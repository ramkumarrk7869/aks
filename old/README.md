# Private AKS Terraform

This Terraform configuration creates a resource group, virtual network, AKS subnet, and a private AKS cluster using a system-assigned managed identity and Azure CNI Overlay.

## Prerequisites

- Terraform 1.5 or later
- Azure CLI, authenticated to the subscription
- Azure permissions to create resource groups, networking resources, and AKS clusters, including permission to create role assignments on the AKS subnet

## Deploy

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and set your Azure subscription ID and desired values.
2. Run:

   ```powershell
   terraform init
   terraform validate
   terraform plan
   terraform apply
   ```

The private API server is not reachable from the public internet. To use `kubectl` or deploy Helm releases, connect from a machine or self-hosted GitHub Actions runner that has private network connectivity and DNS resolution for the AKS private endpoint (for example, through the cluster VNet or a peered network/VPN).

The default VNet, pod, and service address ranges are examples. Ensure they do not overlap each other or any connected organizational networks before deployment.
