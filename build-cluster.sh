#! /bin/sh

#set -x

if [ $# != 1 ]; then
	echo 'Usage: build-cluster.sh <network interface>'
	exit 1
fi
netif=$1; shift
# Addresses. Multi-node: NODE_IP is this node's address on the cluster network; dual-stack: also
# NODE_IP6. IPv6-only (IPV6_ONLY=yes): NODE_IP6 alone, and Services, pods and nodes are IPv6 only.
if [ "${IPV6_ONLY:-}" = yes ]; then
	[ -n "${NODE_IP6:-}" ] || { echo "IPV6_ONLY=yes needs NODE_IP6"; exit 1; }
	NODE_IP=
fi
NODE_IPS=${NODE_IP:-}${NODE_IP:+${NODE_IP6:+,}}${NODE_IP6:-}

# BSDKubernetes: build from the (public) PlatformNerds forks by default. To build dfr's
# upstream branches instead:
#   BSDK8S_GIT_BASE=https://github.com/dfr CRIO_BRANCH=freebsd-wip-1.37.0 K8S_BRANCH=freebsd-kubelet-v1.36.1 ./build-cluster.sh vtnet0
BSDK8S_GIT_BASE=${BSDK8S_GIT_BASE:-https://github.com/PlatformNerds}
CRIO_BRANCH=${CRIO_BRANCH:-bsdk8s-1.37}
K8S_BRANCH=${K8S_BRANCH:-bsdk8s-v1.36.1}

# Control-plane images. dfr publishes FreeBSD/amd64 images only. On other architectures (e.g. arm64 on
# Apple Silicon) build them locally first with BSDKubernetes/scripts/build-images-freebsd.sh and set
# IMAGE_REPO to the prefix used there (default ghcr.io/platformnerds).
ARCH=$(uname -m)
if [ "${ARCH}" = amd64 ]; then
	IMAGE_REPO=${IMAGE_REPO:-ghcr.io/dfr}
else
	IMAGE_REPO=${IMAGE_REPO:-ghcr.io/platformnerds}
	PAUSE_IMAGE=${PAUSE_IMAGE:-${IMAGE_REPO}/pause:3.10.2}
	check_img=${IMAGE_REPO}/kube-apiserver:v1.36.1
	[ -n "${JOIN_ENDPOINT:-}" ] && check_img=${PAUSE_IMAGE}
	if ! sudo podman image exists ${check_img} 2>/dev/null; then
		echo "No ${ARCH} control-plane images found under ${IMAGE_REPO}; build them with"
		echo "  sudo BSDKubernetes/scripts/build-images-freebsd.sh <bindir> ${IMAGE_REPO}"
		exit 1
	fi
fi
ETCD_TAG=${ETCD_TAG:-3.6.5-0}

if [ "$(sysctl -n kern.racct.enable)" -eq 0 ]; then
	echo 'RACCT is disabled; to enable, add kern.racct.enable="1" to /boot/loader.conf and reboot'
	exit 1
fi

# Install Podman packages and supporting utilities which are also needed for
# Kubernetes
echo "Installing and initialising podman-suite"
sudo env ASSUME_ALWAYS_YES=yes pkg update
sudo pkg install -y podman-suite
sudo kldload nullfs
sudo kldload fdescfs
sudo kldload if_bridge
sudo kldload pf
# SCTP sockets for pods (Services and NetworkPolicies of protocol SCTP).
sudo kldload -n sctp
# The NFS server for privileged pods that serve NFS (nfsd runs in the pod's jail;
# the module must be loaded outside the jails).
sudo kldload -n nfsd
sudo sysrc kld_list="nullfs fdescfs if_bridge pf sctp nfsd"

# BSDKubernetes: replace the packaged ocijail with our fork, which enforces
# container resource limits (OCI linux.resources -> rctl rules). Built with the
# CLI11 version ocijail pins (distfiles/v2.3.2.zip); newer CLI11 breaks --version.
# Set OCIJAIL_BRANCH="" to keep the packaged ocijail.
OCIJAIL_BRANCH=${OCIJAIL_BRANCH-bsdk8s-main}
if [ -n "${OCIJAIL_BRANCH}" ]; then
	echo "Building ocijail from ${BSDK8S_GIT_BASE}/ocijail.git (${OCIJAIL_BRANCH})"
	sudo pkg install -y nlohmann-json
	if [ ! -d ocijail ]; then
		git clone -b ${OCIJAIL_BRANCH} ${BSDK8S_GIT_BASE}/ocijail.git
	fi
	(
		cd ocijail
		git pull
		rm -rf _cli11 && mkdir _cli11 && tar -xf distfiles/v2.3.2.zip -C _cli11
		cd ocijail
		c++ -std=c++20 -O2 -Wno-deprecated-declarations -I.. \
			-I../_cli11/CLI11-2.3.2/include -I/usr/local/include \
			-o ../ocijail.bin $(ls *.cpp | grep -v _test) -lm
		sudo install -m 755 ../ocijail.bin /usr/local/bin/ocijail
		sudo pkg lock -y ocijail
	)
fi

ocijail_version=$(ocijail --version | cut -w -f3)
ocijail_major=$(echo ${ocijail_version} | cut -d'.' -f1)
ocijail_minor=$(echo ${ocijail_version} | cut -d'.' -f2)
if [ ${ocijail_major} -le 1 -a ${ocijail_minor} -lt 6 ]; then
	echo "ocijail ${ocijail_version} is too old; install version 0.6.0 or later"
	exit 1
fi

ensure_sysctl() {
	local var=$1; shift
	grep -q ${var} /etc/sysctl.conf || (
		echo ${var} | sudo tee -a /etc/sysctl.conf > /dev/null
	)
}

# Sysctl settings to allow routing and filtering for cluster network traffic
ensure_sysctl 'net.pf.filter_local=1'
ensure_sysctl 'net.inet.ip.forwarding=1'
# Dual-stack (NODE_IP6 set, see below): route IPv6 too.
if [ -n "${NODE_IP6:-}" ]; then
	ensure_sysctl 'net.inet6.ip6.forwarding=1'
	# A forwarding node ignores router advertisements unless this is set, so an uplink
	# configured by SLAAC would lose its IPv6 address and default route.
	ensure_sysctl 'net.inet6.ip6.rfc6204w3=1'
	sudo sysrc ipv6_gateway_enable=YES > /dev/null
fi
ensure_sysctl 'net.link.bridge.pfil_member=1'
# SCTP Services: let pf's rdr change SCTP destination ports (Service port ->
# targetPort, NodePorts). Stock pf never does; the knob comes with
# PlatformNerds/freebsd-src bsdk8s/pf-sctp-rdr-port.
if sysctl -q net.pf.sctp_rdr_ports >/dev/null 2>&1; then
	ensure_sysctl 'net.pf.sctp_rdr_ports=1'
fi
# A pod's containers are sibling jails sharing the pod jail's vnet: let them see each other's
# sockets (netstat/sockstat, e.g. readiness probes), as in one Linux network namespace.
# Needs PlatformNerds/freebsd-src bsdk8s/jail-vnet-socket-visibility.
if sysctl -q security.bsd.see_vnet_sockets >/dev/null 2>&1; then
	ensure_sysctl 'security.bsd.see_vnet_sockets=1'
fi
# A privileged container may run an NFS server (allow.nfsd, granted by CRI-O) in the network
# stack it shares with its pod. Needs PlatformNerds/freebsd-src bsdk8s/jail-nfsd-inherited-vnet.
if sysctl -q security.jail.nfsd_inherited_vnet >/dev/null 2>&1; then
	ensure_sysctl 'security.jail.nfsd_inherited_vnet=1'
fi
# Access times like a Linux node's (relatime): read-mostly pods don't write atimes back, and the
# container mount table (linprocfs) shows relatime, which storage tests check. Kernels without
# PlatformNerds/freebsd-src bsdk8s/linprocfs-mounts-lower-15.1 list the property but ignore it.
if zfs list -H -o name zroot >/dev/null 2>&1; then
	sudo zfs set relatime=on zroot
fi
# Cap the ZFS ARC at a quarter of RAM so pods, not the file cache, get the
# memory (the kubelet counts the ARC above its minimum as reclaimable).
ensure_sysctl "vfs.zfs.arc_max=$(( $(sysctl -n hw.physmem) / 4 ))"
sudo service sysctl start

# Set up a simple PF config which is needed for container networking
if [ ! -f /etc/pf.conf ]; then
	cat >> pf.conf-tmp <<EOF
# Reassemble fragments: kube-proxy's rdr needs ports, which only a datagram's first
# fragment carries, so fragmented UDP to a Service failed without it.
set reassemble yes
v4egress_if = "${netif}"
v6egress_if = "${netif}"

nat on \$v4egress_if inet from <cni-nat> to any -> (\$v4egress_if)
# Pod egress: NAT traffic from the pod CIDR to anything outside it, so pods
# reach external hosts (and DNS) while pod-to-pod traffic keeps pod IPs.
nat on \$v4egress_if inet from 10.244.0.0/16 to ! 10.244.0.0/16 -> (\$v4egress_if)
nat on \$v6egress_if inet6 from <cni-nat> to !ff00::/8 -> (\$v6egress_if)

rdr-anchor "cni-rdr/*"
nat-anchor "cni-rdr/*"
anchor "kube-np/*"
anchor "cni-rdr/*"
table <cni-nat>
EOF
	sudo mv pf.conf-tmp /etc/pf.conf
	sudo sysrc pf_enable=YES
	sudo service pf restart
fi
# kube-proxy also puts filter rules in its anchors: "pass out ... rdr-to" for
# traffic the node itself sends to ClusterIPs (rdr only sees inbound packets).
if ! grep -q '^anchor "cni-rdr/\*"' /etc/pf.conf; then
	echo 'anchor "cni-rdr/*"' | sudo tee -a /etc/pf.conf > /dev/null
	sudo service pf reload
fi
# NetworkPolicy (BSDKubernetes components/bsd-netpol) loads its rules into kube-np/policy.
# Evaluate them before kube-proxy's filter rules, whose "pass in quick ... rdr-to" (split
# port groups) would otherwise skip egress policy.
if ! grep -q '^set reassemble' /etc/pf.conf; then
	{ echo 'set reassemble yes'; cat /etc/pf.conf; } > pf.conf-tmp
	sudo mv pf.conf-tmp /etc/pf.conf
	sudo service pf reload
fi
if ! grep -q '^anchor "kube-np/\*"' /etc/pf.conf; then
	sudo sed -i '' 's|^anchor "cni-rdr/\*"$|anchor "kube-np/*"\
anchor "cni-rdr/*"|' /etc/pf.conf
	sudo service pf reload
fi
# Older configs had no pod egress NAT (ipMasq is off in the CNI config, so
# <cni-nat> stays empty): pods could not reach anything outside the cluster,
# e.g. CoreDNS could not forward. Translation rules must precede filter
# rules, so insert it after the existing nat rule.
if ! grep -q 'from 10.244.0.0/16 to ! 10.244.0.0/16' /etc/pf.conf; then
	sudo sed -i '' '/^nat on \$v4egress_if inet from <cni-nat>/a\
nat on $v4egress_if inet from 10.244.0.0/16 to ! 10.244.0.0/16 -> ($v4egress_if)
' /etc/pf.conf
	sudo pfctl -nf /etc/pf.conf && sudo service pf reload
fi
# Dual-stack: the same for the IPv6 pod range, so pods reach IPv6 hosts outside the cluster
# (NAT66 to the egress interface's address; pf leaves link-local addresses out).
pfx6=${POD_SUBNET6:-fd00:10:244::/56}
if [ -n "${NODE_IP6:-}" ] && ! sudo grep -q "from ${pfx6} to" /etc/pf.conf; then
	sudo sed -i '' '/^nat on \$v6egress_if inet6 from <cni-nat>/a\
nat on $v6egress_if inet6 from '"$pfx6"' to ! '"$pfx6"' -> ($v6egress_if)
' /etc/pf.conf
	sudo pfctl -nf /etc/pf.conf && sudo service pf reload
fi

# Pods get the node's resolv.conf (CoreDNS forwards to it). Keep only IPv4
# nameservers: an IPv6 one the pod network cannot reach (e.g. QEMU's fec0::3)
# makes a share of CoreDNS forwards time out.
sudo mkdir -p /usr/local/etc/kubernetes
# IPv6-only: the other way round, IPv6 nameservers only.
if [ "${IPV6_ONLY:-}" = yes ]; then keep='$2 ~ /:/'; else keep='$2 !~ /:/'; fi
awk "\$1 != \"nameserver\" || $keep" /etc/resolv.conf | sudo tee /usr/local/etc/kubernetes/resolv.conf > /dev/null
grep -q '^nameserver' /usr/local/etc/kubernetes/resolv.conf || sudo cp /etc/resolv.conf /usr/local/etc/kubernetes/resolv.conf

# Linux images (RuntimeClass "linux"): run under the Linux ABI in jails.
# kern.elf64.fallback_brand=3 makes unbranded ELF binaries (musl, e.g.
# Alpine) Linux; FreeBSD binaries always carry a FreeBSD brand.
if [ "${LINUX_IMAGES:-yes}" = yes ]; then
	sudo sysrc kld_list+=" linux64 linprocfs linsysfs fdescfs" > /dev/null
	sudo kldload -n linux64 linprocfs linsysfs fdescfs
	ensure_sysctl 'kern.elf64.fallback_brand=3'
	sudo sysctl kern.elf64.fallback_brand=3 > /dev/null
	sudo mkdir -p /usr/local/etc/crio/crio.conf.d
	printf '[crio.runtime.runtimes.linux]\ninherit_default_runtime = true\ndefault_annotations = { "io.bsdk8s.image-os" = "linux" }\n' |
	    sudo tee /usr/local/etc/crio/crio.conf.d/20-linux.conf > /dev/null
fi

# Like containerd 2.x (enable_unprivileged_ports): non-root processes may bind
# ports below 1024 inside their own pod (e.g. ingress-nginx as uid 101).
# ocijail maps it to the pod vnet's net.inet.ip.portrange.reservedhigh; the
# host keeps its reserved ports. Pods can override it via securityContext.
printf '[crio.runtime]\ndefault_sysctls = [ "net.ipv4.ip_unprivileged_port_start=0" ]\n' |
    sudo tee /usr/local/etc/crio/crio.conf.d/30-unprivileged-ports.conf > /dev/null

# Like containerd and Docker: containers have CAP_MKNOD by default (CRI-O's
# own defaults leave it out). On FreeBSD it only lets a container's jail create
# device nodes outside devfs (allow.mknod, freebsd-src 0043), and those are
# inert: devices are reached only through devfs, where a jail can't create
# nodes. Software that prepares device nodes in a volume expects it.
printf '[crio.runtime]\ndefault_capabilities = [ "MKNOD" ]\n' |
    sudo tee /usr/local/etc/crio/crio.conf.d/35-default-capabilities.conf > /dev/null

# Resolve short image names ("nginx", "bitnami/redis") via docker.io, as
# containerd and Docker do; upstream manifests and charts rely on it.
sudo mkdir -p /usr/local/etc/containers/registries.conf.d
printf 'unqualified-search-registries = ["docker.io"]\nshort-name-mode = "permissive"\n' |
    sudo tee /usr/local/etc/containers/registries.conf.d/10-docker-io.conf > /dev/null

# For the Kubernetes e2e suite only, as upstream CI configures its nodes:
# - the RuntimeClass tests expect a runtime handler named "test-handler" (the
#   default runtime under another name);
# - the private-registry tests run an HTTP registry on the node's
#   localhost:5000, which CRI-O (unlike containerd) only pulls from when it is
#   marked insecure.
if [ "${E2E_NODE_CONFIG:-no}" = yes ]; then
	printf '[crio.runtime.runtimes.test-handler]\ninherit_default_runtime = true\n' |
	    sudo tee /usr/local/etc/crio/crio.conf.d/40-e2e-test-handler.conf > /dev/null
	printf '[[registry]]\nlocation = "localhost:5000"\ninsecure = true\n' |
	    sudo tee /usr/local/etc/containers/registries.conf.d/30-e2e-localhost.conf > /dev/null
fi

# Setup container storage
if [ ! -d /var/db/containers ]; then
	sudo zfs create -o mountpoint=/var/db/containers zroot/containers
fi

# Install build tools needed for building Kubernetes components from source.
echo "Installing packages needed to build and use cluster components"
sudo pkg install -y go gmake gsed git-lite bash pkgconf coreutils kubectl
# The kubelet formats and checks volumes (local disks, block-backed PVs) as on
# Linux: blkid, mkfs.ext4 and e2fsck come from e2fsprogs.
sudo pkg install -y e2fsprogs-core

# Build and install crictl
echo "Building crictl tool for troubleshooting CRI-O problems"
if [ ! -d cri-tools ]; then
	git clone https://github.com/kubernetes-sigs/cri-tools.git
fi
(
	cd cri-tools
	git pull
	gmake
	sudo install build/bin/freebsd/$(go env GOARCH)/crictl /usr/local/bin
	# TODO sudo
	cat >crictl.yaml-tmp <<EOF
runtime-endpoint: "unix:///var/run/crio/crio.sock"
timeout: 0
debug: false
EOF
	sudo mv crictl.yaml-tmp /usr/local/etc/crictl.yaml
)

# Build and install CRI-O
echo "Building CRI-O"
if [ ! -d cri-o ]; then
	git clone -b ${CRIO_BRANCH} ${BSDK8S_GIT_BASE}/cri-o.git
fi
(
	if [ -f /usr/local/etc/rc.d/crio ]; then
		sudo service crio stop
	fi
	cd cri-o
	git pull
	gmake bin/crio
	sudo install bin/crio /usr/local/bin
	sudo install contrib/freebsd/crio /usr/local/etc/rc.d
	if [ -n "${PAUSE_IMAGE:-}" ]; then
		# CRI-O's FreeBSD default pause image (quay.io/dougrabson/pause) is amd64-only
		sudo mkdir -p /usr/local/etc/crio/crio.conf.d
		printf '[crio.image]\npause_image = "%s"\n' "${PAUSE_IMAGE}" | sudo tee /usr/local/etc/crio/crio.conf.d/10-pause.conf > /dev/null
	fi
	sudo sysrc crio_enable=YES
)

# kubelet, kubeadm and kube-proxy report their version from `git describe`, which needs release tags; a
# fork's branch has none, so they would say "v0.0.0-master+$Format:%H$" and kubeadm's preflight check
# refuses such a kubelet. Stamp them from the branch name (vX.Y.Z) and commit instead, unless set.
k8s_version() {
	if [ -n "${KUBE_GIT_VERSION:-}" ]; then echo "$KUBE_GIT_VERSION"; return; fi
	v=$(echo "${K8S_BRANCH}" | sed -n 's/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
	[ -n "$v" ] && echo "${v}-bsdk8s+$(git rev-parse --short=11 HEAD)"
}

# Build and install kubelet
echo "Building kubelet, the node agent running on each node in the cluster"
if [ ! -d kubernetes ]; then
	git clone -b ${K8S_BRANCH} ${BSDK8S_GIT_BASE}/kubernetes.git
fi
(
	if [ -f /usr/local/etc/rc.d/kubelet ]; then
		sudo service kubelet stop
	fi
	sudo install -m 755 files/kubelet /usr/local/etc/rc.d
	sudo mkdir -p /usr/local/etc/newsyslog.conf.d
	sudo install -m 644 files/kubernetes-newsyslog.conf /usr/local/etc/newsyslog.conf.d/kubernetes.conf
	cd kubernetes
	git fetch origin ${K8S_BRANCH}
	git checkout -B ${K8S_BRANCH} origin/${K8S_BRANCH}
	KUBE_GIT_VERSION=$(k8s_version); export KUBE_GIT_VERSION
	gmake WHAT=cmd/kubelet
	sudo install _output/local/go/bin/kubelet /usr/local/bin
	sudo sysrc kubelet_enable=YES
)

# Build and install kubeadm
echo "Building kubeadm, a tool for creating and managing clusters"
(
	cd kubernetes
	# bsdk8s branch carries kubelet + kube-proxy + kubeadm patches together
	git checkout -B ${K8S_BRANCH} origin/${K8S_BRANCH}
	KUBE_GIT_VERSION=$(k8s_version); export KUBE_GIT_VERSION
	gmake WHAT=cmd/kubeadm
	sudo install _output/local/go/bin/kubeadm /usr/local/bin
	# kube-proxy runs on the host (see files/kube-proxy for why)
	gmake WHAT=cmd/kube-proxy
	sudo install _output/local/go/bin/kube-proxy /usr/local/bin
)

# Build a single node cluster using kubeadm
SERVICE_SUBNET=${SERVICE_SUBNET:-10.96.0.0/12}
# Dual-stack: set NODE_IP6 (this node's IPv6 address on the cluster network, e.g.
# fd00:100::1) on every node. These are the IPv6 Service and pod ranges then.
SERVICE_SUBNET6=${SERVICE_SUBNET6:-fd00:10:96::/112}
POD_SUBNET6=${POD_SUBNET6:-fd00:10:244::/56}
if [ "${IPV6_ONLY:-}" = yes ]; then
	SVC_SUBNETS=$SERVICE_SUBNET6; POD_SUBNETS=$POD_SUBNET6
	# kube-proxy's healthz and metrics, on IPv6
	KP_BIND='bindAddress: "::"'
else
	SVC_SUBNETS=${SERVICE_SUBNET}${NODE_IP6:+,${SERVICE_SUBNET6}}; POD_SUBNETS=10.244.0.0/16${NODE_IP6:+,${POD_SUBNET6}}
	KP_BIND=
fi

# Traffic the node sends to a ClusterIP is redirected by pf on output, keeping
# its source address, so that must be an address the endpoint can reply to:
# on a multi-homed node, route the Service CIDR via the NODE_IP interface
# (otherwise it follows the default route, e.g. a NAT interface).
route_service_subnet() {
	if [ -n "${NODE_IP:-}" ]; then
	svcif=$(ifconfig | awk -v ip="${NODE_IP}" '/^[a-z]/ {i=$1; sub(":$", "", i)} $1 == "inet" && $2 == ip {print i}')
	[ -n "$svcif" ] || { echo "NODE_IP ${NODE_IP} not found on any interface"; return 1; }
	sudo sysrc static_routes+=" k8ssvc" > /dev/null
	sudo sysrc route_k8ssvc="-net ${SERVICE_SUBNET} -interface ${svcif}" > /dev/null
	sudo route -q delete -net "${SERVICE_SUBNET}" 2>/dev/null || true
	sudo route -q add -net "${SERVICE_SUBNET}" -interface "${svcif}"
	echo "Service CIDR ${SERVICE_SUBNET} routed via ${svcif}"
	fi
	[ -n "${NODE_IP6:-}" ] || return 0
	svcif6=$(ifconfig | awk -v ip="${NODE_IP6}" '/^[a-z]/ {i=$1; sub(":$", "", i)} $1 == "inet6" && $2 == ip {print i}')
	[ -n "$svcif6" ] || { echo "NODE_IP6 ${NODE_IP6} not found on any interface"; return 1; }
	sudo sysrc ipv6_static_routes+=" k8ssvc6" > /dev/null
	sudo sysrc ipv6_route_k8ssvc6="-net ${SERVICE_SUBNET6} -interface ${svcif6}" > /dev/null
	sudo route -q delete -inet6 -net "${SERVICE_SUBNET6}" 2>/dev/null || true
	sudo route -q add -inet6 -net "${SERVICE_SUBNET6}" -interface "${svcif6}"
	echo "Service CIDR ${SERVICE_SUBNET6} routed via ${svcif6}"
}
route_service_subnet

# Multi-node: NODE_IP is this node's address on the cluster network (e.g. 192.168.100.1).
# Control plane: plain ./build-cluster.sh <if>   Worker: also set JOIN_ENDPOINT (host:6443),
# JOIN_TOKEN and JOIN_CA_HASH (from `kubeadm token create --print-join-command`).
if [ -n "${JOIN_ENDPOINT:-}" ]; then
	echo "Joining the cluster at ${JOIN_ENDPOINT}"
else
	echo "Building the control plane node"
fi
# Recycler pod template: upstream's default (pkg/volume NewPersistentVolumeRecyclerPodTemplate)
# with FreeBSD's official runtime image, whose sh, find and ls run the same scrub command.
RECYCLER_POD=/usr/local/etc/kubernetes/recycler-pod.yaml
RECYCLER_IMAGE=${RECYCLER_IMAGE:-docker.io/freebsd/freebsd-runtime:$(freebsd-version -u | sed 's/-.*//')}
sudo mkdir -p /usr/local/etc/kubernetes
sudo tee "${RECYCLER_POD}" >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  generateName: pv-recycler-
  namespace: default
spec:
  activeDeadlineSeconds: 60
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/os: freebsd
  volumes:
  - name: vol
  containers:
  - name: pv-recycler
    image: ${RECYCLER_IMAGE}
    command: ["/bin/sh"]
    args: ["-c", "test -e /scrub && find /scrub -mindepth 1 -delete && test -z \\"\$(ls -A /scrub)\\" || exit 1"]
    volumeMounts:
    - name: vol
      mountPath: /scrub
EOF

cat >kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
etcd:
  local:
    imageRepository: ${IMAGE_REPO}
    imageTag: ${ETCD_TAG}
imageRepository: ${IMAGE_REPO}
kubernetesVersion: v1.36.1
apiServer:
  extraArgs:
  # kube-apiserver runs in a host-network jail and pf (15.x) does not redirect
  # host-originated traffic to ClusterIPs, so webhook/aggregated-API calls to a
  # Service ClusterIP time out. Resolve those Services to pod endpoints instead.
  - name: enable-aggregator-routing
    value: "true"
  # Serve the DRA beta APIs next to v1 (off by default in 1.36): DRA drivers
  # and e2e tests that still use v1beta1/v1beta2 clients need them.
  - name: runtime-config
    value: resource.k8s.io/v1beta1=true,resource.k8s.io/v1beta2=true
controllerManager:
  # The PV recycler (persistentVolumeReclaimPolicy: Recycle) runs a pod whose
  # default image is Linux (debian-base): use a FreeBSD one (written above).
  extraArgs:
  - name: pv-recycler-pod-template-filepath-nfs
    value: ${RECYCLER_POD}
  - name: pv-recycler-pod-template-filepath-hostpath
    value: ${RECYCLER_POD}
  extraVolumes:
  - name: recycler-pod
    hostPath: ${RECYCLER_POD}
    mountPath: ${RECYCLER_POD}
    readOnly: true
    pathType: File
networking:
  serviceSubnet: ${SVC_SUBNETS}
  podSubnet: ${POD_SUBNETS}
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
serverTLSBootstrap: true
resolvConf: /usr/local/etc/kubernetes/resolv.conf
# Headroom so memory eviction acts before the host runs out (a FreeBSD node with
# no swap to speak of livelocks instead of failing allocations).
systemReserved:
  memory: 1Gi
evictionHard:
  memory.available: 500Mi
  nodefs.available: "10%"
  imagefs.available: "15%"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
# Only this node's pods count as "local" for externalTrafficPolicy: Local. The
# bsd-hostgw CNI doesn't masquerade pod-to-node traffic, so with the default
# (the whole cluster CIDR) a pod calling another node's NodePort would be
# short-circuited instead of treated as external, as on Linux.
detectLocalMode: NodeCIDR
${KP_BIND}
EOF
if [ -n "${NODE_IPS}" ]; then
	cat >>kubeadm-config.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP:-$NODE_IP6}
nodeRegistration:
  kubeletExtraArgs:
  - name: node-ip
    value: ${NODE_IPS}
EOF
fi

sudo service crio start
while [ ! -S /var/run/crio/crio.sock ]; do
	echo "Waiting for crio to start"
	sleep 1
done
echo "crio is running"

# add_ipv6_range CIDR6: copy a CNI config from stdin, adding an IPv6 default route and a
# second (IPv6) range, CIDR6 with its ::1 as gateway. Without CIDR6, copy it unchanged.
add_ipv6_range() {
	[ -n "$1" ] || { cat; return; }
	awk -v s6="$1" -v g6="${1%/*}1" '
	/"dst": "0\.0\.0\.0\/0"/ { print; getline; print "          },"; print "          {"
		print "            \"dst\": \"::/0\""; print; next }
	/"gateway": / { print; getline; print; print "          ],"; print "          ["; print "            {"
		print "              \"subnet\": \"" s6 "\","; print "              \"gateway\": \"" g6 "\""
		print "            }"; next }
	{ print }'
}

# Per-node CNI config: host-local IPAM over this node's podCIDR (allocated by the
# controller-manager from podSubnet), so pod IPs don't collide across nodes. Assumes /24s.
write_cni_config() {
	kc=/usr/local/etc/kubernetes/kubelet.conf
	# IPv6-only: the template's IPv4 range becomes the node's IPv6 one (gateway ::1, route ::/0).
	if [ "${IPV6_ONLY:-}" = yes ]; then
		until cidr6=$(sudo kubectl --kubeconfig $kc get node "$(hostname)" -o jsonpath='{.spec.podCIDR}' 2>/dev/null) && [ -n "$cidr6" ]; do
			echo "Waiting for this node's podCIDR"; sleep 2
		done
		sed -e '/"rangeStart"/d' -e '/"rangeEnd"/d' -e 's|"dst": "0\.0\.0\.0/0"|"dst": "::/0"|' \
		    -e "s|10.244.0.0/16|${cidr6}|" -e "s|\"10.244.0.1\"|\"${cidr6%/*}1\"|" files/10-kubetest.conflist |
		    sudo tee /usr/local/etc/cni/net.d/10-kubetest.conflist > /dev/null
		echo "CNI: pod subnet ${cidr6}"
		return
	fi
	until cidr=$(sudo kubectl --kubeconfig $kc get node "$(hostname)" -o jsonpath='{.spec.podCIDR}' 2>/dev/null) && [ -n "$cidr" ]; do
		echo "Waiting for this node's podCIDR"; sleep 2
	done
	# Dual-stack: the IPv6 pod CIDR comes second.
	cidr6=
	if [ -n "${NODE_IP6:-}" ]; then
		until cidr6=$(sudo kubectl --kubeconfig $kc get node "$(hostname)" -o jsonpath='{.spec.podCIDRs[1]}' 2>/dev/null) && [ -n "$cidr6" ]; do
			echo "Waiting for this node's IPv6 podCIDR"; sleep 2
		done
	fi
	p=${cidr%.*/*}
	# kubeadm reset leaves the CNI bridge with its old address (e.g. a /16 from a
	# single-node config); give it this node's gateway/prefix.
	if ifconfig cni-kubetest >/dev/null 2>&1; then
		sudo ifconfig cni-kubetest inet "${p}.1/${cidr#*/}"
	fi
	sed -e "s|10.244.0.0/16|${cidr}|" -e "s|10.244.0.2\"|${p}.2\"|" \
	    -e "s|10.244.0.254|${p}.254|" -e "s|10.244.0.1\"|${p}.1\"|" files/10-kubetest.conflist |
	    add_ipv6_range "$cidr6" | sudo tee /usr/local/etc/cni/net.d/10-kubetest.conflist > /dev/null
	echo "CNI: pod subnet ${cidr}${cidr6:+ ${cidr6}}"
}

# host-gw routes to the other nodes' pod CIDRs (no-op on a single node).
# Credentials: ServiceAccount kube-system/bsd-hostgw (nodes get/list/watch). The control
# plane creates it; workers get its token as HOSTGW_TOKEN (printed on the control plane).
write_hostgw_kubeconfig() { # server token
	kc=/usr/local/etc/bsd-hostgw/kubeconfig
	sudo mkdir -p /usr/local/etc/bsd-hostgw
	sudo kubectl config --kubeconfig=$kc set-cluster default --server="https://$1" \
		--certificate-authority=/usr/local/etc/kubernetes/pki/ca.crt --embed-certs > /dev/null
	sudo kubectl config --kubeconfig=$kc set-credentials bsd-hostgw --token="$2" > /dev/null
	sudo kubectl config --kubeconfig=$kc set-context default --cluster=default --user=bsd-hostgw > /dev/null
	sudo kubectl config --kubeconfig=$kc use-context default > /dev/null
	sudo chmod 600 $kc
}
install_hostgw() {
	sudo install -m 755 files/bsd-hostgw /usr/local/libexec/bsd-hostgw
	sudo install -m 755 files/bsd_hostgw /usr/local/etc/rc.d/bsd_hostgw
	sudo sysrc bsd_hostgw_enable=YES
	sudo service bsd_hostgw restart
}

# A CNI config left by a previous cluster (kubeadm reset does not remove it) would let
# the first pods (e.g. CoreDNS) start with the wrong subnet before write_cni_config runs.
sudo rm -f /usr/local/etc/cni/net.d/10-kubetest.conflist

if [ -n "${JOIN_ENDPOINT:-}" ]; then
	cat >kubeadm-join.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: ${JOIN_ENDPOINT}
    token: ${JOIN_TOKEN}
    caCertHashes: ["${JOIN_CA_HASH}"]
nodeRegistration:
  kubeletExtraArgs:
  - name: node-ip
    value: ${NODE_IPS:?NODE_IP (or NODE_IP6 with IPV6_ONLY=yes) is required to join}
EOF
	sudo kubeadm join --config ./kubeadm-join.yaml || exit 1
	write_cni_config
	if [ -n "${HOSTGW_TOKEN:-}" ]; then
		write_hostgw_kubeconfig "${JOIN_ENDPOINT}" "${HOSTGW_TOKEN}"
	else
		echo "HOSTGW_TOKEN not set: no cross-node pod routes until it is configured"
	fi
	install_hostgw
	echo "Joined. On the control plane, approve this node's kubelet serving CSR:"
	echo "  kubectl get csr | awk '/Pending/ {print \$1}' | xargs kubectl certificate approve"
	exit 0
fi

sudo kubeadm init --config ./kubeadm-config.yaml || exit 1
mkdir -p $HOME/.kube
sudo cp /usr/local/etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Approve node TLS signing requests
sleep 1
kubectl get csr --no-headers | cut -w -f1 | xargs kubectl certificate approve

# Remove taints from our single node so that we can schedule non control plane
# workloads
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Install a simple network configuration to allow allocating IP addresses for
# pods (per-node subnet) and the host-gw route daemon
write_cni_config
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: bsd-hostgw, namespace: kube-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: bsd-hostgw}
rules:
- {apiGroups: [""], resources: ["nodes"], verbs: ["get", "list", "watch"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: bsd-hostgw}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: bsd-hostgw}
subjects: [{kind: ServiceAccount, name: bsd-hostgw, namespace: kube-system}]
EOF
hostgw_token=$(kubectl -n kube-system create token bsd-hostgw --duration=8760h)
write_hostgw_kubeconfig "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||')" "${hostgw_token}"
install_hostgw

# kube-proxy (pf mode): a hostNetwork pod's jail has no PRIV_NETINET_PF (FreeBSD grants it only
# to VNET jails) unless the kernel has the proposed allow.pf jail parameter
# (PlatformNerds/freebsd-src bsdk8s/allow-pf), which CRI-O then sets for privileged
# host-network pods. With it, the normal kubeadm DaemonSet works. Without it, run
# kube-proxy as a host rc service instead.
if sysctl -q security.jail.param.allow.pf >/dev/null 2>&1; then
	echo "Kernel supports allow.pf: kube-proxy runs as the kubeadm DaemonSet"
else
echo "Kernel lacks allow.pf: running kube-proxy on the host"
kubectl -n kube-system patch ds kube-proxy \
	-p '{"spec":{"template":{"spec":{"nodeSelector":{"bsdk8s.io/kube-proxy-in-pod":"true"}}}}}'
sudo mkdir -p /usr/local/etc/kube-proxy
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | \
	sed 's#/var/lib/kube-proxy/kubeconfig.conf#/usr/local/etc/kube-proxy/kubeconfig.conf#' | \
	sudo tee /usr/local/etc/kube-proxy/config.conf > /dev/null
kp_kc=/usr/local/etc/kube-proxy/kubeconfig.conf
sudo kubectl config --kubeconfig=${kp_kc} set-cluster default \
	--server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') \
	--certificate-authority=/usr/local/etc/kubernetes/pki/ca.crt --embed-certs > /dev/null
sudo kubectl config --kubeconfig=${kp_kc} set-credentials kube-proxy \
	--token=$(kubectl -n kube-system create token kube-proxy --duration=8760h) > /dev/null
sudo kubectl config --kubeconfig=${kp_kc} set-context default --cluster=default --user=kube-proxy > /dev/null
sudo kubectl config --kubeconfig=${kp_kc} use-context default > /dev/null
sudo chmod 600 ${kp_kc}
sudo install -m 755 files/kube-proxy /usr/local/etc/rc.d/kube_proxy
sudo sysrc kube_proxy_enable=YES
sudo service kube_proxy restart
fi

# kubeadm's kubelet-finalize restarts the kubelet, which files new serving CSRs
# (serverTLSBootstrap); approve them or kubectl exec/logs fail with a TLS error.
sleep 5
kubectl get csr --no-headers | awk '$NF ~ /Pending/ {print $1}' | xargs -r kubectl certificate approve

# RuntimeClass for Linux images; nodes opt in with the label (set below).
# bsdk8s.io/pod-os lets the kubelet admit pods with spec.os.name=linux when
# they use this RuntimeClass.
kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: linux
  annotations: {bsdk8s.io/pod-os: linux}
handler: linux
scheduling:
  nodeSelector: {bsdk8s.io/linux-abi: "true"}
EOF
[ "${LINUX_IMAGES:-yes}" = yes ] && kubectl label node "$(hostname)" bsdk8s.io/linux-abi=true --overwrite > /dev/null
# Upstream manifests pin pods to kubernetes.io/os=linux; to run them here
# unmodified, install the bsd-placement webhook (BSDKubernetes repo,
# components/bsd-placement: ./build.sh && deploy/install.sh).
# LoadBalancer Services: BSDKubernetes components/bsd-lb (research/25): build.sh on a node, then
#   sed -e "s|\${IMAGE}|localhost/bsd-lb:dev|" -e "s|\${POOL}|<free addresses on the node network>|" \
#     deploy/bsd-lb.yaml | kubectl apply -f -
# NetworkPolicy: components/bsd-netpol (research/22), whose anchor is set up above.

echo "To add worker nodes, run on each (NODE_IP = the worker's cluster address):"
echo "  NODE_IP=<ip> JOIN_ENDPOINT=... JOIN_TOKEN=... JOIN_CA_HASH=... HOSTGW_TOKEN=<token> ./build-cluster.sh <if>"
echo "  join values: sudo kubeadm token create --print-join-command"
echo "  HOSTGW_TOKEN: kubectl -n kube-system create token bsd-hostgw --duration=8760h"
echo "If everything worked right, the cluster should be live"
kubectl get all -A
