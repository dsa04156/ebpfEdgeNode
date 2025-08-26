#!/bin/bash
# Deploy test workloads for eBPF edge node selection experiments

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

# Deploy latency-sensitive HTTPS echo service
deploy_https_echo() {
    log "Deploying HTTPS echo service..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: workloads
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: https-echo
  namespace: workloads
  labels:
    app: https-echo
    workload-type: latency-sensitive
spec:
  replicas: 6
  selector:
    matchLabels:
      app: https-echo
  template:
    metadata:
      labels:
        app: https-echo
        workload-type: latency-sensitive
    spec:
      schedulerName: network-aware-scheduler  # Use our custom scheduler
      containers:
      - name: echo
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        - containerPort: 443
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        - name: tls-certs
          mountPath: /etc/nginx/ssl
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-echo-config
      - name: tls-certs
        secret:
          secretName: echo-tls
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-echo-config
  namespace: workloads
data:
  default.conf: |
    upstream backend {
        server 127.0.0.1:8080;
    }
    
    server {
        listen 80;
        server_name _;
        
        location / {
            add_header Content-Type text/plain;
            return 200 "Echo from pod: \$hostname on node: \$server_addr\nTimestamp: \$time_iso8601\nRequest: \$request\nHeaders: \$http_user_agent\n";
        }
        
        location /health {
            access_log off;
            return 200 "healthy\n";
        }
    }
    
    server {
        listen 443 ssl http2;
        server_name _;
        
        ssl_certificate /etc/nginx/ssl/tls.crt;
        ssl_certificate_key /etc/nginx/ssl/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        
        location / {
            add_header Content-Type text/plain;
            return 200 "HTTPS Echo from pod: \$hostname on node: \$server_addr\nTimestamp: \$time_iso8601\nRequest: \$request\nSSL Protocol: \$ssl_protocol\nSSL Cipher: \$ssl_cipher\n";
        }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: https-echo
  namespace: workloads
  labels:
    app: https-echo
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: https
    port: 443
    targetPort: 443
  selector:
    app: https-echo
---
apiVersion: v1
kind: Service
metadata:
  name: https-echo-nodeport
  namespace: workloads
  labels:
    app: https-echo
spec:
  type: NodePort
  ports:
  - name: http
    port: 80
    targetPort: 80
    nodePort: 30080
  - name: https
    port: 443
    targetPort: 443
    nodePort: 30443
  selector:
    app: https-echo
EOF

    log "✓ HTTPS echo service deployed"
}

# Generate TLS certificates
generate_tls_certs() {
    log "Generating TLS certificates..."
    
    # Create temporary directory for certs
    local cert_dir=$(mktemp -d)
    
    # Generate private key
    openssl genrsa -out $cert_dir/tls.key 2048
    
    # Generate certificate
    openssl req -new -x509 -key $cert_dir/tls.key -out $cert_dir/tls.crt -days 365 -subj "/CN=echo.local"
    
    # Create Kubernetes secret
    kubectl create secret tls echo-tls \
        --cert=$cert_dir/tls.crt \
        --key=$cert_dir/tls.key \
        --namespace=workloads \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Cleanup
    rm -rf $cert_dir
    
    log "✓ TLS certificates created"
}

# Deploy CPU-intensive inference workload
deploy_inference_workload() {
    log "Deploying CPU-intensive inference workload..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-service
  namespace: workloads
  labels:
    app: inference-service
    workload-type: cpu-intensive
spec:
  replicas: 4
  selector:
    matchLabels:
      app: inference-service
  template:
    metadata:
      labels:
        app: inference-service
        workload-type: cpu-intensive
    spec:
      schedulerName: network-aware-scheduler
      containers:
      - name: inference
        image: python:3.9-slim
        command:
        - python3
        - -c
        - |
          import time
          import json
          import random
          import threading
          from http.server import HTTPServer, BaseHTTPRequestHandler
          from urllib.parse import urlparse, parse_qs
          
          class InferenceHandler(BaseHTTPRequestHandler):
              def do_GET(self):
                  if self.path == '/health':
                      self.send_response(200)
                      self.send_header('Content-type', 'text/plain')
                      self.end_headers()
                      self.wfile.write(b'healthy')
                      return
                  
                  # Simulate CPU-intensive inference
                  start_time = time.time()
                  
                  # Parse complexity parameter
                  parsed = urlparse(self.path)
                  params = parse_qs(parsed.query)
                  complexity = int(params.get('complexity', [1000])[0])
                  
                  # CPU-intensive computation
                  result = 0
                  for i in range(complexity * 1000):
                      result += i * i * random.random()
                  
                  processing_time = time.time() - start_time
                  
                  response = {
                      'result': result,
                      'processing_time_ms': processing_time * 1000,
                      'complexity': complexity,
                      'pod_name': os.getenv('HOSTNAME', 'unknown'),
                      'node_name': os.getenv('NODE_NAME', 'unknown')
                  }
                  
                  self.send_response(200)
                  self.send_header('Content-type', 'application/json')
                  self.end_headers()
                  self.wfile.write(json.dumps(response).encode())
          
          if __name__ == '__main__':
              import os
              server = HTTPServer(('', 8080), InferenceHandler)
              print(f"Inference server starting on pod {os.getenv('HOSTNAME')} node {os.getenv('NODE_NAME')}")
              server.serve_forever()
        ports:
        - containerPort: 8080
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: inference-service
  namespace: workloads
  labels:
    app: inference-service
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  selector:
    app: inference-service
---
apiVersion: v1
kind: Service
metadata:
  name: inference-service-nodeport
  namespace: workloads
  labels:
    app: inference-service
spec:
  type: NodePort
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    nodePort: 30081
  selector:
    app: inference-service
EOF

    log "✓ CPU-intensive inference workload deployed"
}

# Deploy microservices chain
deploy_microservices() {
    log "Deploying microservices chain..."
    
    cat <<EOF | kubectl apply -f -
# Frontend service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: workloads
  labels:
    app: frontend
    workload-type: microservice
spec:
  replicas: 3
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        workload-type: microservice
    spec:
      schedulerName: network-aware-scheduler
      containers:
      - name: frontend
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: frontend-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
      volumes:
      - name: frontend-config
        configMap:
          name: frontend-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
  namespace: workloads
data:
  default.conf: |
    upstream api {
        server api-service:8080;
    }
    
    server {
        listen 80;
        location / {
            proxy_pass http://api;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
---
# API service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: workloads
  labels:
    app: api
    workload-type: microservice
spec:
  replicas: 4
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
        workload-type: microservice
    spec:
      schedulerName: network-aware-scheduler
      containers:
      - name: api
        image: python:3.9-slim
        command:
        - python3
        - -c
        - |
          import time
          import json
          import requests
          from http.server import HTTPServer, BaseHTTPRequestHandler
          
          class APIHandler(BaseHTTPRequestHandler):
              def do_GET(self):
                  if self.path == '/health':
                      self.send_response(200)
                      self.end_headers()
                      self.wfile.write(b'healthy')
                      return
                  
                  start_time = time.time()
                  
                  # Call cache service
                  try:
                      cache_response = requests.get('http://cache-service:6379/cache', timeout=1)
                      cache_data = cache_response.json()
                  except:
                      cache_data = {'status': 'cache_unavailable'}
                  
                  # Simulate API processing
                  time.sleep(0.01)  # 10ms processing
                  
                  response = {
                      'api_response': 'success',
                      'cache_data': cache_data,
                      'processing_time_ms': (time.time() - start_time) * 1000,
                      'pod_name': os.getenv('HOSTNAME'),
                      'node_name': os.getenv('NODE_NAME')
                  }
                  
                  self.send_response(200)
                  self.send_header('Content-type', 'application/json')
                  self.end_headers()
                  self.wfile.write(json.dumps(response).encode())
          
          if __name__ == '__main__':
              import os
              server = HTTPServer(('', 8080), APIHandler)
              server.serve_forever()
        ports:
        - containerPort: 8080
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 300m
            memory: 256Mi
---
# Cache service (Redis)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache
  namespace: workloads
  labels:
    app: cache
    workload-type: microservice
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cache
  template:
    metadata:
      labels:
        app: cache
        workload-type: microservice
    spec:
      schedulerName: network-aware-scheduler
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
      - name: cache-proxy
        image: python:3.9-slim
        command:
        - python3
        - -c
        - |
          import json
          import time
          from http.server import HTTPServer, BaseHTTPRequestHandler
          
          class CacheHandler(BaseHTTPRequestHandler):
              def do_GET(self):
                  response = {
                      'cache_hit': True,
                      'data': 'cached_value_' + str(int(time.time())),
                      'pod_name': os.getenv('HOSTNAME'),
                      'node_name': os.getenv('NODE_NAME')
                  }
                  
                  self.send_response(200)
                  self.send_header('Content-type', 'application/json')
                  self.end_headers()
                  self.wfile.write(json.dumps(response).encode())
          
          if __name__ == '__main__':
              import os
              server = HTTPServer(('', 6379), CacheHandler)
              server.serve_forever()
        ports:
        - containerPort: 6379
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
---
# Services
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
  namespace: workloads
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30082
  selector:
    app: frontend
---
apiVersion: v1
kind: Service
metadata:
  name: api-service
  namespace: workloads
spec:
  type: ClusterIP
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: api
---
apiVersion: v1
kind: Service
metadata:
  name: cache-service
  namespace: workloads
spec:
  type: ClusterIP
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: cache
EOF

    log "✓ Microservices chain deployed"
}

# Verify deployments
verify_deployments() {
    log "Verifying workload deployments..."
    
    # Wait for deployments to be ready
    kubectl wait --for=condition=available deployment/https-echo -n workloads --timeout=300s
    kubectl wait --for=condition=available deployment/inference-service -n workloads --timeout=300s
    kubectl wait --for=condition=available deployment/frontend -n workloads --timeout=300s
    kubectl wait --for=condition=available deployment/api -n workloads --timeout=300s
    kubectl wait --for=condition=available deployment/cache -n workloads --timeout=300s
    
    # Show status
    kubectl get all -n workloads
    
    log "✓ All workloads are ready"
}

# Show access information
show_access_info() {
    log "Workload access information:"
    
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
    
    echo ""
    echo "📋 Test Endpoints:"
    echo "  HTTPS Echo (HTTP):  http://$node_ip:30080"
    echo "  HTTPS Echo (HTTPS): https://$node_ip:30443"
    echo "  Inference Service:  http://$node_ip:30081?complexity=1000"
    echo "  Microservices:      http://$node_ip:30082"
    echo ""
    echo "📊 Load Testing Examples:"
    echo "  # Test HTTPS Echo"
    echo "  curl -k https://$node_ip:30443"
    echo ""
    echo "  # Test Inference (vary complexity: 100-5000)"
    echo "  curl http://$node_ip:30081?complexity=2000"
    echo ""
    echo "  # Test Microservices Chain"
    echo "  curl http://$node_ip:30082"
}

# Main execution
main() {
    log "Deploying test workloads for eBPF experiments..."
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is required but not installed"
        exit 1
    fi
    
    if ! command -v openssl &> /dev/null; then
        error "openssl is required for TLS certificate generation"
        exit 1
    fi
    
    # Deploy workloads
    generate_tls_certs
    deploy_https_echo
    deploy_inference_workload
    deploy_microservices
    verify_deployments
    show_access_info
    
    log "🎉 Test workloads deployment complete!"
}

# Handle script interruption
cleanup() {
    error "Script interrupted"
    exit 1
}

trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
