#!/bin/bash
# Main experiment execution script

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Configuration
SCENARIO=${1:-S1}
MODE=${2:-proposed}
RPS=${3:-500}
REPLICAS=${4:-5}
DURATION=${5:-600}  # 10 minutes
WARMUP=${6:-300}    # 5 minutes
COOLDOWN=${7:-300}  # 5 minutes

RESULTS_DIR="/tmp/experiment-results/$(date +%Y%m%d-%H%M%S)"
PROMETHEUS_URL="http://localhost:30090"

# Validate inputs
validate_inputs() {
    case $SCENARIO in
        S1|S2|S3|S4|S5) ;;
        *) error "Invalid scenario: $SCENARIO. Use S1-S5"; exit 1 ;;
    esac
    
    case $MODE in
        baseline|networkaware|proposed) ;;
        *) error "Invalid mode: $MODE. Use baseline, networkaware, or proposed"; exit 1 ;;
    esac
    
    if ! [[ "$RPS" =~ ^[0-9]+$ ]] || [ "$RPS" -lt 1 ]; then
        error "Invalid RPS: $RPS. Must be positive integer"
        exit 1
    fi
    
    mkdir -p "$RESULTS_DIR"
}

# Setup scheduling mode
setup_scheduler() {
    local mode=$1
    log "Setting up scheduler mode: $mode"
    
    case $mode in
        baseline)
            # Use default Kubernetes scheduler
            kubectl patch deployment https-echo -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"default-scheduler"}}}}'
            kubectl patch deployment inference-service -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"default-scheduler"}}}}'
            kubectl patch deployment frontend -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"default-scheduler"}}}}'
            kubectl patch deployment api -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"default-scheduler"}}}}'
            kubectl patch deployment cache -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"default-scheduler"}}}}'
            ;;
        networkaware)
            # Use network-aware scheduler (placeholder - could be an existing solution)
            warn "NetworkAware mode not fully implemented, using proposed mode"
            kubectl patch deployment https-echo -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment inference-service -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment frontend -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment api -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment cache -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            ;;
        proposed)
            # Use our eBPF-based scheduler
            kubectl patch deployment https-echo -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment inference-service -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment frontend -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment api -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            kubectl patch deployment cache -n workloads -p '{"spec":{"template":{"spec":{"schedulerName":"network-aware-scheduler"}}}}'
            ;;
    esac
    
    # Wait for rollout to complete
    kubectl rollout status deployment/https-echo -n workloads --timeout=300s
    kubectl rollout status deployment/inference-service -n workloads --timeout=300s
    kubectl rollout status deployment/frontend -n workloads --timeout=300s
    kubectl rollout status deployment/api -n workloads --timeout=300s
    kubectl rollout status deployment/cache -n workloads --timeout=300s
    
    log "✓ Scheduler mode $mode configured"
}

# Apply network conditions for scenarios
apply_scenario() {
    local scenario=$1
    log "Applying scenario: $scenario"
    
    # Get list of worker nodes
    local nodes=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name | grep -v master || true))
    
    case $scenario in
        S1)
            log "S1: Applying network latency (20ms ± 5ms)"
            for node in "${nodes[@]}"; do
                ssh $node "sudo tc qdisc add dev eth0 root netem delay 20ms 5ms distribution normal" || warn "Failed to apply latency to $node"
            done
            ;;
        S2)
            log "S2: Applying packet loss (2%)"
            for node in "${nodes[@]}"; do
                ssh $node "sudo tc qdisc add dev eth0 root netem loss 2%" || warn "Failed to apply loss to $node"
            done
            ;;
        S3)
            log "S3: Applying bandwidth limit (50Mbit)"
            for node in "${nodes[@]}"; do
                ssh $node "sudo tc qdisc add dev eth0 root tbf rate 50mbit burst 32kbit latency 400ms" || warn "Failed to apply bandwidth limit to $node"
            done
            ;;
        S4)
            log "S4: Applying CPU pressure"
            for node in "${nodes[@]}"; do
                ssh $node "nohup stress-ng --cpu 2 --timeout ${DURATION}s --metrics-brief > /tmp/stress-\$HOSTNAME.log 2>&1 &" || warn "Failed to apply CPU stress to $node"
            done
            ;;
        S5)
            log "S5: Applying intermittent network failures"
            for node in "${nodes[@]}"; do
                ssh $node "nohup bash -c 'while true; do sudo tc qdisc add dev eth0 root netem loss 10%; sleep 10; sudo tc qdisc del dev eth0 root; sleep 10; done' > /tmp/intermittent-\$HOSTNAME.log 2>&1 &" || warn "Failed to apply intermittent failures to $node"
            done
            ;;
    esac
    
    log "✓ Scenario $scenario applied"
}

# Remove network conditions
cleanup_scenario() {
    local scenario=$1
    log "Cleaning up scenario: $scenario"
    
    local nodes=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name | grep -v master || true))
    
    for node in "${nodes[@]}"; do
        # Remove tc rules
        ssh $node "sudo tc qdisc del dev eth0 root 2>/dev/null || true"
        
        # Kill stress processes
        ssh $node "pkill -f stress-ng || true"
        ssh $node "pkill -f 'tc qdisc' || true"
    done
    
    log "✓ Scenario cleanup complete"
}

# Run load test
run_load_test() {
    local rps=$1
    local duration=$2
    local target_url=$3
    local output_file=$4
    
    log "Running load test: RPS=$rps, Duration=${duration}s, Target=$target_url"
    
    # Use Fortio for load testing
    if ! command -v fortio &> /dev/null; then
        warn "Fortio not found, installing..."
        curl -L https://github.com/fortio/fortio/releases/download/v1.63.0/fortio_linux_amd64.tar.gz | tar xz
        sudo mv fortio /usr/local/bin/
    fi
    
    # Run load test
    fortio load -c 10 -qps $rps -t ${duration}s -json $output_file $target_url
    
    log "✓ Load test completed, results saved to $output_file"
}

# Collect metrics from Prometheus
collect_metrics() {
    local start_time=$1
    local end_time=$2
    local output_file=$3
    
    log "Collecting metrics from Prometheus..."
    
    # Define queries for metrics collection
    local queries=(
        "ebpf_rtt_p50_milliseconds"
        "ebpf_rtt_p99_milliseconds"
        "ebpf_tcp_retrans_rate"
        "ebpf_drop_rate"
        "ebpf_runqlat_p95_milliseconds"
        "ebpf_cpu_utilization"
        "scheduler_framework_score"
        "scheduler_e2e_scheduling_latency_seconds"
        "container_cpu_usage_seconds_total"
        "container_memory_usage_bytes"
    )
    
    local metrics_file="$output_file"
    echo "timestamp,metric,node,value" > $metrics_file
    
    for query in "${queries[@]}"; do
        log "Collecting metric: $query"
        
        # Query Prometheus (simplified - would need proper API calls)
        curl -s "${PROMETHEUS_URL}/api/v1/query_range?query=${query}&start=${start_time}&end=${end_time}&step=5s" \
            | jq -r '.data.result[]? | .metric.node as $node | .values[]? | [.[0], "'$query'", ($node // "unknown"), .[1]] | @csv' \
            >> $metrics_file || warn "Failed to collect $query"
    done
    
    log "✓ Metrics collected to $metrics_file"
}

# Analyze results
analyze_results() {
    local results_dir=$1
    log "Analyzing experimental results..."
    
    # Create analysis script
    cat > $results_dir/analyze.py << 'EOF'
#!/usr/bin/env python3
import json
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
from pathlib import Path
import sys

def load_fortio_results(file_path):
    """Load Fortio JSON results"""
    with open(file_path, 'r') as f:
        data = json.load(f)
    
    # Extract key metrics
    histogram = data.get('DurationHistogram', {})
    percentiles = histogram.get('Percentiles', [])
    
    results = {
        'p50_ms': next((p['Value'] * 1000 for p in percentiles if p['Percentile'] == 50), None),
        'p99_ms': next((p['Value'] * 1000 for p in percentiles if p['Percentile'] == 99), None),
        'avg_ms': histogram.get('Avg', 0) * 1000,
        'qps': data.get('ActualQPS', 0),
        'error_rate': (data.get('ErrorsDurationHistogram', {}).get('Count', 0) / 
                      max(data.get('DurationHistogram', {}).get('Count', 1), 1)) * 100,
        'total_requests': data.get('DurationHistogram', {}).get('Count', 0)
    }
    
    return results

def load_metrics(file_path):
    """Load Prometheus metrics"""
    try:
        df = pd.read_csv(file_path)
        return df
    except:
        return pd.DataFrame()

def create_summary_report(results_dir):
    """Create summary analysis report"""
    results_dir = Path(results_dir)
    
    # Find all result files
    fortio_files = list(results_dir.glob("*_fortio.json"))
    metrics_files = list(results_dir.glob("*_metrics.csv"))
    
    summary = []
    
    for fortio_file in fortio_files:
        # Extract experiment parameters from filename
        parts = fortio_file.stem.replace('_fortio', '').split('_')
        if len(parts) >= 3:
            scenario, mode, rps = parts[:3]
            
            # Load results
            fortio_results = load_fortio_results(fortio_file)
            
            # Find corresponding metrics file
            metrics_file = results_dir / f"{scenario}_{mode}_{rps}_metrics.csv"
            metrics_df = load_metrics(metrics_file)
            
            # Calculate average eBPF metrics during test
            avg_rtt_p99 = metrics_df[metrics_df['metric'] == 'ebpf_rtt_p99_milliseconds']['value'].astype(float).mean() if not metrics_df.empty else 0
            avg_retrans = metrics_df[metrics_df['metric'] == 'ebpf_tcp_retrans_rate']['value'].astype(float).mean() if not metrics_df.empty else 0
            avg_drops = metrics_df[metrics_df['metric'] == 'ebpf_drop_rate']['value'].astype(float).mean() if not metrics_df.empty else 0
            avg_cpu = metrics_df[metrics_df['metric'] == 'ebpf_cpu_utilization']['value'].astype(float).mean() if not metrics_df.empty else 0
            
            summary.append({
                'scenario': scenario,
                'mode': mode,
                'rps': int(rps),
                'p50_latency_ms': fortio_results['p50_ms'],
                'p99_latency_ms': fortio_results['p99_ms'],
                'error_rate_pct': fortio_results['error_rate'],
                'actual_qps': fortio_results['qps'],
                'avg_rtt_p99_ms': avg_rtt_p99,
                'avg_retrans_rate': avg_retrans,
                'avg_drop_rate': avg_drops,
                'avg_cpu_util': avg_cpu
            })
    
    # Create DataFrame and save
    df = pd.DataFrame(summary)
    if not df.empty:
        df.to_csv(results_dir / 'experiment_summary.csv', index=False)
        
        # Create visualizations
        create_plots(df, results_dir)
        
        print("Experiment Summary:")
        print(df.to_string(index=False))
        
        # Statistical analysis
        perform_statistical_analysis(df, results_dir)
    
    return df

def create_plots(df, results_dir):
    """Create visualization plots"""
    if df.empty:
        return
    
    plt.style.use('seaborn-v0_8')
    fig, axes = plt.subplots(2, 3, figsize=(18, 12))
    fig.suptitle('eBPF Edge Node Selection - Experimental Results', fontsize=16)
    
    # P99 Latency by Mode and Scenario
    sns.barplot(data=df, x='scenario', y='p99_latency_ms', hue='mode', ax=axes[0,0])
    axes[0,0].set_title('P99 Latency by Scenario and Mode')
    axes[0,0].set_ylabel('P99 Latency (ms)')
    
    # Error Rate
    sns.barplot(data=df, x='scenario', y='error_rate_pct', hue='mode', ax=axes[0,1])
    axes[0,1].set_title('Error Rate by Scenario and Mode')
    axes[0,1].set_ylabel('Error Rate (%)')
    
    # Throughput
    sns.barplot(data=df, x='scenario', y='actual_qps', hue='mode', ax=axes[0,2])
    axes[0,2].set_title('Actual QPS by Scenario and Mode')
    axes[0,2].set_ylabel('QPS')
    
    # eBPF Metrics
    sns.barplot(data=df, x='scenario', y='avg_rtt_p99_ms', hue='mode', ax=axes[1,0])
    axes[1,0].set_title('Average RTT P99 (eBPF)')
    axes[1,0].set_ylabel('RTT P99 (ms)')
    
    sns.barplot(data=df, x='scenario', y='avg_retrans_rate', hue='mode', ax=axes[1,1])
    axes[1,1].set_title('Average Retransmission Rate')
    axes[1,1].set_ylabel('Retrans/sec')
    
    sns.barplot(data=df, x='scenario', y='avg_cpu_util', hue='mode', ax=axes[1,2])
    axes[1,2].set_title('Average CPU Utilization')
    axes[1,2].set_ylabel('CPU %')
    
    plt.tight_layout()
    plt.savefig(results_dir / 'experiment_results.png', dpi=300, bbox_inches='tight')
    plt.close()

def perform_statistical_analysis(df, results_dir):
    """Perform statistical analysis and save results"""
    from scipy import stats
    
    analysis = []
    
    # Compare baseline vs proposed for each scenario
    for scenario in df['scenario'].unique():
        scenario_df = df[df['scenario'] == scenario]
        
        baseline_data = scenario_df[scenario_df['mode'] == 'baseline']
        proposed_data = scenario_df[scenario_df['mode'] == 'proposed']
        
        if len(baseline_data) > 0 and len(proposed_data) > 0:
            # Mann-Whitney U test for p99 latency
            if len(baseline_data['p99_latency_ms']) > 0 and len(proposed_data['p99_latency_ms']) > 0:
                statistic, p_value = stats.mannwhitneyu(
                    baseline_data['p99_latency_ms'], 
                    proposed_data['p99_latency_ms'],
                    alternative='two-sided'
                )
                
                # Calculate effect size (median difference)
                effect_size = np.median(proposed_data['p99_latency_ms']) - np.median(baseline_data['p99_latency_ms'])
                improvement_pct = (effect_size / np.median(baseline_data['p99_latency_ms'])) * 100
                
                analysis.append({
                    'scenario': scenario,
                    'metric': 'p99_latency_ms',
                    'baseline_median': np.median(baseline_data['p99_latency_ms']),
                    'proposed_median': np.median(proposed_data['p99_latency_ms']),
                    'effect_size': effect_size,
                    'improvement_pct': improvement_pct,
                    'p_value': p_value,
                    'significant': p_value < 0.05
                })
    
    # Save statistical analysis
    if analysis:
        stats_df = pd.DataFrame(analysis)
        stats_df.to_csv(results_dir / 'statistical_analysis.csv', index=False)
        print("\nStatistical Analysis:")
        print(stats_df.to_string(index=False))

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 analyze.py <results_directory>")
        sys.exit(1)
    
    results_dir = sys.argv[1]
    summary_df = create_summary_report(results_dir)
EOF

    # Run analysis
    python3 $results_dir/analyze.py $results_dir
    
    log "✓ Analysis complete, results saved to $results_dir"
}

# Main experiment execution
run_experiment() {
    local scenario=$1
    local mode=$2
    local rps=$3
    local replicas=$4
    
    log "🧪 Starting experiment: Scenario=$scenario, Mode=$mode, RPS=$rps, Replicas=$replicas"
    
    local experiment_id="${scenario}_${mode}_${rps}_$(date +%H%M%S)"
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
    
    # Setup scheduler mode
    setup_scheduler $mode
    
    # Apply scenario conditions
    apply_scenario $scenario
    
    # Wait for conditions to stabilize
    log "Waiting for conditions to stabilize..."
    sleep 30
    
    # Record start time
    local start_time=$(date +%s)
    
    # Warmup phase
    log "Starting warmup phase (${WARMUP}s)..."
    run_load_test $rps $WARMUP "http://$node_ip:30080" "$RESULTS_DIR/${experiment_id}_warmup.json" &
    local warmup_pid=$!
    
    wait $warmup_pid
    log "✓ Warmup phase completed"
    
    # Main measurement phase
    log "Starting measurement phase (${DURATION}s)..."
    local measure_start=$(date +%s)
    
    # Run load tests on multiple endpoints
    run_load_test $rps $DURATION "http://$node_ip:30080" "$RESULTS_DIR/${experiment_id}_https_fortio.json" &
    local https_pid=$!
    
    run_load_test $((rps/2)) $DURATION "http://$node_ip:30081?complexity=1000" "$RESULTS_DIR/${experiment_id}_inference_fortio.json" &
    local inference_pid=$!
    
    run_load_test $((rps/3)) $DURATION "http://$node_ip:30082" "$RESULTS_DIR/${experiment_id}_microservices_fortio.json" &
    local microservices_pid=$!
    
    # Wait for load tests to complete
    wait $https_pid $inference_pid $microservices_pid
    
    local measure_end=$(date +%s)
    log "✓ Measurement phase completed"
    
    # Collect metrics
    collect_metrics $measure_start $measure_end "$RESULTS_DIR/${experiment_id}_metrics.csv"
    
    # Cooldown phase
    log "Starting cooldown phase (${COOLDOWN}s)..."
    sleep $COOLDOWN
    
    # Cleanup scenario conditions
    cleanup_scenario $scenario
    
    # Save experiment metadata
    cat > "$RESULTS_DIR/${experiment_id}_metadata.json" << EOF
{
    "experiment_id": "$experiment_id",
    "scenario": "$scenario",
    "mode": "$mode",
    "rps": $rps,
    "replicas": $replicas,
    "duration": $DURATION,
    "warmup": $WARMUP,
    "cooldown": $COOLDOWN,
    "start_time": $start_time,
    "measure_start": $measure_start,
    "measure_end": $measure_end,
    "node_ip": "$node_ip",
    "kubernetes_version": "$(kubectl version --short --client)",
    "kernel_version": "$(uname -r)"
}
EOF

    log "🎉 Experiment $experiment_id completed successfully!"
    log "Results saved to: $RESULTS_DIR"
}

# Run multiple replicas
run_replicated_experiment() {
    log "Running replicated experiment: $REPLICAS replicas"
    
    for i in $(seq 1 $REPLICAS); do
        log "Running replica $i of $REPLICAS..."
        run_experiment $SCENARIO $MODE $RPS 1
        
        # Wait between replicas
        if [ $i -lt $REPLICAS ]; then
            log "Waiting 60s before next replica..."
            sleep 60
        fi
    done
    
    # Analyze all results
    analyze_results $RESULTS_DIR
}

# Main execution
main() {
    log "🚀 eBPF Edge Node Selection Experiment"
    log "Scenario: $SCENARIO, Mode: $MODE, RPS: $RPS, Replicas: $REPLICAS"
    
    validate_inputs
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not installed"
        exit 1
    fi
    
    # Check cluster status
    if ! kubectl cluster-info &> /dev/null; then
        error "Kubernetes cluster is not accessible"
        exit 1
    fi
    
    # Check if workloads are deployed
    if ! kubectl get deployment https-echo -n workloads &> /dev/null; then
        error "Test workloads are not deployed. Run: cd ../workloads && ./deploy.sh"
        exit 1
    fi
    
    run_replicated_experiment
    
    log "🏁 All experiments completed!"
    log "Results directory: $RESULTS_DIR"
    
    # Show final summary
    if [ -f "$RESULTS_DIR/experiment_summary.csv" ]; then
        log "Experiment Summary:"
        cat "$RESULTS_DIR/experiment_summary.csv"
    fi
}

# Handle script interruption
cleanup() {
    error "Experiment interrupted, cleaning up..."
    cleanup_scenario $SCENARIO || true
    exit 1
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
