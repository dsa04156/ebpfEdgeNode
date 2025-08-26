#!/bin/bash
# Setup Kubernetes cluster with Cilium CNI for eBPF experiments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Configuration
KUBERNETES_VERSION="1.28.4"
CILIUM_VERSION="1.15.5"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   error "This script should not be run as root"
   exit 1
fi

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if kubeadm, kubelet, kubectl are installed
    local missing_tools=()
    
    for tool in kubeadm kubelet kubectl; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing tools: ${missing_tools[*]}"
        log "Please install Kubernetes tools first:"
        log "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -"
        log "echo 'deb https://apt.kubernetes.io/ kubernetes-xenial main' | sudo tee /etc/apt/sources.list.d/kubernetes.list"
        log "sudo apt update && sudo apt install -y kubelet=$KUBERNETES_VERSION kubeadm=$KUBERNETES_VERSION kubectl=$KUBERNETES_VERSION"
        exit 1
    fi
    
    # Check kernel version
    local kernel_version=$(uname -r)
    log "Kernel version: $kernel_version"
    
    # Check if eBPF is supported
    if [ ! -f /sys/kernel/btf/vmlinux ]; then
        warn "BTF support not detected. Some eBPF features may not work."
    else
        log "✓ BTF support detected"
    fi
    
    # Check if required kernel modules are available
    local required_modules=("br_netfilter" "overlay")
    for module in "${required_modules[@]}"; do
        if ! lsmod | grep -q $module; then
            log "Loading kernel module: $module"
            sudo modprobe $module
        fi
    done
}

# Configure system settings
configure_system() {
    log "Configuring system settings..."
    
    # Disable swap
    sudo swapoff -a
    sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    
    # Configure kernel parameters
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sudo sysctl --system
    
    # Install container runtime (containerd)
    if ! command -v containerd &> /dev/null; then
        log "Installing containerd..."
        sudo apt-get update
        sudo apt-get install -y containerd
        
        # Configure containerd
        sudo mkdir -p /etc/containerd
        containerd config default | sudo tee /etc/containerd/config.toml
        
        # Enable SystemdCgroup
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
        
        sudo systemctl restart containerd
        sudo systemctl enable containerd
    fi
}

# Initialize master node
init_master() {
    log "Initializing Kubernetes master node..."
    
    # Initialize kubeadm
    sudo kubeadm init \
        --kubernetes-version=$KUBERNETES_VERSION \
        --pod-network-cidr=$POD_CIDR \
        --service-cidr=$SERVICE_CIDR \
        --skip-phases=addon/kube-proxy
    
    # Configure kubectl
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
    log "✓ Master node initialized"
    
    # Save join command for worker nodes
    sudo kubeadm token create --print-join-command > join-command.txt
    log "Join command saved to join-command.txt"
}

# Install Cilium CNI
install_cilium() {
    log "Installing Cilium CNI..."
    
    # Install cilium CLI
    if ! command -v cilium &> /dev/null; then
        log "Installing Cilium CLI..."
        CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
        CLI_ARCH=amd64
        if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
        curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
        sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
        rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    fi
    
    # Install Cilium with eBPF kube-proxy replacement
    cilium install \
        --version $CILIUM_VERSION \
        --set kubeProxyReplacement=true \
        --set bpf.monitorAggregation=medium \
        --set socketLB.enabled=true \
        --set externalIPs.enabled=true \
        --set nodePort.enabled=true \
        --set hostPort.enabled=true \
        --set bpf.masquerade=true \
        --set tunnel=vxlan \
        --set prometheus.enabled=true \
        --set operator.prometheus.enabled=true \
        --set hubble.enabled=true \
        --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}"
    
    log "Waiting for Cilium to be ready..."
    cilium status --wait
    
    # Verify installation
    log "Verifying Cilium installation..."
    cilium connectivity test --single-node
    
    log "✓ Cilium CNI installed and verified"
}

# Remove taint from master node (for single-node cluster or master scheduling)
configure_master_scheduling() {
    log "Configuring master node for scheduling..."
    
    # Remove taint to allow scheduling on master
    kubectl taint nodes --all node-role.kubernetes.io/control-plane-
    kubectl taint nodes --all node-role.kubernetes.io/master- || true
    
    log "✓ Master node configured for scheduling"
}

# Install additional tools
install_tools() {
    log "Installing additional tools..."
    
    # Install Helm
    if ! command -v helm &> /dev/null; then
        log "Installing Helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    
    # Install bpftool for debugging
    if ! command -v bpftool &> /dev/null; then
        log "Installing bpftool..."
        sudo apt-get update
        sudo apt-get install -y linux-tools-common linux-tools-generic
    fi
    
    # Install bpftrace for smoke testing
    if ! command -v bpftrace &> /dev/null; then
        log "Installing bpftrace..."
        sudo apt-get install -y bpftrace
    fi
    
    log "✓ Additional tools installed"
}

# Verify cluster status
verify_cluster() {
    log "Verifying cluster status..."
    
    # Check node status
    kubectl get nodes -o wide
    
    # Check system pods
    kubectl get pods -A
    
    # Check Cilium status
    cilium status
    
    log "✓ Cluster verification complete"
}

# Main execution
main() {
    log "Starting Kubernetes cluster setup for eBPF experiments"
    log "Kubernetes version: $KUBERNETES_VERSION"
    log "Cilium version: $CILIUM_VERSION"
    
    check_prerequisites
    configure_system
    init_master
    install_cilium
    configure_master_scheduling
    install_tools
    verify_cluster
    
    log "🎉 Kubernetes cluster setup complete!"
    log ""
    log "Next steps:"
    log "1. For worker nodes, copy and run the join command from join-command.txt"
    log "2. Deploy monitoring stack: cd ../monitoring && ./deploy.sh"
    log "3. Deploy eBPF agent: cd ../ebpf-agent && make deploy"
    log "4. Deploy custom scheduler: cd ../scheduler && make deploy"
}

# Handle script interruption
cleanup() {
    error "Script interrupted"
    exit 1
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
