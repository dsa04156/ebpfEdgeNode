# eBPF Agent Makefile

CC = clang
CFLAGS = -O2 -g -Wall -Werror
BPF_CFLAGS = -O2 -g -target bpf -D__TARGET_ARCH_x86

# Directories
LIBBPF_DIR = ./libbpf/src
LIBBPF_OBJ = $(LIBBPF_DIR)/libbpf.a
KERNEL_RELEASE = $(shell uname -r)
INCLUDES = -I$(LIBBPF_DIR)/build/usr/include/ -I./ -I/usr/src/linux-headers-$(KERNEL_RELEASE)/include

# Output files
BPF_OBJ = telemetry.bpf.o
SKEL = telemetry.skel.h
USER_OBJ = agent.o
TARGET = ebpf-agent

# Container settings
IMAGE_NAME = ebpf-edge-agent
IMAGE_TAG = v0.1.0
REGISTRY = localhost:5000

.PHONY: all clean deploy undeploy build-container push-container

all: $(TARGET)

# Build libbpf
$(LIBBPF_OBJ):
	@echo "Building libbpf..."
	@if [ ! -d "libbpf" ]; then \
		git clone https://github.com/libbpf/libbpf.git; \
	fi
	$(MAKE) -C $(LIBBPF_DIR) BUILD_STATIC_ONLY=1

# Compile eBPF program
$(BPF_OBJ): telemetry.bpf.c
	$(CC) $(BPF_CFLAGS) $(INCLUDES) -c $< -o $@

# Generate skeleton header
$(SKEL): $(BPF_OBJ)
	bpftool gen skeleton $< > $@

# Compile userspace program
$(USER_OBJ): agent.c $(SKEL)
	$(CC) $(CFLAGS) $(INCLUDES) -c $< -o $@

# Link final binary
$(TARGET): $(USER_OBJ) $(LIBBPF_OBJ)
	$(CC) $(CFLAGS) $^ -lelf -lz -o $@

# Build container image
build-container: Dockerfile
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

# Push to registry
push-container: build-container
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Deploy to Kubernetes
deploy: push-container
	@echo "Deploying eBPF agent to Kubernetes..."
	kubectl apply -f manifests/namespace.yaml
	kubectl apply -f manifests/rbac.yaml
	kubectl apply -f manifests/daemonset.yaml
	kubectl apply -f manifests/service.yaml
	@echo "Waiting for DaemonSet to be ready..."
	kubectl wait --for=condition=ready pod -l app=ebpf-edge-agent -n observability --timeout=300s

# Undeploy from Kubernetes
undeploy:
	@echo "Removing eBPF agent from Kubernetes..."
	kubectl delete -f manifests/ --ignore-not-found=true

# Test eBPF program (using bpftrace for quick verification)
smoke-test:
	@echo "Running smoke tests with bpftrace..."
	@echo "Testing RTT collection..."
	timeout 10s bpftrace -e 'kprobe:tcp_rcv_established { @srtt[comm] = ((struct tcp_sock *)arg0)->srtt_us >> 3; }' || true
	@echo "Testing retransmission tracking..."
	timeout 10s bpftrace -e 'tracepoint:tcp:tcp_retransmit_skb { @retrans[comm] = count(); }' || true
	@echo "Testing packet drops..."
	timeout 10s bpftrace -e 'tracepoint:skb:kfree_skb { @drops[args->reason] = count(); }' || true
	@echo "Smoke tests completed"

# Clean build artifacts
clean:
	rm -f $(BPF_OBJ) $(SKEL) $(USER_OBJ) $(TARGET)
	$(MAKE) -C $(LIBBPF_DIR) clean

# Development helpers
dev-setup:
	@echo "Installing development dependencies..."
	sudo apt-get update
	sudo apt-get install -y \
		clang \
		llvm \
		libelf-dev \
		libbpf-dev \
		bpftool \
		linux-tools-common \
		linux-tools-generic \
		linux-cloud-tools-generic

# Check kernel requirements
check-kernel:
	@echo "Checking kernel version and eBPF support..."
	@uname -r
	@echo "Checking for BTF support..."
	@ls /sys/kernel/btf/vmlinux >/dev/null 2>&1 && echo "✓ BTF support available" || echo "✗ BTF support not found"
	@echo "Checking bpftool availability..."
	@which bpftool >/dev/null 2>&1 && echo "✓ bpftool available" || echo "✗ bpftool not found"
	@echo "Checking for required tracepoints..."
	@ls /sys/kernel/debug/tracing/events/tcp/ >/dev/null 2>&1 && echo "✓ TCP tracepoints available" || echo "✗ TCP tracepoints not found"
	@ls /sys/kernel/debug/tracing/events/skb/ >/dev/null 2>&1 && echo "✓ SKB tracepoints available" || echo "✗ SKB tracepoints not found"

# Monitor metrics
monitor:
	@echo "Monitoring eBPF agent metrics..."
	kubectl port-forward -n observability svc/ebpf-edge-agent 8080:8080 &
	@echo "Metrics available at: http://localhost:8080/metrics"
	@echo "Press Ctrl+C to stop port forwarding"
