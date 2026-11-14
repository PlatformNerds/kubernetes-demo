#! /bin/sh

#set -x

if [ $# != 1 ]; then
	echo 'Usage: build-cluster.sh <network interface>'
	exit 1
fi
netif=$1; shift

# BSDKubernetes: build from PlatformNerds forks by default. The forks are private, so
# either configure git credentials (e.g. `gh auth setup-git`) or point at dfr's public repos:
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
	if ! sudo podman image exists ${IMAGE_REPO}/kube-apiserver:v1.36.1 2>/dev/null; then
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
sudo service sysctl start

# Set up a simple PF config which is needed for container networking
if [ ! -f /etc/pf.conf ]; then
	cat >> pf.conf-tmp <<EOF
v4egress_if = "${netif}"
v6egress_if = "${netif}"

nat on \$v4egress_if inet from <cni-nat> to any -> (\$v4egress_if)
nat on \$v6egress_if inet6 from <cni-nat> to !ff00::/8 -> (\$v6egress_if)

rdr-anchor "cni-rdr/*"
nat-anchor "cni-rdr/*"
table <cni-nat>
EOF
	sudo mv pf.conf-tmp /etc/pf.conf
	sudo sysrc pf_enable=YES
	sudo service pf restart
fi

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
	git checkout ${K8S_BRANCH}
	gmake WHAT=cmd/kubelet
	sudo install _output/local/go/bin/kubelet /usr/local/bin
	sudo sysrc kubelet_enable=YES
)

# Build and install kubeadm
echo "Building kubeadm, a tool for creating and managing clusters"
(
	cd kubernetes
	# bsdk8s branch carries kubelet + kube-proxy + kubeadm patches together
	git checkout ${K8S_BRANCH}
	gmake WHAT=cmd/kubeadm
	sudo install _output/local/go/bin/kubeadm /usr/local/bin
	# kube-proxy runs on the host (see files/kube-proxy for why)
	gmake WHAT=cmd/kube-proxy
	sudo install _output/local/go/bin/kube-proxy /usr/local/bin
)

# Build a single node cluster using kubeadm
echo "Building a single node cluster"
cat >kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
etcd:
  local:
    imageRepository: ${IMAGE_REPO}
    imageTag: ${ETCD_TAG}
imageRepository: ${IMAGE_REPO}
kubernetesVersion: v1.36.1
networking:
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
serverTLSBootstrap: true
EOF

sudo service crio start
while [ ! -S /var/run/crio/crio.sock ]; do
	echo "Waiting for crio to start"
	sleep 1
done
echo "crio is running"

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
# pods
sudo install -m 644 files/10-kubetest.conflist /usr/local/etc/cni/net.d

# kube-proxy (pf mode) as a host service instead of the kubeadm DaemonSet: a hostNetwork
# jail has no PRIV_NETINET_PF (FreeBSD grants it only to VNET jails), so pfctl gets EPERM.
echo "Running kube-proxy on the host"
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

# kubeadm's kubelet-finalize restarts the kubelet, which files new serving CSRs
# (serverTLSBootstrap); approve them or kubectl exec/logs fail with a TLS error.
sleep 5
kubectl get csr --no-headers | awk '$NF ~ /Pending/ {print $1}' | xargs -r kubectl certificate approve

echo "If everything worked right, the cluster should be live"
kubectl get all -A
