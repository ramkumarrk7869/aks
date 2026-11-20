resource "azurerm_subnet" "application_gateway" {
  name                 = "${var.cluster_name}-appgw-subnet"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [var.application_gateway_subnet_prefix]

  delegation {
    name = "application-gateway"

    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_application_gateway" "aks" {
  name                = "${var.cluster_name}-appgw"
  resource_group_name = azurerm_resource_group.aks.name
  location            = azurerm_resource_group.aks.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "gateway-ip-configuration"
    subnet_id = azurerm_subnet.application_gateway.id
  }

  frontend_ip_configuration {
    name                          = "private-frontend"
    subnet_id                     = azurerm_subnet.application_gateway.id
    private_ip_address            = var.application_gateway_private_ip
    private_ip_address_allocation = "Static"
  }

  frontend_port {
    name = "http"
    port = 80
  }

  backend_address_pool {
    name = "initial-backend-pool"
  }

  backend_http_settings {
    name                  = "initial-backend-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
  }

  http_listener {
    name                           = "initial-listener"
    frontend_ip_configuration_name = "private-frontend"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "initial-rule"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "initial-listener"
    backend_address_pool_name  = "initial-backend-pool"
    backend_http_settings_name = "initial-backend-settings"
  }

  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      frontend_ip_configuration,
      frontend_port,
      http_listener,
      probe,
      redirect_configuration,
      request_routing_rule,
      rewrite_rule_set,
      ssl_certificate,
      url_path_map,
    ]
  }
}

resource "azurerm_role_assignment" "agic_gateway_contributor" {
  scope                            = azurerm_application_gateway.aks.id
  role_definition_name             = "Contributor"
  principal_id                     = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "agic_resource_group_reader" {
  scope                            = azurerm_resource_group.aks.id
  role_definition_name             = "Reader"
  principal_id                     = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "agic_subnet_network_contributor" {
  scope                            = azurerm_subnet.application_gateway.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.aks.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
