#!/bin/bash
# Cleanup script for eBPF Edge Node Selection experiment

set -e

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

# Clean up workloads
cleanup_workloads() {
    log "Cleaning up test workloads..."
    
    kubectl delete namespace workloads --ignore-not-found=true
    
    log "✓ Workloads cleaned up"
}

# Clean up monitoring stack
cleanup_monitoring() {
    log "Cleaning up monitoring stack..."
    
    helm uninstall prometheus -n monitoring --ignore-not-found=true || true
    kubectl delete namespace monitoring --ignore-not-found=true
    
    log "✓ Monitoring stack cleaned up"
}

# Clean up eBPF agent
cleanup_ebpf_agent() {
    log "Cleaning up eBPF agent..."
    
    kubectl delete -f ../ebpf-agent/manifests/ --ignore-not-found=true || true
    kubectl delete namespace observability --ignore-not-found=true
    
    log "✓ eBPF agent cleaned up"
}

# Clean up custom scheduler
cleanup_scheduler() {
    log "Cleaning up custom scheduler..."
    
    kubectl delete -f ../scheduler/manifests/ --ignore-not-found=true || true
    
    # Restore original scheduler if backup exists
    if [ -f ../scheduler/kube-scheduler-backup.yaml ]; then
        log "Restoring original scheduler..."
        kubectl apply -f ../scheduler/kube-scheduler-backup.yaml || warn "Failed to restore original scheduler"
    fi
    
    log "✓ Custom scheduler cleaned up"
}

# Clean up network conditions on all nodes
cleanup_network_conditions() {
    log "Cleaning up network conditions..."
    
    local nodes=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo))
    
    for node in "${nodes[@]}"; do
        if [ -n "$node" ]; then
            log "Cleaning network conditions on node: $node"
            
            # Remove tc rules
            ssh $node "sudo tc qdisc del dev eth0 root 2>/dev/null || true" || warn "Failed to clean tc rules on $node"
            
            # Kill stress processes
            ssh $node "pkill -f stress-ng || true" || warn "Failed to kill stress processes on $node"
            
            # Kill network condition scripts
            ssh $node "pkill -f 'tc qdisc' || true" || warn "Failed to kill tc scripts on $node"
        fi
    done
    
    log "✓ Network conditions cleaned up"
}

# Clean up container images
cleanup_images() {
    log "Cleaning up container images..."
    
    # Remove custom images if they exist
    docker rmi localhost:5000/ebpf-edge-agent:v0.1.0 2>/dev/null || true
    docker rmi localhost:5000/network-aware-scheduler:v0.1.0 2>/dev/null || true
    docker rmi ebpf-edge-agent:v0.1.0 2>/dev/null || true
    docker rmi network-aware-scheduler:v0.1.0 2>/dev/null || true
    
    log "✓ Container images cleaned up"
}

# Clean up temporary files
cleanup_temp_files() {
    log "Cleaning up temporary files..."
    
    # Remove experiment results
    rm -rf /tmp/experiment-results/* 2>/dev/null || true
    
    # Remove build artifacts
    rm -f ../ebpf-agent/*.o ../ebpf-agent/*.skel.h ../ebpf-agent/ebpf-agent 2>/dev/null || true
    rm -f ../scheduler/kube-scheduler ../scheduler/kube-scheduler_unix 2>/dev/null || true
    rm -f ../scheduler-extender/scheduler-extender 2>/dev/null || true
    
    # Remove join command files
    rm -f ../infrastructure/join-command.txt 2>/dev/null || true
    
    # Remove logs
    rm -f *.log 2>/dev/null || true
    
    log "✓ Temporary files cleaned up"
}

# Reset cluster to clean state
reset_cluster() {
    log "Resetting cluster to clean state..."
    
    # Remove taints that we might have added
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
    kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
    
    # Reset all deployments to use default scheduler
    for ns in workloads default; do
        for deployment in $(kubectl get deployments -n $ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo); do
            if [ -n "$deployment" ]; then
                kubectl patch deployment $deployment -n $ns -p '{"spec":{"template":{"spec":{"schedulerName":"default-scheduler"}}}}' 2>/dev/null || true
            fi
        done
    done
    
    log "✓ Cluster reset to clean state"
}

# Show cleanup status
show_status() {
    log "Checking cleanup status..."
    
    echo ""
    echo "📊 Cleanup Status:"
    
    # Check namespaces
    local ns_count=$(kubectl get namespaces --no-headers 2>/dev/null | grep -E "(workloads|monitoring|observability)" | wc -l || echo "0")
    echo "  Namespaces remaining: $ns_count"
    
    # Check pods
    local pod_count=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -E "(ebpf|scheduler|prometheus|grafana)" | wc -l || echo "0")
    echo "  Experiment pods remaining: $pod_count"
    
    # Check custom resources
    local crd_count=$(kubectl get crd --no-headers 2>/dev/null | grep -E "(monitoring|ebpf)" | wc -l || echo "0")
    echo "  Custom resources remaining: $crd_count"
    
    # Check images
    local image_count=$(docker images --format "table {{.Repository}}" 2>/dev/null | grep -E "(ebpf|scheduler)" | wc -l || echo "0")
    echo "  Custom images remaining: $image_count"
    
    echo ""
    
    if [ "$ns_count" -eq 0 ] && [ "$pod_count" -eq 0 ]; then
        log "✅ Cleanup completed successfully!"
    else
        warn "⚠️  Some resources may still remain. Manual cleanup might be needed."
    fi
}

# Destructive cleanup (for complete reset)
destructive_cleanup() {
    warn "🚨 DESTRUCTIVE CLEANUP - This will remove ALL resources!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "Cleanup cancelled"
        return
    fi
    
    log "Performing destructive cleanup..."
    
    # Remove all custom namespaces
    kubectl delete namespace workloads monitoring observability --ignore-not-found=true
    
    # Remove all Helm releases
    helm list --all-namespaces -q | xargs -r helm uninstall || true
    
    # Remove all custom CRDs
    kubectl delete crd --all || true
    
    # Reset kubeadm (WARNING: This will destroy the cluster)
    read -p "Do you want to reset the entire Kubernetes cluster? (yes/no): " reset_cluster
    if [ "$reset_cluster" == "yes" ]; then
        sudo kubeadm reset --force || true
        sudo rm -rf /etc/kubernetes/ || true
        sudo rm -rf ~/.kube/ || true
    fi
    
    log "🔥 Destructive cleanup completed"
}

# Show help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --workloads       Clean up test workloads only"
    echo "  --monitoring      Clean up monitoring stack only"
    echo "  --ebpf           Clean up eBPF agent only"
    echo "  --scheduler      Clean up custom scheduler only"
    echo "  --network        Clean up network conditions only"
    echo "  --images         Clean up container images only"
    echo "  --temp           Clean up temporary files only"
    echo "  --all            Clean up all components (default)"
    echo "  --destructive    Destructive cleanup (removes everything)"
    echo "  --status         Show cleanup status"
    echo "  --help           Show this help message"
}

# Main execution
main() {
    local action="all"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --workloads)
                action="workloads"
                shift
                ;;
            --monitoring)
                action="monitoring"
                shift
                ;;
            --ebpf)
                action="ebpf"
                shift
                ;;
            --scheduler)
                action="scheduler"
                shift
                ;;
            --network)
                action="network"
                shift
                ;;
            --images)
                action="images"
                shift
                ;;
            --temp)
                action="temp"
                shift
                ;;
            --all)
                action="all"
                shift
                ;;
            --destructive)
                action="destructive"
                shift
                ;;
            --status)
                action="status"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    log "🧹 Starting cleanup process..."
    
    case $action in
        workloads)
            cleanup_workloads
            ;;
        monitoring)
            cleanup_monitoring
            ;;
        ebpf)
            cleanup_ebpf_agent
            ;;
        scheduler)
            cleanup_scheduler
            ;;
        network)
            cleanup_network_conditions
            ;;
        images)
            cleanup_images
            ;;
        temp)
            cleanup_temp_files
            ;;
        all)
            cleanup_network_conditions
            cleanup_workloads
            cleanup_monitoring
            cleanup_ebpf_agent
            cleanup_scheduler
            cleanup_images
            cleanup_temp_files
            reset_cluster
            ;;
        destructive)
            destructive_cleanup
            ;;
        status)
            show_status
            exit 0
            ;;
    esac
    
    show_status
    
    log "🎉 Cleanup process completed!"
}

# Handle script interruption
cleanup_handler() {
    error "Cleanup script interrupted"
    exit 1
}

trap cleanup_handler SIGINT SIGTERM

# Run main function
main "$@"
