###########
# Cleanup #
###########
dnf remove -y kubeadm kubelet kubectl docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman cri-o containerd runc jq openssl wget zip htop subscription-manager kubernetes-cni kube*
rm -f /etc/modules-load.d/kubernetes.conf
rm -f /etc/sysctl.d/kubernetes.conf
rm -f /etc/docker/daemon.json
rm -f /etc/yum.repos.d/kubernetes.repo
rm -f /etc/yum.repos.d/crio.repo
rm -rf /etc/crio

# Reboot to make sure everything above takes effect
reboot

#################################################################################################

# (reboot)

#################################################################################################

# Technical objectives:
#  - cgroupv2 enforced
#  - selinux enforced
#  - crio (no containerd, no docker)
# 	opensource, default runtime behind podman (which is alternative to docker)
#	backed and recommended by RedHat, better integration with RedHat-like distribution
#	specifically designed for Kubernetes (lightweight, stable, performant, secure)
#  - kubernetes (without kube-proxy scope)
#  - cilium (with kube-proxy scope)
#  - hubble (cluster network monitoring)
#  - full-epbf (no dependency on br_netfilter kernel module)

#################################################################################################

# Enforcing the new cgroupv2
grep cgroup2 /proc/filesystems	# You should see a line mentioning "cgroup2", meaning that it is available (your Linux kernel is recent enough to embeed this feature)
stat -fc %T /sys/fs/cgroup/	# You should see cgroup2fs, anything else means that you are not using cgroup2, so you would need to enforce it:
  grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1" # To enforce modern/recommended way to manage system resources
  echo $? # Should see 0 if previous command worked fine	
# Clear console
clear

# Usually, we would have to enable two kernel modules: overlay and br_netfilter.
# We will use cri-o as container runtime (instead of containerd), and cri-o will need overlay.
# Now speaking of br_netfilter, the native kube-proxy (kube-system namespace) depends on it... but we will disable it and let cilium (with its eBPF-based proxy mode - basically fully ePBF mode) cover that part; in that case, nothing will depend on kernel module br_netfilter
# Enable overlay within kernel:
mkdir -p /etc/modules-load.d/
echo "overlay" > /etc/modules-load.d/kubernetes.conf
modprobe overlay
# Should see 0 if previous command worked fine
echo $?
# Clear console
clear

# Enforce packets to go through a Linux bridge (package sent to the iptables firewall for processing - no bypass).
# Even if we plan to use cilium with its full-eBPF mode, we still need to enable these systctl parameters.
mkdir -p /etc/sysctl.d/
echo "net.bridge.bridge-nf-call-iptables = 1" > /etc/sysctl.d/kubernetes.conf
echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.d/kubernetes.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/kubernetes.conf
cat /etc/sysctl.d/kubernetes.conf
# To apply changes above
sysctl --system
# Should see 0 if previous command worked fine
echo $?
# Clear console
clear

# Kubernetes 1.28+ officially supports swap, but in our case, we don't want Kubernetes to rely on swap whatsoever (we have plenty of RAM on server and we don't want any of our service to rely on swap since it would introduce higher latency), hence we can disable all swap partitions:
swapoff -a
grep swap /etc/fstab # To see if there is any swap paritition to disable manually
  # If you see a line that is not starting with #:
  vi /etc/fstab  	# ... and just comment line containing "swap" using # in front of line)

# Enforce selinux (because it is important for security purpose - must always be "enforced")
getenforce 	# you should see "Enforcing"; if no, then run command to enforce it (= enable it): setenforce 1
# Clear console
clear

# Add new crio packages repository (not defined in rocky linux by default):
echo "[cri-o]" > /etc/yum.repos.d/crio.repo
echo "name=CRI-O" >> /etc/yum.repos.d/crio.repo
echo "baseurl=https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/rpm/" >> /etc/yum.repos.d/crio.repo
echo "enabled=1" >> /etc/yum.repos.d/crio.repo
echo "gpgcheck=1" >> /etc/yum.repos.d/crio.repo
echo "gpgkey=https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/rpm/repodata/repomd.xml.key" >> /etc/yum.repos.d/crio.repo
cat /etc/yum.repos.d/crio.repo

# Defined which version of crio/kube we will focus on:
kube_latest_minor_stable_version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
echo $kube_latest_minor_stable_version
# In my case, I got "v1.34.1" so major version will be set to:
kube_latest_major_stable_version="v1.34"
echo $kube_latest_major_stable_version

# Add new kube packages repository (not defined in rocky linux by default):
echo "[kubernetes]" > /etc/yum.repos.d/kubernetes.repo
echo "name=Kubernetes" >> /etc/yum.repos.d/kubernetes.repo
echo "baseurl=https://pkgs.k8s.io/core:/stable:/${kube_latest_major_stable_version}/rpm/" >> /etc/yum.repos.d/kubernetes.repo
echo "enabled=1" >> /etc/yum.repos.d/kubernetes.repo
echo "gpgcheck=1" >> /etc/yum.repos.d/kubernetes.repo
echo "gpgkey=https://pkgs.k8s.io/core:/stable:/${kube_latest_major_stable_version}/rpm/repodata/repomd.xml.key" >> /etc/yum.repos.d/kubernetes.repo
cat /etc/yum.repos.d/kubernetes.repo
# Clear console
clear

# Enable CRB repos (9)
yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
/usr/bin/crb enable
# Clear console
clear

# Open port (within firwall) according to https://kubernetes.io/docs/reference/networking/ports-and-protocols/:
systemctl status firewalld
# [6443/tcp] (control-plane) Kubernetes API server
# [2379/tcp] (control-plane) etcd server client API
# [2380/tcp] (control-plane) etcd server client API (too)
# [10250/tcp] (control-plane) Kubelet API
# [10257/tcp] (control-plane) Kubernetes Controller Manager
# [10259/tcp] (control-plane) Kubernetes Scheduler
# [30000-32767/tcp] (worker) Kubernetes NodePort Services
# [30000-32767/udp] (worker) Kubernetes NodePort Services
# [4240/tcp] (cilium) Used for cluster-wide network connectivity and Cilium agent health API
# [8472/udp] (cilium) Default VXLAN port for overlay networking (if VXLAN mode is used)
# [6081/udp] (cilium) Default Geneve port for overlay networking (if Geneve mode is used)
# [9879/tcp] (cilium) Cilium-agent health status API
# [4222/tcp] (cilium) Hubble health
# [4245/tcp] (cilium) Hubble CLI
# [4244/tcp] (cilium) Hubble API
# [6062/tcp] (cilium) Hubble relay pprof server
# [9878/tcp] (cilium) Cilium-envoy health listener
# [9890/tcp] (cilium) Cilium-agent gops server
# [51871/udp] (cilium) WireGuard port (if WireGuard is used for IPsec)
# [12000/tcp] (cilium) Hubble UI
firewall-cmd --permanent --add-port=6443/tcp
firewall-cmd --permanent --add-port=2379/tcp
firewall-cmd --permanent --add-port=2380/tcp
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=10257/tcp
firewall-cmd --permanent --add-port=10259/tcp
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --permanent --add-port=30000-32767/udp
firewall-cmd --permanent --add-port=4240/tcp
firewall-cmd --permanent --add-port=8472/udp
firewall-cmd --permanent --add-port=6081/udp
firewall-cmd --permanent --add-port=9879/tcp
firewall-cmd --permanent --add-port=4222/tcp
firewall-cmd --permanent --add-port=4245/tcp
firewall-cmd --permanent --add-port=4244/tcp
firewall-cmd --permanent --add-port=6062/tcp
firewall-cmd --permanent --add-port=12000/tcp
firewall-cmd --permanent --add-port=9878/tcp
firewall-cmd --permanent --add-port=9890/tcp
firewall-cmd --permanent --add-port=51871/udp
firewall-cmd --reload
firewall-cmd --list-all
# Clear console
clear

# Reboot to make sure everything above takes effect
reboot

#################################################################################################

# (reboot)

#################################################################################################

# Install basic tools
yum install -y crun htop jq openssl wget yq yum-utils zip

# Check swap is off:
htop 	# You may not see swap, or if you see it then you should see "swap 0kb/0kb" => meaning no active swap anymore

# Check cgroupv2:
grep cgroup2 /proc/filesystems	# You should see a line with "cgroup2"
stat -fc %T /sys/fs/cgroup/	# You should see "cgroup2fs"

# Check kernel modules loaded:
lsmod | grep "overlay"	# You should see a line with "overlay"

# Install-enable-start cri-o as container runtime (we won't use containerd nor docker, kube will interact with crio directly)
yum install -y cri-tools kubernetes-cni cri-o

# Enforce cgroup2 within cri-o and enable-start cri-o container runtime:
crio
grep "cgroup_manager" /etc/crio/crio.conf  # or /etc/crio/crio.conf.d/10-crio.conf
# If value is "cgroupfs" then it's cgroupv1, that we don't want, so need to edit value...
  vi /etc/crio/crio.conf # ... or /etc/crio/crio.conf.d/10-crio.conf and add/replace ==> cgroup_manager = "systemd"   // under crio.runtime block
  systemctl daemon-reload

# [crio.image]
# pause_image="registry.k8s.io/pause:3.10"

# Start-enable crio runtime container:
systemctl start crio
systemctl enable crio
systemctl status -l crio
# Clear console
clear

# Install kube tools
yum install -y libnetfilter_cthelper libnetfilter_cttimeout libnetfilter_queue conntrack-tools kubelet kubectl kubeadm helm --disableexcludes=kubernetes
# Clear console
clear

# Initialise the cluster from the master node (control-plane)
# However, we don't want kube-proxy, that job will be handled by cilium
systemctl enable kubelet
kubeadm config images pull
kubeadm init --skip-phases=addon/kube-proxy --pod-network-cidr=10.0.0.0/8 # default cilium cidr

# Add root as able to run kubectl commands:
mkdir -p $HOME/.kube
/bin/cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Start-enable kubelet
systemctl start kubelet
systemctl status kubelet
# Clear console
clear

# Make current (master) node able to run pods:
kubectl get nodes
kubectl describe node $(kubectl get nodes | grep -v "NAME" | cut -d" " -f1 | xargs)
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl label nodes --all node.kubernetes.io/exclude-from-external-load-balancers-
kubectl describe node $(kubectl get nodes | grep -v "NAME" | cut -d" " -f1 | xargs)
# Clear console
clear

# Deploy cilium and hubble-ui
helm repo add cilium https://helm.cilium.io/
API_SERVER_IP=192.168.10.65
API_SERVER_PORT=6443
helm upgrade --install cilium cilium/cilium --namespace kube-system \
--reuse-values \
--set k8sServiceHost=${API_SERVER_IP} \
--set k8sServicePort=${API_SERVER_PORT} \
--set kubeProxyReplacement=true \
--set operator.replicas=1 \
--set hubble.enabled=true \
--set hubble.relay.enabled=true \
--set hubble.ui.enabled=true
# Clear console
clear

# Wait 10-15 minutes and check cilium:
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose

# List all pods, should look like this:
[root@nano ~]# kubectl get pods -n kube-system
NAME                               READY   STATUS    RESTARTS   AGE
cilium-envoy-rrxd9                 1/1     Running   0          22m
cilium-operator-75c44f4bd8-8bzrg   1/1     Running   0          22m
cilium-zslsc                       1/1     Running   0          22m
coredns-66bc5c9577-cwmw5           1/1     Running   0          35m
coredns-66bc5c9577-zwq8r           1/1     Running   0          35m
etcd-nano                          1/1     Running   0          35m
hubble-relay-7bdfbfd78b-qdzpn      1/1     Running   0          15s
hubble-ui-576dcd986f-rpb4p         2/2     Running   0          22m
kube-apiserver-nano                1/1     Running   0          35m
kube-controller-manager-nano       1/1     Running   0          35m
kube-scheduler-nano                1/1     Running   0          35m

# Cleanup unused images
crictl rmi --prune
# [root@nano ~]# crictl rmi --prune
# Deleted: registry.k8s.io/kube-proxy:v1.34.1
# Deleted: registry.k8s.io/pause:3.10.1

# Download cilium and hubble CLI:
wget https://github.com/cilium/cilium-cli/releases/download/v0.18.7/cilium-linux-amd64.tar.gz
tar xf cilium-linux-amd64.tar.gz
rm -f cilium-linux-amd64.tar.gz
mv cilium /usr/local/sbin/
cilium status

# Download hubble CLI:
wget https://github.com/cilium/hubble/releases/download/v1.18.0/hubble-linux-amd64.tar.gz
tar xf hubble-linux-amd64.tar.gz
rm -f hubble-linux-amd64.tar.gz
mv hubble /usr/local/sbin/
hubble list nodes -P
hubble status -P

# Expose Hubble UI
kubectl edit svc hubble-ui -n kube-system
# Remove spec block and add this one:
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      targetPort: 8081
      nodePort: 30000
  selector:
    k8s-app: hubble-ui
# Wait a bit and access to Hubble UI using URL http://$(kubectl describe svc hubble-ui -n kube-system | grep "IP:" | cut -d":" -f2 | xargs):80

#################################################################################################
#################################################################################################
#################################################################################################
#################################################################################################
#################################################################################################


# RPM URLs
* https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/getPackage/crun-1.23.1-2.el9_6.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/developer/EPEL/x86_64/getPackage/htop-3.3.0-1.el9.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/getPackage/jq-1.6-17.el9.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/getPackage/xmlsec1-openssl-1.2.29-13.el9.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/getPackage/openssl-3.2.2-6.0.1.el9_5.1.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/getPackage/openssl-libs-3.2.2-6.0.1.el9_5.1.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/getPackage/wget-1.21.1-8.el9_4.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/developer/EPEL/x86_64/getPackage/yq-4.47.1-2.el9.x86_64.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/getPackage/yum-utils-4.3.0-20.0.1.el9.noarch.rpm
* https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/getPackage/zip-3.0-35.el9.x86_64.rpm
* cri-tools kubernetes-cni cri-o
* libnetfilter_cthelper libnetfilter_cttimeout libnetfilter_queue conntrack-tools kubelet kubectl kubeadm helm
* cilium CLI: https://github.com/cilium/cilium-cli/releases/download/v0.18.7/cilium-linux-amd64.tar.gz
* hubble CLI: https://github.com/cilium/hubble/releases/download/v1.18.0/hubble-linux-amd64.tar.gz

# Configuration files or systemd
* /etc/crio/crio.conf (cgroup_manager + pause_image="registry.k8s.io/pause:3.10")
* systemd kubelet
* TAR cilium helm folder
* kube svc hubble-ui (to switch from cluster IP to nodeport)
* 

# Docker images (base is kube 1.34.1) => TAR => github
[root@nano ~]# crictl images
IMAGE                                     TAG                 IMAGE ID            SIZE
quay.io/cilium/cilium-envoy               <none>              5b9199b8f90cc       186MB
quay.io/cilium/cilium                     <none>              db11d8ecd9884       721MB
quay.io/cilium/hubble-relay               <none>              4456983f292e4       94.3MB
quay.io/cilium/hubble-ui-backend          <none>              5ebbb858e3938       69.8MB
quay.io/cilium/hubble-ui                  <none>              e792110c58142       31.6MB
quay.io/cilium/operator-generic           <none>              d56c72ada0b89       117MB
registry.k8s.io/coredns/coredns           v1.12.1             52546a367cc9e       76.1MB
registry.k8s.io/etcd                      3.6.4-0             5f1f5298c888d       196MB
registry.k8s.io/kube-apiserver            v1.34.1             c3994bc696102       89MB
registry.k8s.io/kube-controller-manager   v1.34.1             c80c8dbafe7dd       76MB
registry.k8s.io/kube-scheduler            v1.34.1             7dd6aaa1717ab       53.8MB
registry.k8s.io/pause                     3.10                873ed75102791       742kB

