variable "subscription_id" {
  description = "Azure subscription ID where the AKS resources will be created."
  type        = string
}

variable "location" {
  description = "Azure region for the resource group and AKS resources."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the resource group."
  type        = string
  default     = "rg-private-aks"
}

variable "cluster_name" {
  description = "Name of the AKS cluster."
  type        = string
  default     = "aks-private"
}

variable "dns_prefix" {
  description = "DNS prefix used by the AKS cluster."
  type        = string
  default     = "aks-private"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. Leave null to use the Azure default."
  type        = string
  default     = null
  nullable    = true
}

variable "node_vm_size" {
  description = "VM size for the system node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "node_count" {
  description = "Number of nodes in the system node pool."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "vnet_address_space" {
  description = "Address space for the AKS virtual network."
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "aks_subnet_address_prefixes" {
  description = "Address prefixes assigned to the AKS subnet."
  type        = list(string)
  default     = ["10.20.0.0/22"]
}

variable "application_gateway_subnet_prefix" {
  description = "Dedicated /24 subnet for Application Gateway. Must be unused and within the VNet address space."
  type        = string
  default     = "10.20.4.0/24"
}

variable "application_gateway_private_ip" {
  description = "Static private frontend IP for Application Gateway, inside its dedicated subnet."
  type        = string
  default     = "10.20.4.250"
}

variable "website_dns_zone_name" {
  description = "Private DNS zone for the website hostname."
  type        = string
  default     = "internal.example.com"
}

variable "website_dns_record_name" {
  description = "A-record name inside the website private DNS zone."
  type        = string
  default     = "nginx"
}

variable "website_dns_target_ip" {
  description = "Optional DNS target override for rollback; leave null to use the Application Gateway IP."
  type        = string
  default     = null
}

variable "website_client_vnet_id" {
  description = "Optional resource ID of a peered client VNet that must resolve the website private DNS name."
  type        = string
  default     = ""
}

variable "pod_cidr" {
  description = "Pod address range for Azure CNI Overlay; must not overlap the VNet or service CIDR."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service address range; must not overlap the VNet or pod CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "dns_service_ip" {
  description = "IP address for the Kubernetes DNS service, within service_cidr."
  type        = string
  default     = "10.0.0.10"
}
