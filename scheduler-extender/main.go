package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/api"
	v1 "github.com/prometheus/client_golang/api/prometheus/v1"
	extenderv1 "k8s.io/kube-scheduler/extender/v1"
)

type SchedulerExtender struct {
	promClient   v1.API
	config       *ExtenderConfig
	metricsCache map[string]*NodeMetrics
	lastUpdate   time.Time
}

type ExtenderConfig struct {
	PrometheusURL string       `json:"prometheus_url"`
	Weights       ScoreWeights `json:"weights"`
	Port          int          `json:"port"`
	Debug         bool         `json:"debug"`
	CacheTTL      int          `json:"cache_ttl_seconds"`
}

type ScoreWeights struct {
	RTTp99      float64 `json:"rtt_p99"`
	RetransRate float64 `json:"retrans_rate"`
	DropRate    float64 `json:"drop_rate"`
	RunqlatP95  float64 `json:"runqlat_p95"`
	CPUUtil     float64 `json:"cpu_util"`
}

type NodeMetrics struct {
	NodeName    string  `json:"node_name"`
	RTTp99      float64 `json:"rtt_p99_ms"`
	RetransRate float64 `json:"retrans_rate"`
	DropRate    float64 `json:"drop_rate"`
	RunqlatP95  float64 `json:"runqlat_p95_ms"`
	CPUUtil     float64 `json:"cpu_util"`
	Score       float64 `json:"score"`
	Timestamp   int64   `json:"timestamp"`
}

func NewSchedulerExtender() (*SchedulerExtender, error) {
	config := &ExtenderConfig{
		PrometheusURL: getEnv("PROMETHEUS_URL", "http://prometheus.monitoring:9090"),
		Port:          getEnvInt("PORT", 8080),
		Debug:         getEnvBool("DEBUG", true),
		CacheTTL:      getEnvInt("CACHE_TTL", 10),
		Weights: ScoreWeights{
			RTTp99:      0.3,
			RetransRate: 0.2,
			DropRate:    0.2,
			RunqlatP95:  0.15,
			CPUUtil:     0.15,
		},
	}

	// Create Prometheus client
	promConfig := api.Config{
		Address: config.PrometheusURL,
	}
	promClient, err := api.NewClient(promConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create Prometheus client: %w", err)
	}

	extender := &SchedulerExtender{
		promClient:   v1.NewAPI(promClient),
		config:       config,
		metricsCache: make(map[string]*NodeMetrics),
	}

	log.Printf("Scheduler Extender initialized with Prometheus URL: %s", config.PrometheusURL)
	return extender, nil
}

func (se *SchedulerExtender) prioritize(w http.ResponseWriter, r *http.Request) {
	if se.config.Debug {
		log.Printf("Received prioritize request from %s", r.RemoteAddr)
	}

	var args extenderv1.ExtenderArgs
	if err := json.NewDecoder(r.Body).Decode(&args); err != nil {
		http.Error(w, fmt.Sprintf("Failed to decode request: %v", err), http.StatusBadRequest)
		return
	}

	// Update metrics cache if needed
	if time.Since(se.lastUpdate) > time.Duration(se.config.CacheTTL)*time.Second {
		if err := se.updateMetrics(r.Context()); err != nil {
			log.Printf("Failed to update metrics: %v", err)
			// Continue with cached data
		}
	}

	// Calculate scores for each node
	var hostPriorities []extenderv1.HostPriority
	
	for _, node := range args.Nodes.Items {
		nodeName := node.Name
		score := se.calculateNodeScore(nodeName)
		
		hostPriorities = append(hostPriorities, extenderv1.HostPriority{
			Host:  nodeName,
			Score: int64(score),
		})
		
		if se.config.Debug {
			log.Printf("Node %s scored: %d", nodeName, int64(score))
		}
	}

	result := &extenderv1.HostPriorityList{
		Items: hostPriorities,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(result); err != nil {
		log.Printf("Failed to encode response: %v", err)
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}

	if se.config.Debug {
		log.Printf("Returned scores for %d nodes", len(hostPriorities))
	}
}

func (se *SchedulerExtender) filter(w http.ResponseWriter, r *http.Request) {
	// For now, we don't filter nodes - just pass all through
	var args extenderv1.ExtenderArgs
	if err := json.NewDecoder(r.Body).Decode(&args); err != nil {
		http.Error(w, fmt.Sprintf("Failed to decode request: %v", err), http.StatusBadRequest)
		return
	}

	result := &extenderv1.ExtenderFilterResult{
		Nodes:       args.Nodes,
		FailedNodes: make(extenderv1.FailedNodesMap),
		Error:       "",
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func (se *SchedulerExtender) calculateNodeScore(nodeName string) float64 {
	metrics, exists := se.metricsCache[nodeName]
	if !exists {
		if se.config.Debug {
			log.Printf("No metrics found for node %s, using neutral score", nodeName)
		}
		return 50.0 // Neutral score
	}

	// Normalize metrics and calculate weighted score
	normalizedRTT := se.normalizeMetric(metrics.RTTp99, 0, 1000, true)
	normalizedRetrans := se.normalizeMetric(metrics.RetransRate, 0, 100, true)
	normalizedDrops := se.normalizeMetric(metrics.DropRate, 0, 1000, true)
	normalizedRunqlat := se.normalizeMetric(metrics.RunqlatP95, 0, 100, true)
	normalizedCPU := se.normalizeMetric(metrics.CPUUtil, 0, 100, true)

	score := se.config.Weights.RTTp99*normalizedRTT +
		se.config.Weights.RetransRate*normalizedRetrans +
		se.config.Weights.DropRate*normalizedDrops +
		se.config.Weights.RunqlatP95*normalizedRunqlat +
		se.config.Weights.CPUUtil*normalizedCPU

	// Convert to 0-100 range
	finalScore := score * 100.0
	
	// Store calculated score for debugging
	metrics.Score = finalScore

	return finalScore
}

func (se *SchedulerExtender) normalizeMetric(value, min, max float64, lowerIsBetter bool) float64 {
	if max == min {
		return 0.5
	}

	if value < min {
		value = min
	}
	if value > max {
		value = max
	}

	normalized := (value - min) / (max - min)
	
	if lowerIsBetter {
		normalized = 1.0 - normalized
	}

	return normalized
}

func (se *SchedulerExtender) updateMetrics(ctx context.Context) error {
	timeoutCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	queries := map[string]string{
		"rtt_p99":      "ebpf_rtt_p99_milliseconds",
		"retrans_rate": "ebpf_tcp_retrans_rate",
		"drop_rate":    "ebpf_drop_rate",
		"runqlat_p95":  "ebpf_runqlat_p95_milliseconds",
		"cpu_util":     "ebpf_cpu_utilization",
	}

	metricsData := make(map[string]map[string]float64)

	for metricName, query := range queries {
		result, _, err := se.promClient.Query(timeoutCtx, query, time.Now())
		if err != nil {
			log.Printf("Failed to query %s: %v", metricName, err)
			continue
		}

		nodeValues := make(map[string]float64)
		// Simplified Prometheus result parsing
		// In production, you'd need proper parsing based on the result type
		if vectors, ok := result.(map[string]interface{}); ok {
			for nodeName, value := range vectors {
				if val, ok := value.(float64); ok {
					nodeValues[nodeName] = val
				}
			}
		}
		metricsData[metricName] = nodeValues
	}

	// Build new metrics cache
	newCache := make(map[string]*NodeMetrics)
	
	// Get all unique node names
	nodeNames := make(map[string]bool)
	for _, nodeValues := range metricsData {
		for nodeName := range nodeValues {
			nodeNames[nodeName] = true
		}
	}

	for nodeName := range nodeNames {
		metrics := &NodeMetrics{
			NodeName:  nodeName,
			Timestamp: time.Now().Unix(),
		}

		if val, exists := metricsData["rtt_p99"][nodeName]; exists {
			metrics.RTTp99 = val
		}
		if val, exists := metricsData["retrans_rate"][nodeName]; exists {
			metrics.RetransRate = val
		}
		if val, exists := metricsData["drop_rate"][nodeName]; exists {
			metrics.DropRate = val
		}
		if val, exists := metricsData["runqlat_p95"][nodeName]; exists {
			metrics.RunqlatP95 = val
		}
		if val, exists := metricsData["cpu_util"][nodeName]; exists {
			metrics.CPUUtil = val
		}

		newCache[nodeName] = metrics
	}

	se.metricsCache = newCache
	se.lastUpdate = time.Now()

	if se.config.Debug {
		log.Printf("Updated metrics cache for %d nodes", len(newCache))
	}

	return nil
}

func (se *SchedulerExtender) metricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(se.metricsCache)
}

func (se *SchedulerExtender) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intValue, err := strconv.Atoi(value); err == nil {
			return intValue
		}
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	if value := os.Getenv(key); value != "" {
		if boolValue, err := strconv.ParseBool(value); err == nil {
			return boolValue
		}
	}
	return defaultValue
}

func main() {
	extender, err := NewSchedulerExtender()
	if err != nil {
		log.Fatalf("Failed to create scheduler extender: %v", err)
	}

	// Setup HTTP routes
	http.HandleFunc("/filter", extender.filter)
	http.HandleFunc("/prioritize", extender.prioritize)
	http.HandleFunc("/metrics", extender.metricsHandler)
	http.HandleFunc("/health", extender.healthHandler)

	addr := fmt.Sprintf(":%d", extender.config.Port)
	log.Printf("Starting scheduler extender on %s", addr)
	
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}
