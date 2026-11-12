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
