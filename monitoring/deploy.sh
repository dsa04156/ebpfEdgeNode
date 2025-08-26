#!/bin/bash
# Deploy Prometheus and Grafana monitoring stack

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

# Install monitoring stack using kube-prometheus-stack
install_prometheus_stack() {
    log "Installing Prometheus monitoring stack..."
    
    # Add Prometheus community Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Install kube-prometheus-stack
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.retention=7d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
        --set grafana.adminPassword=admin123 \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.size=5Gi \
        --set alertmanager.enabled=true \
        --set nodeExporter.enabled=true \
        --set kubeStateMetrics.enabled=true \
        --wait --timeout=600s
    
    log "✓ Prometheus stack installed"
}

# Configure Prometheus to scrape eBPF agent metrics
configure_prometheus() {
    log "Configuring Prometheus for eBPF metrics..."
    
    # Apply ServiceMonitor for eBPF agent
    cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ebpf-edge-agent
  namespace: monitoring
  labels:
    app: ebpf-edge-agent
spec:
  selector:
    matchLabels:
      app: ebpf-edge-agent
  namespaceSelector:
    matchNames:
    - observability
  endpoints:
  - port: metrics
    interval: 5s
    path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: network-aware-scheduler
  namespace: monitoring
  labels:
    app: network-aware-scheduler
spec:
  selector:
    matchLabels:
      app: network-aware-scheduler
  namespaceSelector:
    matchNames:
    - kube-system
  endpoints:
  - port: metrics
    interval: 10s
    path: /metrics
EOF

    log "✓ Prometheus configured for eBPF metrics"
}

# Install Grafana dashboards
install_dashboards() {
    log "Installing Grafana dashboards..."
    
    # Wait for Grafana to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s
    
    # Apply ConfigMap with custom dashboards
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ebpf-dashboards
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  ebpf-network-metrics.json: |
    {
      "dashboard": {
        "id": null,
        "title": "eBPF Network Telemetry",
        "tags": ["ebpf", "networking"],
        "style": "dark",
        "timezone": "browser",
        "panels": [
          {
            "id": 1,
            "title": "RTT Percentiles",
            "type": "graph",
            "targets": [
              {
                "expr": "ebpf_rtt_p50_milliseconds",
                "legendFormat": "p50 - {{node}}"
              },
              {
                "expr": "ebpf_rtt_p99_milliseconds",
                "legendFormat": "p99 - {{node}}"
              }
            ],
            "yAxes": [
              {
                "label": "Milliseconds",
                "min": 0
              }
            ],
            "xAxis": {
              "mode": "time"
            },
            "gridPos": {
              "h": 8,
              "w": 12,
              "x": 0,
              "y": 0
            }
          },
          {
            "id": 2,
            "title": "TCP Retransmission Rate",
            "type": "graph",
            "targets": [
              {
                "expr": "rate(ebpf_tcp_retrans_rate[1m])",
                "legendFormat": "{{node}}"
              }
            ],
            "yAxes": [
              {
                "label": "Rate/sec",
                "min": 0
              }
            ],
            "gridPos": {
              "h": 8,
              "w": 12,
              "x": 12,
              "y": 0
            }
          },
          {
            "id": 3,
            "title": "Packet Drop Rate",
            "type": "graph",
            "targets": [
              {
                "expr": "rate(ebpf_drop_rate[1m])",
                "legendFormat": "{{node}}"
              }
            ],
            "yAxes": [
              {
                "label": "Drops/sec",
                "min": 0
              }
            ],
            "gridPos": {
              "h": 8,
              "w": 12,
              "x": 0,
              "y": 8
            }
          },
          {
            "id": 4,
            "title": "Scheduler Queue Latency",
            "type": "graph",
            "targets": [
              {
                "expr": "ebpf_runqlat_p95_milliseconds",
                "legendFormat": "p95 - {{node}}"
              }
            ],
            "yAxes": [
              {
                "label": "Milliseconds",
                "min": 0
              }
            ],
            "gridPos": {
              "h": 8,
              "w": 12,
              "x": 12,
              "y": 8
            }
          },
          {
            "id": 5,
            "title": "CPU Utilization",
            "type": "graph",
            "targets": [
              {
                "expr": "ebpf_cpu_utilization",
                "legendFormat": "{{node}}"
              }
            ],
            "yAxes": [
              {
                "label": "Percentage",
                "min": 0,
                "max": 100
              }
            ],
            "gridPos": {
              "h": 8,
              "w": 24,
              "x": 0,
              "y": 16
            }
          }
        ],
        "time": {
          "from": "now-1h",
          "to": "now"
        },
        "refresh": "5s"
      }
    }
  scheduler-metrics.json: |
    {
      "dashboard": {
        "id": null,
        "title": "Network-Aware Scheduler",
        "tags": ["scheduler", "kubernetes"],
        "style": "dark",
        "timezone": "browser",
        "panels": [
          {
            "id": 1,
            "title": "Node Scores",
            "type": "graph",
            "targets": [
              {
                "expr": "scheduler_framework_score",
                "legendFormat": "{{node}}"
              }
            ],
            "yAxes": [
              {
                "label": "Score",
                "min": 0,
                "max": 100
              }
            ],
            "gridPos": {
              "h": 8,
              "w": 12,
              "x": 0,
              "y": 0
            }
          },
          {
            "id": 2,
            "title": "Scheduling Latency",
            "type": "graph",
            "targets": [
              {
                "expr": "histogram_quantile(0.99, rate(scheduler_e2e_scheduling_latency_seconds_bucket[5m]))",
                "legendFormat": "p99"
              },
              {
                "expr": "histogram_quantile(0.50, rate(scheduler_e2e_scheduling_latency_seconds_bucket[5m]))",
                "legendFormat": "p50"
              }
            ],
            "yAxes": [
              {
                "label": "Seconds",
                "min": 0
              }
            ],
            "gridPos": {
              "h": 8,
              "w": 12,
              "x": 12,
              "y": 0
            }
          }
        ],
        "time": {
          "from": "now-1h",
          "to": "now"
        },
        "refresh": "10s"
      }
    }
EOF

    log "✓ Grafana dashboards installed"
}

# Expose services for access
expose_services() {
    log "Exposing monitoring services..."
    
    # Expose Prometheus
    kubectl patch svc prometheus-kube-prometheus-prometheus -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"port": 9090, "nodePort": 30090}]}}'
    
    # Expose Grafana
    kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "nodePort": 30300}]}}'
    
    # Expose Alertmanager
    kubectl patch svc prometheus-kube-prometheus-alertmanager -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"port": 9093, "nodePort": 30093}]}}'
    
    log "✓ Services exposed:"
    log "  Prometheus: http://localhost:30090"
    log "  Grafana: http://localhost:30300 (admin/admin123)"
    log "  Alertmanager: http://localhost:30093"
}

# Verify installation
verify_installation() {
    log "Verifying monitoring stack installation..."
    
    # Check pods
    kubectl get pods -n monitoring
    
    # Check services
    kubectl get svc -n monitoring
    
    # Wait for all pods to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s
    
    log "✓ Monitoring stack verification complete"
}

# Main execution
main() {
    log "Deploying Prometheus and Grafana monitoring stack..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not installed"
        exit 1
    fi
    
    # Check if helm is available
    if ! command -v helm &> /dev/null; then
        error "helm is required but not installed"
        exit 1
    fi
    
    install_prometheus_stack
    configure_prometheus
    install_dashboards
    expose_services
    verify_installation
    
    log "🎉 Monitoring stack deployment complete!"
    log ""
    log "Access URLs:"
    log "  Prometheus: http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):30090"
    log "  Grafana: http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):30300"
    log "  Username: admin, Password: admin123"
}

# Handle script interruption
cleanup() {
    error "Script interrupted"
    exit 1
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
