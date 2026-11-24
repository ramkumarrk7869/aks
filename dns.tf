locals {
  website_dns_target_ip = var.website_dns_target_ip == null ? var.application_gateway_private_ip : var.website_dns_target_ip
}

resource "azurerm_private_dns_zone" "website" {
  name                = var.website_dns_zone_name
  resource_group_name = azurerm_resource_group.aks.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "website" {
  name                  = "${var.cluster_name}-website-dns-link"
  resource_group_name   = azurerm_resource_group.aks.name
  private_dns_zone_name = azurerm_private_dns_zone.website.name
  virtual_network_id    = azurerm_virtual_network.aks.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "website_client" {
  count = var.website_client_vnet_id == "" ? 0 : 1

  name                  = "${var.cluster_name}-website-client-dns-link"
  resource_group_name   = azurerm_resource_group.aks.name
  private_dns_zone_name = azurerm_private_dns_zone.website.name
  virtual_network_id    = var.website_client_vnet_id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "website" {
  name                = var.website_dns_record_name
  zone_name           = azurerm_private_dns_zone.website.name
  resource_group_name = azurerm_resource_group.aks.name
  ttl                 = 300
  records             = [local.website_dns_target_ip]
}
