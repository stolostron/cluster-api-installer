package main

import (
	"crypto/tls"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// ARMPath represents parsed Azure Resource Manager path components
type ARMPath struct {
	SubscriptionID  string
	ResourceGroup   string
	Location        string // For location-based resources like hcpOpenShiftVersions
	ResourceType    string
	ResourceName    string
	SubResource     string
	SubResourceName string
	Action          string
}

// Resource represents a generic ARM resource in the database
type Resource struct {
	ID                string
	ResourceType      string // HcpOpenShiftCluster, NodePool, ExternalAuth
	SubscriptionID    string
	ResourceGroup     string
	Name              string
	Properties        string // JSON blob
	Identity          string // JSON blob
	Tags              string // JSON blob
	Location          string
	ProvisioningState string
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// AROHCPMockProxyEnhanced with async operations and configuration
type AROHCPMockProxyEnhanced struct {
	db         *sql.DB
	azureProxy *httputil.ReverseProxy
	devProxy   *httputil.ReverseProxy // optional: proxy hcpOpenShiftCluster* to dev environment
	asyncOps   *AsyncOperationManager
	config     *Config
}

func NewAROHCPMockProxyEnhanced(config *Config) (*AROHCPMockProxyEnhanced, error) {
	// Initialize SQLite database
	db, err := sql.Open("sqlite3", config.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Create tables
	if err := initDatabase(db); err != nil {
		return nil, fmt.Errorf("failed to initialize database: %w", err)
	}

	// Create Azure reverse proxy
	azureURL, err := url.Parse(config.AzureEndpoint)
	if err != nil {
		return nil, fmt.Errorf("invalid Azure endpoint: %w", err)
	}

	azureProxy := httputil.NewSingleHostReverseProxy(azureURL)
	originalDirector := azureProxy.Director
	azureProxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = azureURL.Host
	}

	// Create async operation manager
	asyncOps := NewAsyncOperationManager(config)

	// Create optional dev environment proxy
	var devProxy *httputil.ReverseProxy
	if config.DevEndpoint != "" {
		devURL, err := url.Parse(config.DevEndpoint)
		if err != nil {
			return nil, fmt.Errorf("invalid dev endpoint: %w", err)
		}
		devProxy = httputil.NewSingleHostReverseProxy(devURL)
		originalDevDirector := devProxy.Director
		devProxy.Director = func(req *http.Request) {
			// Save the original Host (proxy address) before the director rewrites it.
			// The frontend uses Referer to build Azure-AsyncOperation/Location URLs
			// for LRO polling. These must point back to the proxy so ASO can reach them.
			originalHost := req.Host
			originalDevDirector(req)
			req.Host = devURL.Host
			req.Header.Set("X-Original-Host", originalHost)
			req.Header.Set("Referer", "https://"+originalHost+req.URL.Path+"?"+req.URL.RawQuery)
			// Inject ARM headers if missing - the real ARM gateway
			// adds these headers, but requests via the mockup proxy skip ARM.
			if req.Header.Get("X-Ms-Arm-Resource-System-Data") == "" {
				systemData := fmt.Sprintf(`{"createdBy":"mockup-proxy","createdByType":"Application","createdAt":"%s"}`, time.Now().UTC().Format(time.RFC3339))
				req.Header.Set("X-Ms-Arm-Resource-System-Data", systemData)
			}
			if req.Header.Get("X-Ms-Identity-Url") == "" {
				req.Header.Set("X-Ms-Identity-Url", "https://dummyhost.identity.azure.net")
			}
		}
		// Rewrite Azure-AsyncOperation and Location response headers so LRO
		// polling URLs point to the proxy, not the real frontend.
		devProxy.ModifyResponse = func(resp *http.Response) error {
			for _, header := range []string{"Azure-Asyncoperation", "Location"} {
				if val := resp.Header.Get(header); val != "" {
					if u, err := url.Parse(val); err == nil {
						u.Host = resp.Request.Header.Get("X-Original-Host")
						u.Scheme = "https"
						resp.Header.Set(header, u.String())
					}
				}
			}
			return nil
		}
		// Skip TLS verification for dev (port-forwarded) endpoints
		devProxy.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
	}

	return &AROHCPMockProxyEnhanced{
		db:         db,
		azureProxy: azureProxy,
		devProxy:   devProxy,
		asyncOps:   asyncOps,
		config:     config,
	}, nil
}

func (p *AROHCPMockProxyEnhanced) baseURL(r *http.Request) string {
	scheme := "http"
	if p.config.EnableTLS {
		scheme = "https"
	}
	host := r.Host
	if host == "" {
		host = p.config.ExternalHost
	}
	if host == "" {
		host = p.config.Port
	}
	return fmt.Sprintf("%s://%s", scheme, host)
}

// statusRecorder wraps http.ResponseWriter to capture the status code.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (sr *statusRecorder) WriteHeader(code int) {
	sr.status = code
	sr.ResponseWriter.WriteHeader(code)
}

func (p *AROHCPMockProxyEnhanced) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rec := &statusRecorder{ResponseWriter: w, status: 200}
	log.Printf("[%s] %s (Host: %s)", r.Method, r.URL.Path, r.Host)

	// Handle async operation status requests
	if strings.Contains(r.URL.Path, "/operations/") && !strings.Contains(r.URL.Path, "/providers/") {
		log.Println("  -> Routing to Async Operation Status")
		p.asyncOps.ServeHTTP(rec, r)
		log.Printf("  <- %d", rec.status)
		return
	}

	// Check if this is an ARO-HCP request
	if strings.Contains(r.URL.Path, "/Microsoft.RedHatOpenShift/") {
		// When DevEndpoint is configured, forward hcpOpenShiftCluster requests
		// to the real ARO HCP frontend (e.g. via oc port-forward)
		if p.devProxy != nil && isHcpClusterRequest(r.URL.Path) {
			log.Printf("  -> Routing to Dev ARO-HCP frontend (%s)", p.config.DevEndpoint)
			p.devProxy.ServeHTTP(rec, r)
			log.Printf("  <- %d", rec.status)
			return
		}
		log.Println("  -> Routing to ARO-HCP Mock (SQLite)")
		p.handleAROHCP(rec, r)
		log.Printf("  <- %d", rec.status)
		return
	}

	// Forward to real Azure
	log.Println("  -> Routing to Azure ARM")
	p.azureProxy.ServeHTTP(rec, r)
	log.Printf("  <- %d", rec.status)
}

// isHcpClusterRequest returns true for paths that target hcpOpenShiftClusters
// and their sub-resources (nodePools, externalAuth, actions like
// requestAdminCredential), as well as hcpOperationStatuses for LRO polling.
// Location-based read-only resources like hcpOpenShiftVersions and
// hcpOperatorIdentityRoleSets are NOT matched so they continue to be
// served by the local mock.
func isHcpClusterRequest(path string) bool {
	lower := strings.ToLower(path)
	return strings.Contains(lower, "/hcpopenshiftclusters") ||
		strings.Contains(lower, "/hcpoperationstatuses") ||
		strings.Contains(lower, "/hcpoperationresults")
}

func (p *AROHCPMockProxyEnhanced) handleResourceGroup(w http.ResponseWriter, r *http.Request) {
	// Parse path to extract subscription and resource group
	re := regexp.MustCompile(`/subscriptions/([^/]+)/resourceGroups/([^/?]+)`)
	matches := re.FindStringSubmatch(r.URL.Path)

	if len(matches) < 3 {
		http.Error(w, "Invalid ResourceGroup path", http.StatusBadRequest)
		return
	}

	subscriptionID := matches[1]
	rgName := matches[2]
	resourceID := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s", subscriptionID, rgName)

	switch r.Method {
	case "PUT":
		// Create ResourceGroup
		var body map[string]interface{}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}

		location := ""
		if loc, ok := body["location"].(string); ok {
			location = loc
		}

		tags, _ := json.Marshal(body["tags"])

		// Insert or update ResourceGroup in database
		_, err := p.db.Exec(`
			INSERT INTO resources (id, resource_type, subscription_id, resource_group, name,
				properties, tags, location, provisioning_state, updated_at)
			VALUES (?, 'ResourceGroup', ?, ?, ?, '{}', ?, ?, 'Succeeded', CURRENT_TIMESTAMP)
			ON CONFLICT(subscription_id, resource_group, resource_type, name) DO UPDATE SET
				tags = excluded.tags,
				location = excluded.location,
				updated_at = CURRENT_TIMESTAMP
		`, resourceID, subscriptionID, rgName, rgName, string(tags), location)

		if err != nil {
			log.Printf("Database error creating ResourceGroup: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		response := map[string]interface{}{
			"id":       resourceID,
			"name":     rgName,
			"type":     "Microsoft.Resources/resourceGroups",
			"location": location,
			"properties": map[string]interface{}{
				"provisioningState": "Succeeded",
			},
		}

		if body["tags"] != nil {
			response["tags"] = body["tags"]
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(response)

	case "GET":
		// Get ResourceGroup
		var r Resource
		err := p.db.QueryRow(`
			SELECT id, subscription_id, resource_group, name, tags, location, provisioning_state
			FROM resources WHERE id = ? AND resource_type = 'ResourceGroup'
		`, resourceID).Scan(&r.ID, &r.SubscriptionID, &r.ResourceGroup, &r.Name, &r.Tags, &r.Location, &r.ProvisioningState)

		if err != nil {
			http.Error(w, "ResourceGroup not found", http.StatusNotFound)
			return
		}

		response := map[string]interface{}{
			"id":       r.ID,
			"name":     r.Name,
			"type":     "Microsoft.Resources/resourceGroups",
			"location": r.Location,
			"properties": map[string]interface{}{
				"provisioningState": r.ProvisioningState,
			},
		}

		if r.Tags != "" {
			var tags map[string]interface{}
			if err := json.Unmarshal([]byte(r.Tags), &tags); err == nil {
				response["tags"] = tags
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)

	case "DELETE":
		// Delete ResourceGroup
		result, err := p.db.Exec("DELETE FROM resources WHERE id = ? AND resource_type = 'ResourceGroup'", resourceID)
		if err != nil {
			http.Error(w, "Delete failed", http.StatusInternalServerError)
			return
		}

		rows, _ := result.RowsAffected()
		if rows == 0 {
			http.Error(w, "ResourceGroup not found", http.StatusNotFound)
			return
		}

		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (p *AROHCPMockProxyEnhanced) handleKeyVault(w http.ResponseWriter, r *http.Request) {
	// Handle deletedVaults checks (always return 404 - vault not in soft delete)
	if strings.Contains(r.URL.Path, "/deletedVaults/") {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	// Parse path to extract subscription, resource group, and vault name
	re := regexp.MustCompile(`/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.KeyVault/vaults/([^/?]+)`)
	matches := re.FindStringSubmatch(r.URL.Path)

	if len(matches) < 4 {
		http.Error(w, "Invalid KeyVault path", http.StatusBadRequest)
		return
	}

	subscriptionID := matches[1]
	rgName := matches[2]
	vaultName := matches[3]
	resourceID := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/%s", subscriptionID, rgName, vaultName)

	switch r.Method {
	case "PUT":
		// Create KeyVault
		var body map[string]interface{}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}

		location := ""
		if loc, ok := body["location"].(string); ok {
			location = loc
		}

		properties, _ := json.Marshal(body["properties"])
		tags, _ := json.Marshal(body["tags"])

		// Insert or update KeyVault in database
		_, err := p.db.Exec(`
			INSERT INTO resources (id, resource_type, subscription_id, resource_group, name,
				properties, tags, location, provisioning_state, updated_at)
			VALUES (?, 'Vault', ?, ?, ?, ?, ?, ?, 'Succeeded', CURRENT_TIMESTAMP)
			ON CONFLICT(subscription_id, resource_group, resource_type, name) DO UPDATE SET
				properties = excluded.properties,
				tags = excluded.tags,
				location = excluded.location,
				updated_at = CURRENT_TIMESTAMP
		`, resourceID, subscriptionID, rgName, vaultName, string(properties), string(tags), location)

		if err != nil {
			log.Printf("Database error creating KeyVault: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		response := map[string]interface{}{
			"id":       resourceID,
			"name":     vaultName,
			"type":     "Microsoft.KeyVault/vaults",
			"location": location,
			"properties": map[string]interface{}{
				"provisioningState": "Succeeded",
				"vaultUri":          fmt.Sprintf("https://%s.vault.azure.net/", vaultName),
			},
		}

		if body["properties"] != nil {
			if props, ok := body["properties"].(map[string]interface{}); ok {
				response["properties"] = props
				response["properties"].(map[string]interface{})["provisioningState"] = "Succeeded"
			}
		}

		if body["tags"] != nil {
			response["tags"] = body["tags"]
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(response)

	case "GET":
		// Get KeyVault
		var r Resource
		err := p.db.QueryRow(`
			SELECT id, subscription_id, resource_group, name, properties, tags, location, provisioning_state
			FROM resources WHERE id = ? AND resource_type = 'Vault'
		`, resourceID).Scan(&r.ID, &r.SubscriptionID, &r.ResourceGroup, &r.Name, &r.Properties, &r.Tags, &r.Location, &r.ProvisioningState)

		if err != nil {
			http.Error(w, "KeyVault not found", http.StatusNotFound)
			return
		}

		response := map[string]interface{}{
			"id":       r.ID,
			"name":     r.Name,
			"type":     "Microsoft.KeyVault/vaults",
			"location": r.Location,
			"properties": map[string]interface{}{
				"provisioningState": r.ProvisioningState,
				"vaultUri":          fmt.Sprintf("https://%s.vault.azure.net/", r.Name),
			},
		}

		if r.Properties != "" {
			var props map[string]interface{}
			if err := json.Unmarshal([]byte(r.Properties), &props); err == nil {
				response["properties"] = props
				response["properties"].(map[string]interface{})["provisioningState"] = r.ProvisioningState
			}
		}

		if r.Tags != "" {
			var tags map[string]interface{}
			if err := json.Unmarshal([]byte(r.Tags), &tags); err == nil {
				response["tags"] = tags
			}
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)

	case "DELETE":
		// Delete KeyVault
		result, err := p.db.Exec("DELETE FROM resources WHERE id = ? AND resource_type = 'Vault'", resourceID)
		if err != nil {
			http.Error(w, "Delete failed", http.StatusInternalServerError)
			return
		}

		rows, _ := result.RowsAffected()
		if rows == 0 {
			http.Error(w, "KeyVault not found", http.StatusNotFound)
			return
		}

		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (p *AROHCPMockProxyEnhanced) handleAROHCP(w http.ResponseWriter, r *http.Request) {
	// Parse the request path to extract resource info
	parsed := p.parseARMPath(r.URL.Path)
	if parsed == nil {
		http.Error(w, "Invalid ARM path", http.StatusBadRequest)
		return
	}

	// Handle provider-level operations list
	if parsed.ResourceType == "operations" && r.Method == "GET" {
		p.handleOperationsList(w, r)
		return
	}

	// Handle location-based resources (hcpOpenShiftVersions, hcpOperatorIdentityRoleSets)
	if parsed.Location != "" {
		p.handleLocationBasedResource(w, r, parsed)
		return
	}

	// Check if this is an action endpoint (e.g., /requestAdminCredential)
	isAction := parsed.Action != "" ||
		strings.Contains(r.URL.Path, "/requestAdminCredential") ||
		strings.Contains(r.URL.Path, "/revokeCredentials")

	switch r.Method {
	case "PUT":
		p.handleCreateEnhanced(w, r, parsed)
	case "GET":
		if isAction {
			// Actions can be GET requests too (e.g., polling the Location URL)
			p.handleAction(w, r, parsed)
		} else if parsed.ResourceName == "" && parsed.SubResourceName == "" {
			p.handleList(w, r, parsed)
		} else {
			p.handleGet(w, r, parsed)
		}
	case "PATCH":
		p.handleUpdate(w, r, parsed)
	case "DELETE":
		p.handleDeleteEnhanced(w, r, parsed)
	case "POST":
		p.handleAction(w, r, parsed)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (p *AROHCPMockProxyEnhanced) handleOperationsList(w http.ResponseWriter, r *http.Request) {
	// Return the list of available operations for the Microsoft.RedHatOpenShift provider
	operations := []map[string]interface{}{
		{
			"name":   "Microsoft.RedHatOpenShift/hcpOpenShiftClusters/read",
			"display": map[string]interface{}{
				"provider":    "Microsoft Red Hat OpenShift",
				"resource":    "HCP OpenShift Cluster",
				"operation":   "Get HCP OpenShift Cluster",
				"description": "Gets a HCP OpenShift cluster",
			},
		},
		{
			"name":   "Microsoft.RedHatOpenShift/hcpOpenShiftClusters/write",
			"display": map[string]interface{}{
				"provider":    "Microsoft Red Hat OpenShift",
				"resource":    "HCP OpenShift Cluster",
				"operation":   "Create or Update HCP OpenShift Cluster",
				"description": "Creates or updates a HCP OpenShift cluster",
			},
		},
		{
			"name":   "Microsoft.RedHatOpenShift/hcpOpenShiftClusters/delete",
			"display": map[string]interface{}{
				"provider":    "Microsoft Red Hat OpenShift",
				"resource":    "HCP OpenShift Cluster",
				"operation":   "Delete HCP OpenShift Cluster",
				"description": "Deletes a HCP OpenShift cluster",
			},
		},
	}

	response := map[string]interface{}{
		"value": operations,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func (p *AROHCPMockProxyEnhanced) handleLocationBasedResource(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	switch parsed.ResourceType {
	case "hcpOpenShiftVersions":
		p.handleHcpOpenShiftVersions(w, r, parsed)
	case "hcpOperatorIdentityRoleSets":
		p.handleHcpOperatorIdentityRoleSets(w, r, parsed)
	default:
		http.Error(w, "Unknown location-based resource type", http.StatusNotFound)
	}
}

func (p *AROHCPMockProxyEnhanced) handleHcpOpenShiftVersions(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	// Mock data for available OpenShift versions
	versions := []map[string]interface{}{
		{
			"id":   fmt.Sprintf("/subscriptions/%s/providers/Microsoft.RedHatOpenShift/locations/%s/hcpOpenShiftVersions/4.14.0", parsed.SubscriptionID, parsed.Location),
			"name": "4.14.0",
			"type": "Microsoft.RedHatOpenShift/hcpOpenShiftVersions",
			"properties": map[string]interface{}{
				"version":      "4.14.0",
				"channelGroup": "stable",
			},
		},
		{
			"id":   fmt.Sprintf("/subscriptions/%s/providers/Microsoft.RedHatOpenShift/locations/%s/hcpOpenShiftVersions/4.15.0", parsed.SubscriptionID, parsed.Location),
			"name": "4.15.0",
			"type": "Microsoft.RedHatOpenShift/hcpOpenShiftVersions",
			"properties": map[string]interface{}{
				"version":      "4.15.0",
				"channelGroup": "stable",
			},
		},
	}

	if r.Method == "GET" {
		if parsed.ResourceName != "" {
			// Get specific version
			for _, v := range versions {
				if v["name"] == parsed.ResourceName {
					w.Header().Set("Content-Type", "application/json")
					json.NewEncoder(w).Encode(v)
					return
				}
			}
			http.Error(w, "Version not found", http.StatusNotFound)
		} else {
			// List versions
			response := map[string]interface{}{
				"value": versions,
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(response)
		}
	} else {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (p *AROHCPMockProxyEnhanced) handleHcpOperatorIdentityRoleSets(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	// Mock data for operator identity role sets
	roleSets := []map[string]interface{}{
		{
			"id":   fmt.Sprintf("/subscriptions/%s/providers/Microsoft.RedHatOpenShift/locations/%s/hcpOperatorIdentityRoleSets/4.14", parsed.SubscriptionID, parsed.Location),
			"name": "4.14",
			"type": "Microsoft.RedHatOpenShift/hcpOperatorIdentityRoleSets",
			"properties": map[string]interface{}{
				"version": "4.14",
				"roles": []string{
					"Contributor",
					"Network Contributor",
					"Storage Account Contributor",
				},
			},
		},
	}

	if r.Method == "GET" {
		if parsed.ResourceName != "" {
			// Get specific role set
			for _, rs := range roleSets {
				if rs["name"] == parsed.ResourceName {
					w.Header().Set("Content-Type", "application/json")
					json.NewEncoder(w).Encode(rs)
					return
				}
			}
			http.Error(w, "Role set not found", http.StatusNotFound)
		} else {
			// List role sets
			response := map[string]interface{}{
				"value": roleSets,
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(response)
		}
	} else {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func (p *AROHCPMockProxyEnhanced) handleCreateEnhanced(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	// Read request body
	var body map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	// Generate resource ID - handle both parent and child resources
	var resourceID string
	var resourceType string
	if parsed.SubResource != "" {
		// This is a child resource (nodePool or externalAuth)
		resourceID = fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s/%s/%s",
			parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName,
			parsed.SubResource, parsed.SubResourceName)
		resourceType = parsed.SubResource
	} else {
		resourceID = fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s",
			parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName)
		resourceType = parsed.ResourceType
	}

	// Extract fields and inject read-only properties based on resource type
	var propertiesMap map[string]interface{}
	if props, ok := body["properties"].(map[string]interface{}); ok {
		propertiesMap = props
	} else {
		propertiesMap = make(map[string]interface{})
	}

	// Inject read-only fields for HcpOpenShiftClusters
	if parsed.ResourceType == "hcpOpenShiftClusters" && parsed.SubResource == "" {
		// Inject console URL (read-only)
		if _, hasConsole := propertiesMap["console"]; !hasConsole {
			propertiesMap["console"] = map[string]interface{}{}
		}
		if console, ok := propertiesMap["console"].(map[string]interface{}); ok {
			console["url"] = fmt.Sprintf("https://console-openshift-console.apps.%s.mock.arodev.io", parsed.ResourceName)
			propertiesMap["console"] = console
		}

		// Inject platform issuerUrl (read-only)
		if platform, ok := propertiesMap["platform"].(map[string]interface{}); ok {
			platform["issuerUrl"] = fmt.Sprintf("https://oidc-%s.mock.arodev.io", parsed.ResourceName)
			propertiesMap["platform"] = platform
		}

		// Inject API URL if api section exists
		if api, ok := propertiesMap["api"].(map[string]interface{}); ok {
			api["url"] = fmt.Sprintf("https://%s-api.mock.arodev.io:6443", parsed.ResourceName)
			propertiesMap["api"] = api
		}
	}

	properties, _ := json.Marshal(propertiesMap)
	identity, _ := json.Marshal(body["identity"])
	tags, _ := json.Marshal(body["tags"])
	location := ""
	if loc, ok := body["location"].(string); ok {
		location = loc
	}

	// Check if resource already exists and is fully provisioned
	existingResource, _ := p.getResource(resourceID)
	isNewResource := existingResource == nil
	needsProvisioning := isNewResource || (existingResource != nil && existingResource.ProvisioningState != "Succeeded")

	// Determine initial provisioning state
	initialState := "Creating"
	if !p.config.EnableAsyncOperations {
		initialState = "Succeeded"
	}

	if isNewResource {
		// Insert new resource
		_, err := p.db.Exec(`
			INSERT INTO resources (id, resource_type, subscription_id, resource_group, name,
				properties, identity, tags, location, provisioning_state, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
		`, resourceID, resourceType, parsed.SubscriptionID, parsed.ResourceGroup,
			getResourceName(parsed), string(properties), string(identity), string(tags), location, initialState)

		if err != nil {
			log.Printf("Database error: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
	} else {
		// Update existing resource; reset to Creating if not yet Succeeded
		updateState := existingResource.ProvisioningState
		if needsProvisioning {
			updateState = initialState
		}
		_, err := p.db.Exec(`
			UPDATE resources SET
				properties = ?,
				identity = ?,
				tags = ?,
				location = ?,
				provisioning_state = ?,
				updated_at = CURRENT_TIMESTAMP
			WHERE id = ?
		`, string(properties), string(identity), string(tags), location, updateState, resourceID)

		if err != nil {
			log.Printf("Database error: %v", err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
	}

	// Start async operation for new resources or those stuck in non-Succeeded state
	var asyncOp *AsyncOperation
	if p.config.EnableAsyncOperations && needsProvisioning {
		asyncOp = p.asyncOps.StartOperation(resourceID, "Create", p.db)
		log.Printf("Started async operation: %s", asyncOp.ID)
	}

	// Return created resource
	resource, err := p.getResource(resourceID)
	if err != nil {
		http.Error(w, "Failed to retrieve created resource", http.StatusInternalServerError)
		return
	}

	response := p.buildResourceResponse(resource)
	w.Header().Set("Content-Type", "application/json")

	// Add async operation headers if enabled
	if p.config.EnableAsyncOperations && asyncOp != nil {
		base := p.baseURL(r)
		w.Header().Set("Azure-AsyncOperation", fmt.Sprintf("%s/operations/%s", base, asyncOp.ID))
		w.Header().Set("Location", fmt.Sprintf("%s%s", base, resourceID))
		w.Header().Set("Retry-After", fmt.Sprintf("%d", int(p.config.PollingInterval.Seconds())))
		w.WriteHeader(http.StatusCreated)
	} else {
		w.WriteHeader(http.StatusOK)
	}

	json.NewEncoder(w).Encode(response)
}

func getResourceName(parsed *ARMPath) string {
	if parsed.SubResourceName != "" {
		return parsed.SubResourceName
	}
	return parsed.ResourceName
}

func buildResourceID(parsed *ARMPath) string {
	if parsed.SubResource != "" {
		return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s/%s/%s",
			parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName,
			parsed.SubResource, parsed.SubResourceName)
	}
	return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s",
		parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName)
}

func (p *AROHCPMockProxyEnhanced) handleDeleteEnhanced(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	resourceID := buildResourceID(parsed)

	// Check if resource exists
	_, err := p.getResource(resourceID)
	if err != nil {
		http.Error(w, "Resource not found", http.StatusNotFound)
		return
	}

	// Start async operation if enabled
	var asyncOp *AsyncOperation
	if p.config.EnableAsyncOperations {
		// Update state to Deleting
		p.db.Exec("UPDATE resources SET provisioning_state = 'Deleting' WHERE id = ?", resourceID)

		asyncOp = p.asyncOps.StartOperation(resourceID, "Delete", p.db)
		log.Printf("Started async delete operation: %s", asyncOp.ID)

		// Schedule actual deletion after operation completes
		go func() {
			time.Sleep(p.config.ProvisioningDelay)
			p.db.Exec("DELETE FROM resources WHERE id = ?", resourceID)
		}()
	} else {
		// Immediate deletion
		result, err := p.db.Exec("DELETE FROM resources WHERE id = ?", resourceID)
		if err != nil {
			http.Error(w, "Delete failed", http.StatusInternalServerError)
			return
		}

		rows, _ := result.RowsAffected()
		if rows == 0 {
			http.Error(w, "Resource not found", http.StatusNotFound)
			return
		}
	}

	// Add async operation headers if enabled
	if p.config.EnableAsyncOperations && asyncOp != nil {
		base := p.baseURL(r)
		w.Header().Set("Azure-AsyncOperation", fmt.Sprintf("%s/operations/%s", base, asyncOp.ID))
		w.Header().Set("Location", fmt.Sprintf("%s%s", base, resourceID))
		w.Header().Set("Retry-After", fmt.Sprintf("%d", int(p.config.PollingInterval.Seconds())))
		w.WriteHeader(http.StatusAccepted)
	} else {
		w.WriteHeader(http.StatusNoContent)
	}
}

// Copy other methods from main.go
func (p *AROHCPMockProxyEnhanced) parseARMPath(path string) *ARMPath {
	// Provider-level operations: /providers/Microsoft.RedHatOpenShift/operations
	if reOps := regexp.MustCompile(`^/providers/Microsoft\.RedHatOpenShift/(operations)$`); reOps.MatchString(path) {
		return &ARMPath{
			ResourceType: "operations",
		}
	}

	// Location-based resources: /subscriptions/{subId}/providers/Microsoft.RedHatOpenShift/locations/{location}/{resourceType}[/{name}]
	if reLocation := regexp.MustCompile(`/subscriptions/([^/]+)/providers/Microsoft\.RedHatOpenShift/locations/([^/]+)/([^/]+)(?:/([^/]+))?`); reLocation.MatchString(path) {
		matches := reLocation.FindStringSubmatch(path)
		result := &ARMPath{
			SubscriptionID: matches[1],
			Location:       matches[2],
			ResourceType:   matches[3],
		}
		if len(matches) > 4 && matches[4] != "" {
			result.ResourceName = matches[4]
		}
		return result
	}

	// Subscription-level list: /subscriptions/{subId}/providers/Microsoft.RedHatOpenShift/{resourceType}
	if reSubList := regexp.MustCompile(`^/subscriptions/([^/]+)/providers/Microsoft\.RedHatOpenShift/([^/]+)$`); reSubList.MatchString(path) {
		matches := reSubList.FindStringSubmatch(path)
		return &ARMPath{
			SubscriptionID: matches[1],
			ResourceType:   matches[2],
		}
	}

	// Resource group scoped resources with optional child resources and actions
	// /subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.RedHatOpenShift/{type}/{name}[/{subType}/{subName}][/{action}]
	re := regexp.MustCompile(`/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.RedHatOpenShift/([^/]+)(?:/([^/]+))?(?:/([^/]+))?(?:/([^/]+))?(?:/([^/]+))?`)
	matches := re.FindStringSubmatch(path)

	if len(matches) < 4 {
		return nil
	}

	result := &ARMPath{
		SubscriptionID: matches[1],
		ResourceGroup:  matches[2],
		ResourceType:   matches[3],
	}

	if len(matches) > 4 && matches[4] != "" {
		result.ResourceName = matches[4]
	}
	if len(matches) > 5 && matches[5] != "" {
		result.SubResource = matches[5]
	}
	if len(matches) > 6 && matches[6] != "" {
		result.SubResourceName = matches[6]
	}
	if len(matches) > 7 && matches[7] != "" {
		result.Action = matches[7]
	}

	return result
}

func (p *AROHCPMockProxyEnhanced) handleGet(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	resourceID := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s",
		parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName)

	resource, err := p.getResource(resourceID)
	if err != nil {
		http.Error(w, "Resource not found", http.StatusNotFound)
		return
	}

	response := p.buildResourceResponse(resource)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func (p *AROHCPMockProxyEnhanced) handleList(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	var rows *sql.Rows
	var err error

	if parsed.ResourceGroup != "" {
		rows, err = p.db.Query(`
			SELECT id, resource_type, subscription_id, resource_group, name,
				properties, identity, tags, location, provisioning_state, created_at, updated_at
			FROM resources
			WHERE subscription_id = ? AND resource_group = ? AND resource_type = ?
		`, parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType)
	} else {
		rows, err = p.db.Query(`
			SELECT id, resource_type, subscription_id, resource_group, name,
				properties, identity, tags, location, provisioning_state, created_at, updated_at
			FROM resources
			WHERE subscription_id = ? AND resource_type = ?
		`, parsed.SubscriptionID, parsed.ResourceType)
	}

	if err != nil {
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var resources []Resource
	for rows.Next() {
		var r Resource
		err := rows.Scan(&r.ID, &r.ResourceType, &r.SubscriptionID, &r.ResourceGroup, &r.Name,
			&r.Properties, &r.Identity, &r.Tags, &r.Location, &r.ProvisioningState, &r.CreatedAt, &r.UpdatedAt)
		if err != nil {
			continue
		}
		resources = append(resources, r)
	}

	values := make([]interface{}, 0, len(resources))
	for _, res := range resources {
		values = append(values, p.buildResourceResponse(&res))
	}

	response := map[string]interface{}{
		"value": values,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func (p *AROHCPMockProxyEnhanced) handleUpdate(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	var body map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	resourceID := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s",
		parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName)

	_, err := p.getResource(resourceID)
	if err != nil {
		http.Error(w, "Resource not found", http.StatusNotFound)
		return
	}

	properties, _ := json.Marshal(body["properties"])
	tags, _ := json.Marshal(body["tags"])

	_, err = p.db.Exec(`
		UPDATE resources
		SET properties = COALESCE(?, properties),
			tags = COALESCE(?, tags),
			updated_at = CURRENT_TIMESTAMP
		WHERE id = ?
	`, nullIfEmpty(string(properties)), nullIfEmpty(string(tags)), resourceID)

	if err != nil {
		http.Error(w, "Update failed", http.StatusInternalServerError)
		return
	}

	resource, _ := p.getResource(resourceID)
	response := p.buildResourceResponse(resource)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func (p *AROHCPMockProxyEnhanced) handleAction(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	log.Printf("Action endpoint: %s", r.URL.Path)

	if strings.HasSuffix(r.URL.Path, "/requestAdminCredential") {
		if r.Method == "POST" {
			p.handleRequestAdminCredential(w, r, parsed)
			return
		} else if r.Method == "GET" {
			// Return result if operation completed
			// This is called via the Location header after the async operation completes
			p.handleGetAdminCredential(w, r, parsed)
			return
		}
	}

	if strings.HasSuffix(r.URL.Path, "/revokeCredentials") {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	http.Error(w, "Action not implemented", http.StatusNotImplemented)
}

func (p *AROHCPMockProxyEnhanced) handleRequestAdminCredential(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	resourceID := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s",
		parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName)

	// Read kubeconfig from file (path configurable via MOCK_KUBECONFIG_PATH env)
	kubeconfigPath := os.Getenv("MOCK_KUBECONFIG_PATH")
	if kubeconfigPath == "" {
		kubeconfigPath = "/data/workload-kubeconfig.yaml"
	}
	kubeconfigBytes, err := os.ReadFile(kubeconfigPath)
	if err != nil {
		log.Printf("Failed to read kubeconfig from %s: %v", kubeconfigPath, err)
		http.Error(w, "Failed to read kubeconfig", http.StatusInternalServerError)
		return
	}

	// Create the credential response
	expirationTime := time.Now().Add(24 * time.Hour)
	credentialResponse := map[string]interface{}{
		"kubeconfig":          string(kubeconfigBytes),
		"expirationTimestamp": expirationTime.Format(time.RFC3339),
	}

	// Start async operation with the credential result
	asyncOp := p.asyncOps.StartOperationWithResult(resourceID, "RequestAdminCredential", credentialResponse)
	log.Printf("Started async operation for requestAdminCredential: %s", asyncOp.ID)

	// Return 202 with async operation headers
	base := p.baseURL(r)

	// Azure LRO pattern: Azure-AsyncOperation for status polling, Location for final result
	w.Header().Set("Azure-AsyncOperation", fmt.Sprintf("%s/operations/%s", base, asyncOp.ID))
	w.Header().Set("Location", fmt.Sprintf("%s%s", base, r.URL.Path))
	w.Header().Set("Retry-After", fmt.Sprintf("%d", int(p.config.PollingInterval.Seconds())))
	w.WriteHeader(http.StatusAccepted)
	// No body for 202 response per Azure LRO spec
}

func (p *AROHCPMockProxyEnhanced) handleGetAdminCredential(w http.ResponseWriter, r *http.Request, parsed *ARMPath) {
	// This is called when polling the Location URL
	// We need to find the completed operation and return its result

	// For simplicity, we'll look for the most recent completed RequestAdminCredential operation
	// In a real implementation, we'd store operation ID associations

	resourceID := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.RedHatOpenShift/%s/%s",
		parsed.SubscriptionID, parsed.ResourceGroup, parsed.ResourceType, parsed.ResourceName)

	// Find the operation for this resource
	var completedOp *AsyncOperation
	p.asyncOps.mu.RLock()
	for _, op := range p.asyncOps.operations {
		op.mu.RLock()
		if op.ResourceID == resourceID && op.OperationType == "RequestAdminCredential" && op.Status == "Succeeded" && op.Result != nil {
			completedOp = op
			op.mu.RUnlock()
			break
		}
		op.mu.RUnlock()
	}
	p.asyncOps.mu.RUnlock()

	if completedOp == nil {
		// Operation not found or not completed yet - return 404 or tell client to wait
		http.Error(w, "Credential request not completed yet", http.StatusNotFound)
		return
	}

	// Return the credential response
	completedOp.mu.RLock()
	result := completedOp.Result
	completedOp.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(result)
}

func (p *AROHCPMockProxyEnhanced) getResource(id string) (*Resource, error) {
	var r Resource
	err := p.db.QueryRow(`
		SELECT id, resource_type, subscription_id, resource_group, name,
			properties, identity, tags, location, provisioning_state, created_at, updated_at
		FROM resources WHERE id = ?
	`, id).Scan(&r.ID, &r.ResourceType, &r.SubscriptionID, &r.ResourceGroup, &r.Name,
		&r.Properties, &r.Identity, &r.Tags, &r.Location, &r.ProvisioningState, &r.CreatedAt, &r.UpdatedAt)

	if err != nil {
		return nil, err
	}
	return &r, nil
}

func (p *AROHCPMockProxyEnhanced) buildResourceResponse(r *Resource) map[string]interface{} {
	response := map[string]interface{}{
		"id":       r.ID,
		"name":     r.Name,
		"type":     fmt.Sprintf("Microsoft.RedHatOpenShift/%s", r.ResourceType),
		"location": r.Location,
	}

	if r.Properties != "" {
		var props map[string]interface{}
		if err := json.Unmarshal([]byte(r.Properties), &props); err == nil {
			if props == nil {
				props = make(map[string]interface{})
			}
			props["provisioningState"] = r.ProvisioningState
			response["properties"] = props
		}
	}

	if r.Identity != "" {
		var identity map[string]interface{}
		if err := json.Unmarshal([]byte(r.Identity), &identity); err == nil {
			response["identity"] = identity
		}
	}

	if r.Tags != "" {
		var tags map[string]interface{}
		if err := json.Unmarshal([]byte(r.Tags), &tags); err == nil {
			response["tags"] = tags
		}
	}

	response["systemData"] = map[string]interface{}{
		"createdAt":      r.CreatedAt.Format(time.RFC3339),
		"lastModifiedAt": r.UpdatedAt.Format(time.RFC3339),
	}

	return response
}

// recoverStuckResources transitions any resources left in non-terminal
// provisioning states (Creating, Deleting, Updating) to Succeeded on startup.
// This handles the case where the proxy was restarted while async operations
// were in progress — those in-memory operations are lost, so without this
// the resources would stay stuck forever.
func (p *AROHCPMockProxyEnhanced) recoverStuckResources() {
	result, err := p.db.Exec(`
		UPDATE resources
		SET provisioning_state = 'Succeeded', updated_at = CURRENT_TIMESTAMP
		WHERE provisioning_state NOT IN ('Succeeded', 'Failed', 'Canceled')
	`)
	if err != nil {
		log.Printf("Warning: failed to recover stuck resources: %v", err)
		return
	}
	if rows, _ := result.RowsAffected(); rows > 0 {
		log.Printf("Recovered %d resource(s) stuck in non-terminal state -> Succeeded", rows)
	}
}

func (p *AROHCPMockProxyEnhanced) Close() error {
	return p.db.Close()
}

func initDatabase(db *sql.DB) error {
	schema := `
	CREATE TABLE IF NOT EXISTS resources (
		id TEXT PRIMARY KEY,
		resource_type TEXT NOT NULL,
		subscription_id TEXT NOT NULL,
		resource_group TEXT NOT NULL,
		name TEXT NOT NULL,
		properties TEXT,
		identity TEXT,
		tags TEXT,
		location TEXT,
		provisioning_state TEXT DEFAULT 'Succeeded',
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
		updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
		UNIQUE(subscription_id, resource_group, resource_type, name)
	);

	CREATE INDEX IF NOT EXISTS idx_subscription ON resources(subscription_id);
	CREATE INDEX IF NOT EXISTS idx_resource_group ON resources(subscription_id, resource_group);
	CREATE INDEX IF NOT EXISTS idx_type ON resources(resource_type);
	`

	_, err := db.Exec(schema)
	return err
}

func nullIfEmpty(s string) interface{} {
	if s == "" || s == "null" {
		return nil
	}
	return s
}

func main() {
	// Load configuration
	config := LoadConfig()

	protocol := "http"
	if config.EnableTLS {
		protocol = "https"
	}

	log.Printf("Starting ARO-HCP Mock Proxy on %s://%s", protocol, config.Port)
	log.Printf("  Database: %s", config.DatabasePath)
	log.Printf("  Azure Backend: %s", config.AzureEndpoint)
	if config.EnableTLS {
		log.Printf("  TLS: enabled (cert: %s, key: %s)", config.CertFile, config.KeyFile)
	}
	log.Printf("")
	log.Printf("Features:")
	log.Printf("  Async Operations: %v", config.EnableAsyncOperations)
	if config.EnableAsyncOperations {
		log.Printf("  Provisioning Delay: %s", config.ProvisioningDelay)
		log.Printf("  Polling Interval: %s", config.PollingInterval)
	}
	log.Printf("  Validation: %v", config.EnableValidation)
	log.Printf("  Failure Simulation: %v (rate: %.1f%%)", config.SimulateFailures, config.FailureRate*100)
	log.Printf("")
	log.Printf("Routing:")
	if config.DevEndpoint != "" {
		log.Printf("  hcpOpenShiftCluster requests -> Dev frontend %s", config.DevEndpoint)
		log.Printf("  Other ARO-HCP requests -> SQLite Mock")
	} else {
		log.Printf("  ARO-HCP requests -> SQLite Mock")
	}
	log.Printf("  Other requests -> %s", config.AzureEndpoint)
	log.Printf("")

	proxy, err := NewAROHCPMockProxyEnhanced(config)
	if err != nil {
		log.Fatalf("Failed to create proxy: %v", err)
	}
	defer proxy.Close()

	// Recover resources stuck in non-terminal states from a previous run.
	// Async operations are in-memory only and lost on restart, so any resource
	// still in "Creating"/"Deleting" will never transition without this.
	proxy.recoverStuckResources()

	log.Printf("Server ready on %s://%s", protocol, config.Port)

	if config.EnableTLS {
		if err := http.ListenAndServeTLS(config.Port, config.CertFile, config.KeyFile, proxy); err != nil {
			log.Fatalf("Server failed: %v", err)
		}
	} else {
		if err := http.ListenAndServe(config.Port, proxy); err != nil {
			log.Fatalf("Server failed: %v", err)
		}
	}
}
