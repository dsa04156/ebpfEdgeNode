#!/bin/bash

set -e

echo "Deploying network-aware scheduler..."

# Build the scheduler
echo "Building Go binary..."
go mod tidy
go build -o bin/scheduler main.go

# Create Docker image
echo "Building Docker image..."
cat > Dockerfile << 'EOF'
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o scheduler main.go

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/scheduler .
CMD ["./scheduler"]
EOF

docker build -t network-aware-scheduler:v1 .

# Apply manifests
echo "Applying Kubernetes manifests..."
kubectl apply -f manifests/

echo "Checking deployment status..."
kubectl get pods -n kube-system | grep network-aware-scheduler || true

echo "Network-aware scheduler deployed successfully!"
