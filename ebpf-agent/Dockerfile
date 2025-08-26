FROM ubuntu:22.04

RUN apt-get update && apt-get install -y python3 python3-pip && \
    pip3 install prometheus_client psutil && \
    rm -rf /var/lib/apt/lists/*

COPY simple_agent /usr/local/bin/
COPY simple_telemetry.bpf.o /usr/local/bin/

# Create a simple metrics server
RUN echo '#!/usr/bin/env python3' > /usr/local/bin/metrics_server.py && \
    echo 'import time' >> /usr/local/bin/metrics_server.py && \
    echo 'import random' >> /usr/local/bin/metrics_server.py && \
    echo 'from prometheus_client import start_http_server, Histogram, Counter' >> /usr/local/bin/metrics_server.py && \
    echo 'import socket' >> /usr/local/bin/metrics_server.py && \
    echo '' >> /usr/local/bin/metrics_server.py && \
    echo 'rtt_histogram = Histogram("node_network_rtt_seconds", "Network RTT", buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0])' >> /usr/local/bin/metrics_server.py && \
    echo 'packet_counter = Counter("node_network_packets_total", "Network packets", ["type"])' >> /usr/local/bin/metrics_server.py && \
    echo '' >> /usr/local/bin/metrics_server.py && \
    echo 'def collect_metrics():' >> /usr/local/bin/metrics_server.py && \
    echo '    while True:' >> /usr/local/bin/metrics_server.py && \
    echo '        # Simulate RTT collection based on node' >> /usr/local/bin/metrics_server.py && \
    echo '        hostname = socket.gethostname()' >> /usr/local/bin/metrics_server.py && \
    echo '        if "cluster1" in hostname:' >> /usr/local/bin/metrics_server.py && \
    echo '            rtt = random.uniform(0.08, 0.15)  # Higher RTT' >> /usr/local/bin/metrics_server.py && \
    echo '        elif "cluster2" in hostname:' >> /usr/local/bin/metrics_server.py && \
    echo '            rtt = random.uniform(0.005, 0.02)  # Lower RTT' >> /usr/local/bin/metrics_server.py && \
    echo '        else:' >> /usr/local/bin/metrics_server.py && \
    echo '            rtt = random.uniform(0.02, 0.05)  # Medium RTT' >> /usr/local/bin/metrics_server.py && \
    echo '        rtt_histogram.observe(rtt)' >> /usr/local/bin/metrics_server.py && \
    echo '        packet_counter.labels(type="tcp").inc()' >> /usr/local/bin/metrics_server.py && \
    echo '        time.sleep(1)' >> /usr/local/bin/metrics_server.py && \
    echo '' >> /usr/local/bin/metrics_server.py && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/metrics_server.py && \
    echo '    start_http_server(8080)' >> /usr/local/bin/metrics_server.py && \
    echo '    print("eBPF metrics server started on port 8080")' >> /usr/local/bin/metrics_server.py && \
    echo '    collect_metrics()' >> /usr/local/bin/metrics_server.py && \
    chmod +x /usr/local/bin/metrics_server.py

EXPOSE 8080
CMD ["python3", "/usr/local/bin/metrics_server.py"]
