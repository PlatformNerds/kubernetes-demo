#! /bin/sh

#set -x

if [ $# != 1 ]; then
	echo 'Usage: build-cluster.sh <network interface>'
	exit 1
fi
netif=$1; shift

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
sudo sysrc kld_list="nullfs fdescfs if_bridge pf"

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
ensure_sysctl 'net.link.bridge.pfil_member=1'
# Cap the ZFS ARC at a quarter of RAM so pods, not the file cache, get the
# memory (the kubelet counts the ARC above its minimum as reclaimable).
ensure_sysctl "vfs.zfs.arc_max=$(( $(sysctl -n hw.physmem) / 4 ))"
sudo service sysctl start

# Set up a simple PF config which is needed for container networking
if [ ! -f /etc/pf.conf ]; then
	cat >> pf.conf-tmp <<EOF
v4egress_if = "${netif}"
v6egress_if = "${netif}"

nat on \$v4egress_if inet from <cni-nat> to any -> (\$v4egress_if)
# Pod egress: NAT traffic from the pod CIDR to anything outside it, so pods
# reach external hosts (and DNS) while pod-to-pod traffic keeps pod IPs.
nat on \$v4egress_if inet from 10.244.0.0/16 to ! 10.244.0.0/16 -> (\$v4egress_if)
nat on \$v6egress_if inet6 from <cni-nat> to !ff00::/8 -> (\$v6egress_if)

rdr-anchor "cni-rdr/*"
nat-anchor "cni-rdr/*"
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

# Pods get the node's resolv.conf (CoreDNS forwards to it). Keep only IPv4
# nameservers: an IPv6 one the pod network cannot reach (e.g. QEMU's fec0::3)
# makes a share of CoreDNS forwards time out.
sudo mkdir -p /usr/local/etc/kubernetes
awk '$1 != "nameserver" || $2 !~ /:/' /etc/resolv.conf | sudo tee /usr/local/etc/kubernetes/resolv.conf > /dev/null
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

# Resolve short image names ("nginx", "bitnami/redis") via docker.io, as
# containerd and Docker do; upstream manifests and charts rely on it.
sudo mkdir -p /usr/local/etc/containers/registries.conf.d
printf 'unqualified-search-registries = ["docker.io"]\nshort-name-mode = "permissive"\n' |
    sudo tee /usr/local/etc/containers/registries.conf.d/10-docker-io.conf > /dev/null

# Setup container storage
if [ ! -d /var/db/containers ]; then
	sudo zfs create -o mountpoint=/var/db/containers zroot/containers
fi

# Install build tools needed for building Kubernetes components from source.
echo "Installing packages needed to build and use cluster components"
sudo pkg install -y go gmake gsed git-lite bash pkgconf coreutils kubectl

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
	cd kubernetes
	git fetch origin ${K8S_BRANCH}
	git checkout -B ${K8S_BRANCH} origin/${K8S_BRANCH}
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
	gmake WHAT=cmd/kubeadm
	sudo install _output/local/go/bin/kubeadm /usr/local/bin
	# kube-proxy runs on the host (see files/kube-proxy for why)
	gmake WHAT=cmd/kube-proxy
	sudo install _output/local/go/bin/kube-proxy /usr/local/bin
)

# Build a single node cluster using kubeadm
SERVICE_SUBNET=${SERVICE_SUBNET:-10.96.0.0/12}

# Traffic the node sends to a ClusterIP is redirected by pf on output, keeping
# its source address, so that must be an address the endpoint can reply to:
# on a multi-homed node, route the Service CIDR via the NODE_IP interface
# (otherwise it follows the default route, e.g. a NAT interface).
route_service_subnet() {
	[ -n "${NODE_IP:-}" ] || return 0
	svcif=$(ifconfig | awk -v ip="${NODE_IP}" '/^[a-z]/ {i=$1; sub(":$", "", i)} $1 == "inet" && $2 == ip {print i}')
	[ -n "$svcif" ] || { echo "NODE_IP ${NODE_IP} not found on any interface"; return 1; }
	sudo sysrc static_routes+=" k8ssvc" > /dev/null
	sudo sysrc route_k8ssvc="-net ${SERVICE_SUBNET} -interface ${svcif}" > /dev/null
	sudo route -q delete -net "${SERVICE_SUBNET}" 2>/dev/null || true
	sudo route -q add -net "${SERVICE_SUBNET}" -interface "${svcif}"
	echo "Service CIDR ${SERVICE_SUBNET} routed via ${svcif}"
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
networking:
  serviceSubnet: ${SERVICE_SUBNET}
  podSubnet: 10.244.0.0/16
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
EOF
if [ -n "${NODE_IP:-}" ]; then
	cat >>kubeadm-config.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
nodeRegistration:
  kubeletExtraArgs:
  - name: node-ip
    value: ${NODE_IP}
EOF
fi

sudo service crio start
while [ ! -S /var/run/crio/crio.sock ]; do
	echo "Waiting for crio to start"
	sleep 1
done
echo "crio is running"

# Per-node CNI config: host-local IPAM over this node's podCIDR (allocated by the
# controller-manager from podSubnet), so pod IPs don't collide across nodes. Assumes /24s.
write_cni_config() {
	kc=/usr/local/etc/kubernetes/kubelet.conf
	until cidr=$(sudo kubectl --kubeconfig $kc get node "$(hostname)" -o jsonpath='{.spec.podCIDR}' 2>/dev/null) && [ -n "$cidr" ]; do
		echo "Waiting for this node's podCIDR"; sleep 2
	done
	p=${cidr%.*/*}
	# kubeadm reset leaves the CNI bridge with its old address (e.g. a /16 from a
	# single-node config); give it this node's gateway/prefix.
	if ifconfig cni-kubetest >/dev/null 2>&1; then
		sudo ifconfig cni-kubetest inet "${p}.1/${cidr#*/}"
	fi
	sed -e "s|10.244.0.0/16|${cidr}|" -e "s|10.244.0.2\"|${p}.2\"|" \
	    -e "s|10.244.0.254|${p}.254|" -e "s|10.244.0.1\"|${p}.1\"|" files/10-kubetest.conflist |
	    sudo tee /usr/local/etc/cni/net.d/10-kubetest.conflist > /dev/null
	echo "CNI: pod subnet ${cidr}"
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
    value: ${NODE_IP:?NODE_IP is required to join}
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
kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: {name: linux}
handler: linux
scheduling:
  nodeSelector: {bsdk8s.io/linux-abi: "true"}
EOF
[ "${LINUX_IMAGES:-yes}" = yes ] && kubectl label node "$(hostname)" bsdk8s.io/linux-abi=true --overwrite > /dev/null
# Upstream manifests pin pods to kubernetes.io/os=linux; to run them here
# unmodified, install the bsd-placement webhook (BSDKubernetes repo,
# components/bsd-placement: ./build.sh && deploy/install.sh).

echo "To add worker nodes, run on each (NODE_IP = the worker's cluster address):"
echo "  NODE_IP=<ip> JOIN_ENDPOINT=... JOIN_TOKEN=... JOIN_CA_HASH=... HOSTGW_TOKEN=<token> ./build-cluster.sh <if>"
echo "  join values: sudo kubeadm token create --print-join-command"
echo "  HOSTGW_TOKEN: kubectl -n kube-system create token bsd-hostgw --duration=8760h"
echo "If everything worked right, the cluster should be live"
kubectl get all -A
