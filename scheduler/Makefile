# Scheduler Plugin Makefile

# Go parameters
GOCMD = go
GOBUILD = $(GOCMD) build
GOCLEAN = $(GOCMD) clean
GOTEST = $(GOCMD) test
GOGET = $(GOCMD) get
GOMOD = $(GOCMD) mod

# Binary names
BINARY_NAME = kube-scheduler
BINARY_UNIX = $(BINARY_NAME)_unix

# Container settings
IMAGE_NAME = network-aware-scheduler
IMAGE_TAG = v0.1.0
REGISTRY = localhost:5000

# Build flags
LDFLAGS = -w -s

.PHONY: all build clean test deps deploy undeploy

all: test build

# Build the scheduler binary
build:
	$(GOBUILD) -ldflags="$(LDFLAGS)" -o $(BINARY_NAME) -v ./...

# Build for Linux
build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GOBUILD) -ldflags="$(LDFLAGS)" -o $(BINARY_UNIX) -v ./...

# Run tests
test:
	$(GOTEST) -v ./...

# Clean build artifacts
clean:
	$(GOCLEAN)
	rm -f $(BINARY_NAME)
	rm -f $(BINARY_UNIX)

# Download dependencies
deps:
	$(GOMOD) download
	$(GOMOD) tidy

# Build container image
build-container: build-linux
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

# Push to registry
push-container: build-container
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Deploy scheduler to Kubernetes
deploy: push-container
	@echo "Backing up original scheduler..."
	kubectl -n kube-system get deployment kube-scheduler -o yaml > kube-scheduler-backup.yaml
	@echo "Deploying network-aware scheduler..."
	kubectl apply -f manifests/
	@echo "Waiting for scheduler to be ready..."
	kubectl wait --for=condition=available deployment/network-aware-scheduler -n kube-system --timeout=300s

# Undeploy and restore original scheduler
undeploy:
	@echo "Removing network-aware scheduler..."
	kubectl delete -f manifests/ --ignore-not-found=true
	@echo "Restoring original scheduler..."
	if [ -f kube-scheduler-backup.yaml ]; then \
		kubectl apply -f kube-scheduler-backup.yaml; \
	fi

# Quick rollback (for MTTR measurement)
rollback:
	@echo "Starting rollback at: $(shell date)"
	kubectl patch deployment kube-scheduler -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"kube-scheduler","image":"k8s.gcr.io/kube-scheduler:v1.28.4"}]}}}}'
	kubectl wait --for=condition=available deployment/kube-scheduler -n kube-system --timeout=180s
	@echo "Rollback completed at: $(shell date)"

# Development helpers
dev-setup:
	@echo "Installing Go dependencies..."
	$(GOGET) -u github.com/prometheus/client_golang/api/prometheus/v1
	$(GOGET) -u k8s.io/apimachinery/pkg/runtime
	$(GOGET) -u k8s.io/kubernetes/pkg/scheduler/framework
	$(GOGET) -u sigs.k8s.io/scheduler-plugins/pkg/apis/config

# Test scheduler configuration
test-config:
	@echo "Testing scheduler configuration..."
	kubectl -n kube-system get configmap network-aware-scheduler-config -o yaml

# Monitor scheduler logs
logs:
	kubectl logs -f -n kube-system -l app=network-aware-scheduler

# Get scheduler metrics
metrics:
	kubectl port-forward -n kube-system svc/network-aware-scheduler 8080:8080 &
	@echo "Scheduler metrics available at: http://localhost:8080/metrics"
