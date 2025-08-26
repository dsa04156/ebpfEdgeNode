# Makefile for eBPF Edge Node Selection Experiment
.PHONY: all help setup-cluster deploy-monitoring deploy-agent deploy-scheduler deploy-workloads experiment baseline cleanup

# Default values
SCENARIO ?= S1
MODE ?= proposed
RPS ?= 500
REPLICAS ?= 5

# Colors
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m

all: help

help:
	@echo "Usage: make <target> [SCENARIO=S1] [MODE=proposed] [RPS=500]"
	@echo ""
	@echo "Targets:"
	@echo "  setup-cluster     - Setup Kubernetes cluster with Cilium"
	@echo "  deploy-monitoring - Deploy Prometheus and Grafana"
	@echo "  deploy-agent      - Deploy eBPF telemetry agent"
	@echo "  deploy-scheduler  - Deploy custom scheduler"
	@echo "  deploy-workloads  - Deploy test workloads"
	@echo "  experiment        - Run complete experiment"
	@echo "  baseline          - Run baseline measurement"
	@echo "  cleanup           - Clean up all resources"
	@echo ""
	@echo "Scenarios: S1(latency), S2(loss), S3(bandwidth), S4(cpu), S5(failure)"
	@echo "Modes: baseline, networkaware, proposed"

setup-cluster:
	@echo -e "$(GREEN)Setting up Kubernetes cluster...$(NC)"
	cd infrastructure && ./setup-cluster.sh

deploy-monitoring:
	@echo -e "$(YELLOW)Deploying monitoring stack...$(NC)"
	cd monitoring && ./deploy.sh

build-ebpf:
	@echo -e "$(YELLOW)Building eBPF agent...$(NC)"
	cd ebpf-agent && make all

deploy-agent: build-ebpf
	@echo -e "$(YELLOW)Deploying eBPF agent...$(NC)"
	cd ebpf-agent && make deploy

deploy-scheduler:
	@echo -e "$(YELLOW)Deploying custom scheduler...$(NC)"
	cd scheduler && make deploy

deploy-workloads:
	@echo -e "$(YELLOW)Deploying test workloads...$(NC)"
	cd workloads && ./deploy.sh

experiment:
	@echo -e "$(YELLOW)Running experiment: SCENARIO=$(SCENARIO) MODE=$(MODE) RPS=$(RPS)$(NC)"
	cd experiments && ./run-experiment.sh "$(SCENARIO)" "$(MODE)" "$(RPS)" "$(REPLICAS)"

baseline:
	@echo -e "$(YELLOW)Running baseline measurement...$(NC)"
	cd experiments && ./run-baseline.sh

cleanup:
	@echo -e "$(YELLOW)Cleaning up resources...$(NC)"
	cd scripts && ./cleanup.sh
