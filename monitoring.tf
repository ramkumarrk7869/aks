resource "azurerm_log_analytics_workspace" "monitoring" {
  name                = "${var.cluster_name}-logs"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_monitor_workspace" "monitoring" {
  name                = "${var.cluster_name}-metrics"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
}

resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = "${var.cluster_name}-dce"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = "${var.cluster_name}-prometheus"
  location                    = azurerm_resource_group.aks.location
  resource_group_name         = azurerm_resource_group.aks.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.monitoring.id
      name               = "prometheus"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["prometheus"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "prometheus"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = "prometheus"
  target_resource_id      = azurerm_kubernetes_cluster.aks.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
}

resource "azurerm_dashboard_grafana" "monitoring" {
  name                  = "${var.cluster_name}-grafana"
  resource_group_name   = azurerm_resource_group.aks.name
  location              = azurerm_resource_group.aks.location
  grafana_major_version = 12
  sku                   = "Standard"

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.monitoring.id
  }
}

resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                            = azurerm_monitor_workspace.monitoring.id
  role_definition_name             = "Monitoring Reader"
  principal_id                     = azurerm_dashboard_grafana.monitoring.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
