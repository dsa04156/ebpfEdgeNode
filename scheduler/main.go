package main

import (
	"encoding/json"
	"log"
	"net/http"

	v1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	extenderv1 "k8s.io/kube-scheduler/extender/v1"
)

type NetworkAwareScheduler struct {
	client kubernetes.Interface
}

func main() {
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to create in-cluster config: %v", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create clientset: %v", err)
	}

	scheduler := &NetworkAwareScheduler{client: clientset}

	http.HandleFunc("/filter", scheduler.filter)
	http.HandleFunc("/prioritize", scheduler.prioritize)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	log.Println("Network-aware scheduler extender starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func (s *NetworkAwareScheduler) filter(w http.ResponseWriter, r *http.Request) {
	var args extenderv1.ExtenderArgs
	if err := json.NewDecoder(r.Body).Decode(&args); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// For now, allow all nodes (no filtering)
	result := &extenderv1.ExtenderFilterResult{
		Nodes: args.Nodes,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *NetworkAwareScheduler) prioritize(w http.ResponseWriter, r *http.Request) {
	var args extenderv1.ExtenderArgs
	if err := json.NewDecoder(r.Body).Decode(&args); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Score nodes based on simulated network metrics
	var hostPriorities []extenderv1.HostPriority
	
	for _, node := range args.Nodes.Items {
		score := s.calculateNetworkScore(node)
		hostPriorities = append(hostPriorities, extenderv1.HostPriority{
			Host:  node.Name,
			Score: score,
		})
		log.Printf("Node %s scored %d", node.Name, score)
	}

	result := extenderv1.HostPriorityList(hostPriorities)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (s *NetworkAwareScheduler) calculateNetworkScore(node v1.Node) int64 {
	// Simulate network-aware scoring based on node properties
	score := int64(50) // Base score
	
	// Prefer nodes with lower indices (simulating better network conditions)
	if len(node.Name) > 0 {
		lastChar := node.Name[len(node.Name)-1:]
		switch lastChar {
		case "1":
			score += 40 // Best network performance
		case "2":
			score += 20 // Medium network performance  
		case "3":
			score += 10 // Lower network performance
		}
	}
	
	// Consider node readiness
	for _, condition := range node.Status.Conditions {
		if condition.Type == v1.NodeReady && condition.Status == v1.ConditionTrue {
			score += 10
		}
	}
	
	log.Printf("Calculated score for node %s: %d", node.Name, score)
	return score
}
