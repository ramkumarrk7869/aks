output "resource_group_name" {
  description = "Resource group containing the private AKS cluster."
  value       = azurerm_resource_group.aks.name
}

output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "private_fqdn" {
  description = "Private API server FQDN. It is resolvable/reachable from connected networks only."
  value       = azurerm_kubernetes_cluster.aks.private_fqdn
}

output "aks_subnet_id" {
  description = "Resource ID of the AKS node subnet."
  value       = azurerm_subnet.aks.id
}

output "cluster_identity_client_id" {
  description = "Client ID of the user-assigned identity used by AKS."
  value       = azurerm_user_assigned_identity.aks.client_id
}

output "acr_name" {
  description = "Name of the Azure Container Registry."
  value       = azurerm_container_registry.aks.name
}

output "acr_login_server" {
  description = "Login server for the Azure Container Registry."
  value       = azurerm_container_registry.aks.login_server
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace used for AKS logs."
  value       = azurerm_log_analytics_workspace.monitoring.id
}

output "azure_monitor_workspace_id" {
  description = "Resource ID of the Azure Monitor workspace used for Prometheus metrics."
  value       = azurerm_monitor_workspace.monitoring.id
}

output "grafana_endpoint" {
  description = "URL of the Azure Managed Grafana workspace."
  value       = azurerm_dashboard_grafana.monitoring.endpoint
}

output "application_gateway_id" {
  description = "Resource ID of the private Application Gateway."
  value       = azurerm_application_gateway.aks.id
}

output "application_gateway_private_ip" {
  description = "Private frontend IP address of the Application Gateway."
  value       = var.application_gateway_private_ip
}
