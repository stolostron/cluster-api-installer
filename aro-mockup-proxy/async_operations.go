package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"
)

// AsyncOperation represents a long-running Azure operation
type AsyncOperation struct {
	ID               string
	ResourceID       string
	OperationType    string // Create, Update, Delete
	Status           string // InProgress, Succeeded, Failed
	PercentComplete  int
	StartTime        time.Time
	EndTime          *time.Time
	Error            *OperationError
	Result           interface{} // Custom result for operations like requestAdminCredential
	mu               sync.RWMutex
}

type OperationError struct {
	Code    string
	Message string
}

// AsyncOperationManager manages async operations
type AsyncOperationManager struct {
	operations map[string]*AsyncOperation
	mu         sync.RWMutex
	config     *Config
}

func NewAsyncOperationManager(config *Config) *AsyncOperationManager {
	return &AsyncOperationManager{
		operations: make(map[string]*AsyncOperation),
		config:     config,
	}
}

// StartOperation creates a new async operation and starts processing
func (m *AsyncOperationManager) StartOperation(resourceID, operationType string, db *sql.DB) *AsyncOperation {
	m.mu.Lock()
	defer m.mu.Unlock()

	operationID := fmt.Sprintf("op-%s-%d", generateShortID(), time.Now().Unix())

	op := &AsyncOperation{
		ID:            operationID,
		ResourceID:    resourceID,
		OperationType: operationType,
		Status:        "InProgress",
		PercentComplete: 0,
		StartTime:     time.Now(),
	}

	m.operations[operationID] = op

	// Start background processing
	go m.processOperation(op, db)

	return op
}

// StartOperationWithResult creates a new async operation with a custom result
func (m *AsyncOperationManager) StartOperationWithResult(resourceID, operationType string, result interface{}) *AsyncOperation {
	m.mu.Lock()
	defer m.mu.Unlock()

	operationID := fmt.Sprintf("op-%s-%d", generateShortID(), time.Now().Unix())

	op := &AsyncOperation{
		ID:              operationID,
		ResourceID:      resourceID,
		OperationType:   operationType,
		Status:          "InProgress",
		PercentComplete: 0,
		StartTime:       time.Now(),
		Result:          result,
	}

	m.operations[operationID] = op

	// Start background processing without database updates
	go m.processOperationWithResult(op)

	return op
}

// processOperationWithResult processes operations that have custom results
func (m *AsyncOperationManager) processOperationWithResult(op *AsyncOperation) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Panic in async operation %s: %v", op.ID, r)
			op.mu.Lock()
			op.Status = "Failed"
			now := time.Now()
			op.EndTime = &now
			op.Error = &OperationError{
				Code:    "InternalError",
				Message: fmt.Sprintf("Operation failed: %v", r),
			}
			op.mu.Unlock()
		}
	}()

	// Simulate provisioning progress
	stages := []int{10, 25, 50, 75, 90, 100}
	delay := m.config.ProvisioningDelay / time.Duration(len(stages))

	for _, percent := range stages {
		time.Sleep(delay)
		op.mu.Lock()
		op.PercentComplete = percent
		op.mu.Unlock()

		log.Printf("Operation %s: %d%% complete", op.ID, percent)
	}

	// Mark as succeeded
	op.mu.Lock()
	op.Status = "Succeeded"
	op.PercentComplete = 100
	now := time.Now()
	op.EndTime = &now
	op.mu.Unlock()

	log.Printf("Operation %s completed successfully", op.ID)
}

// GetOperation retrieves an operation by ID
func (m *AsyncOperationManager) GetOperation(operationID string) (*AsyncOperation, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	op, exists := m.operations[operationID]
	if !exists {
		return nil, fmt.Errorf("operation not found")
	}

	return op, nil
}

// processOperation simulates async processing
func (m *AsyncOperationManager) processOperation(op *AsyncOperation, db *sql.DB) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Panic in async operation %s: %v", op.ID, r)
			op.mu.Lock()
			op.Status = "Failed"
			now := time.Now()
			op.EndTime = &now
			op.Error = &OperationError{
				Code:    "InternalError",
				Message: fmt.Sprintf("Operation failed: %v", r),
			}
			op.mu.Unlock()
		}
	}()

	// Simulate failure if configured
	if m.config.SimulateFailures && rand.Float64() < m.config.FailureRate {
		time.Sleep(2 * time.Second)
		op.mu.Lock()
		op.Status = "Failed"
		now := time.Now()
		op.EndTime = &now
		op.Error = &OperationError{
			Code:    "SimulatedFailure",
			Message: "Simulated failure for testing",
		}
		op.mu.Unlock()
		return
	}

	// Simulate provisioning progress
	stages := []int{10, 25, 50, 75, 90, 100}
	delay := m.config.ProvisioningDelay / time.Duration(len(stages))

	for _, percent := range stages {
		time.Sleep(delay)
		op.mu.Lock()
		op.PercentComplete = percent
		op.mu.Unlock()

		log.Printf("Operation %s: %d%% complete", op.ID, percent)
	}

	// Update resource provisioning state in database
	if db != nil {
		_, err := db.Exec(`
			UPDATE resources
			SET provisioning_state = ?
			WHERE id = ?
		`, "Succeeded", op.ResourceID)

		if err != nil {
			log.Printf("Failed to update resource state: %v", err)
			op.mu.Lock()
			op.Status = "Failed"
			now := time.Now()
			op.EndTime = &now
			op.Error = &OperationError{
				Code:    "DatabaseError",
				Message: err.Error(),
			}
			op.mu.Unlock()
			return
		}
	}

	// Mark as succeeded
	op.mu.Lock()
	op.Status = "Succeeded"
	op.PercentComplete = 100
	now := time.Now()
	op.EndTime = &now
	op.mu.Unlock()

	log.Printf("Operation %s completed successfully", op.ID)
}

// ServeHTTP handles async operation status requests
func (m *AsyncOperationManager) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Extract operation ID from path
	// Expected: /operations/{operationID}
	pathParts := splitPath(r.URL.Path)
	if len(pathParts) < 2 {
		http.Error(w, "Invalid operation path", http.StatusBadRequest)
		return
	}

	operationID := pathParts[len(pathParts)-1]

	op, err := m.GetOperation(operationID)
	if err != nil {
		http.Error(w, "Operation not found", http.StatusNotFound)
		return
	}

	op.mu.RLock()
	defer op.mu.RUnlock()

	response := map[string]interface{}{
		"id":        op.ID,
		"name":      op.ID,
		"status":    op.Status,
		"startTime": op.StartTime.Format(time.RFC3339),
	}

	if op.EndTime != nil {
		response["endTime"] = op.EndTime.Format(time.RFC3339)
	}

	if op.Status == "InProgress" {
		response["percentComplete"] = op.PercentComplete
	}

	if op.Error != nil {
		response["error"] = map[string]interface{}{
			"code":    op.Error.Code,
			"message": op.Error.Message,
		}
	}

	// Add standard Azure async operation fields
	// DO NOT include the result here - the result should only be returned via the Location URL
	// The poller with finalState="location" expects to get the result from the Location endpoint
	if op.Status == "Succeeded" {
		response["properties"] = map[string]interface{}{
			"resourceId": op.ResourceID,
		}
	}

	w.Header().Set("Content-Type", "application/json")

	// Set appropriate status code
	switch op.Status {
	case "InProgress":
		w.WriteHeader(http.StatusOK)
	case "Succeeded":
		w.WriteHeader(http.StatusOK)
	case "Failed":
		w.WriteHeader(http.StatusOK) // Azure returns 200 even for failed ops
	}

	json.NewEncoder(w).Encode(response)
}

func generateShortID() string {
	const charset = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 8)
	for i := range b {
		b[i] = charset[rand.Intn(len(charset))]
	}
	return string(b)
}

func splitPath(path string) []string {
	var parts []string
	for _, p := range split(path, '/') {
		if p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

func split(s string, sep rune) []string {
	var parts []string
	var current string
	for _, c := range s {
		if c == sep {
			if current != "" {
				parts = append(parts, current)
				current = ""
			}
		} else {
			current += string(c)
		}
	}
	if current != "" {
		parts = append(parts, current)
	}
	return parts
}
