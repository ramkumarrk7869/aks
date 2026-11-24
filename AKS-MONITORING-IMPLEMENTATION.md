# AKS Monitoring Implementation

This guide explains how monitoring is implemented for this AKS cluster using Terraform, Azure Monitor, Log Analytics, Managed Prometheus, and Azure Managed Grafana. It is intended as a repeatable reference for provisioning, understanding the data flow, verifying data, and resolving the issue encountered during setup.

## 1. What this setup monitors

This project uses Azure-managed collection and visualization rather than installing and maintaining a separate Prometheus/Grafana stack in Kubernetes:

```text
AKS
  ├─ Azure Monitor agent / Container Insights
  │    └─ container logs -> Log Analytics workspace
  └─ Managed Prometheus collection
       └─ Prometheus metrics -> Azure Monitor workspace
                                    └─ Azure Managed Grafana
```

The two data types have different destinations:

- **Container logs** are queried with Kusto Query Language (KQL) in the Log Analytics workspace.
- **Prometheus metrics** are queried with PromQL in Grafana through the Azure Monitor workspace.
- **Azure Managed Grafana** is the visualization/query interface. Its managed identity receives read permission on the Azure Monitor workspace.

This configuration does not create the Private Link Scope, private endpoints, or private DNS shown in some architecture diagrams. The workspaces and Grafana use Azure public service endpoints, protected by Azure authentication and RBAC. Add private endpoints and DNS separately only if your organization's policy requires private-only access.

## 2. Terraform components and connections

### AKS settings in `main.tf`

The cluster resource connects its log and metric collection features to the Terraform-created resources:

```hcl
oms_agent {
  log_analytics_workspace_id = azurerm_log_analytics_workspace.monitoring.id
}

monitor_metrics {
  annotations_allowed = null
  labels_allowed      = null
}
```

- `oms_agent` enables the Azure Monitor/Container Insights log agent and sends container logs to Log Analytics.
- `monitor_metrics` enables the AKS Managed Prometheus metrics integration.
- `annotations_allowed` and `labels_allowed` are left `null`; this setup does not add custom Kubernetes annotations or labels as metric dimensions.

### Resources in `monitoring.tf`

| Terraform resource | Role |
|---|---|
| `azurerm_log_analytics_workspace.monitoring` | Stores/query container logs; configured with `PerGB2018` and 30-day retention. |
| `azurerm_monitor_workspace.monitoring` | Managed destination for Prometheus metrics. |
| `azurerm_monitor_data_collection_endpoint.prometheus` | Endpoint for Azure Monitor's Prometheus data collection. |
| `azurerm_monitor_data_collection_rule.prometheus` | Selects the `Microsoft-PrometheusMetrics` stream and forwards it to the monitor workspace. |
| `azurerm_monitor_data_collection_rule_association.prometheus` | Associates that DCR with the AKS cluster. |
| `azurerm_dashboard_grafana.monitoring` | Creates Standard Azure Managed Grafana, version 12, and links it to the Azure Monitor workspace. |
| `azurerm_role_assignment.grafana_monitoring_reader` | Grants Grafana's system-assigned identity `Monitoring Reader` on the monitor workspace so Grafana can query metrics. |

Important distinction: `Monitoring Reader` is assigned to **Grafana's managed identity**, not automatically to your user. A human opening the Grafana endpoint needs **Azure Managed Grafana Viewer** (or a higher Grafana access role) on the Grafana resource.

## 3. Prerequisites and permissions

You need:

- Terraform 1.5 or later and the AzureRM 4.x provider selected in [versions.tf](./versions.tf).
- Azure CLI authenticated to the subscription containing the cluster.
- A `terraform.tfvars` with the required `subscription_id` and the appropriate resource group, location, and cluster settings.
- An Azure identity allowed to create the monitoring resources and Azure role assignments. Typically this means Contributor plus User Access Administrator (or equivalent permissions to create role assignments).
- Network access to the private AKS API from any host used to run `kubectl`.

The Terraform provider is configured in `versions.tf`; the AzureRM provider version is constrained to `~> 4.0`. Review provider constraints before copying this setup to another Terraform project.

## 4. Provision or update monitoring

The monitoring resources are part of the Terraform root configuration and are created with the cluster. From the directory containing the `.tf` files:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Review the plan for:

- Log Analytics workspace, Azure Monitor workspace, DCE, DCR, DCR association, and Managed Grafana creation/updates.
- AKS `oms_agent` and `monitor_metrics` configuration.
- Grafana role assignment.
- No unexpected AKS cluster replacement or unrelated resource destruction.

Apply only after the plan is understood:

```bash
terraform apply
```

Allow several minutes after the apply for agents to start and initial data to arrive. Azure Monitor data ingestion can incur charges; Managed Grafana uses the Standard SKU and also incurs charges.

Terraform outputs useful resource information:

```bash
terraform output -raw log_analytics_workspace_id
terraform output -raw azure_monitor_workspace_id
terraform output -raw grafana_endpoint
```

Terraform outputs are not secrets, but the workspace IDs identify your Azure resources. The Grafana endpoint is the URL to open after access has been granted.

## 5. Verify each part of the data path

### 5.1 Confirm agents and cluster connectivity

From a machine connected to the private AKS API:

```bash
az aks get-credentials \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw cluster_name)"

kubectl get nodes -o wide
kubectl get pods --namespace kube-system | grep ama
```

On Windows PowerShell, use:

```powershell
az aks get-credentials --resource-group (terraform output -raw resource_group_name) --name (terraform output -raw cluster_name)
kubectl get nodes -o wide
kubectl get pods --namespace kube-system | Select-String "ama-"
```

The cluster nodes should be Ready and Azure Monitor agent pods should be Running/Ready. If you cannot reach the private API from your current network, run these checks from a VM/runner with private network and DNS access.

### 5.2 Verify logs in Log Analytics

In the Azure portal:

1. Open the Log Analytics workspace created by Terraform (named `<cluster-name>-logs` by default).
2. Select **Logs**.
3. Run a query over a recent period:

```kusto
ContainerLogV2
| where TimeGenerated > ago(30m)
| project TimeGenerated, PodNamespace, PodName, ContainerName, LogMessage
| sort by TimeGenerated desc
| take 50
```

Allow time for initial ingestion. If the table has no rows, confirm the `oms_agent` configuration and agent pods, and that the query time range includes recent activity.

### 5.3 Verify Prometheus metrics in Grafana

1. Get the endpoint:

   ```bash
   terraform output -raw grafana_endpoint
   ```

2. Open it and sign in with Microsoft Entra ID. Your user needs **Azure Managed Grafana Viewer** or a higher role.
3. In Grafana, open **Explore** and choose the Prometheus data source associated with the linked Azure Monitor workspace.
4. Query a basic metric such as:

   ```promql
   up
   ```

   or:

   ```promql
   kube_node_info
   ```

Results confirm that Prometheus metrics reached the workspace and Grafana can query them. Use the dashboard browser to view available dashboards or create one.

If metrics are empty, check that:

- Terraform applied `monitor_metrics`.
- Azure Monitor metric-agent pods (typically named with `ama-metrics`) are healthy.
- The DCR exists and is associated with the AKS resource.
- The DCR's Prometheus stream targets the Azure Monitor workspace.
- The Grafana integration points at that workspace.
- The Grafana managed identity has `Monitoring Reader` on that workspace.
- Enough time has passed for the first collection/ingestion.

## 6. Know what `kubectl top` does (and does not do)

This Terraform configuration enables Managed Prometheus collection and Azure Monitor logs. That does not necessarily mean the Kubernetes Metrics API used by `kubectl top` is available.

- Grafana/Managed Prometheus queries metrics stored in Azure Monitor.
- `kubectl top` reads current CPU/memory usage from the Kubernetes Metrics API.
- Scheduler placement is based on resource requests and node allocatable capacity, not just live usage.

If `kubectl top` reports `Metrics API not available`, use `kubectl describe nodes` and pod events to inspect scheduling and requests. That message alone does not mean Log Analytics or Managed Prometheus is broken.

## 7. Error encountered and resolution

### Grafana major version rejected by the AzureRM provider

**Error:**

```text
expected grafana_major_version to be one of ["11" "12"], got 13
```

**Cause:** The configured Grafana major version was not accepted by the AzureRM provider version used by this project.

**Resolution:** Set `grafana_major_version = 12` on `azurerm_dashboard_grafana.monitoring` in [monitoring.tf](./monitoring.tf), then run:

```bash
terraform fmt -check
terraform validate
terraform plan
```

The current configuration uses version 12. Do not select a major version unless it is accepted by the provider version pinned in [versions.tf](./versions.tf).

## 8. Access, networking, costs, and operational notes

- Grafana login access and Grafana's ability to query metrics are separate permissions. Assign users **Azure Managed Grafana Viewer**; the Terraform `Monitoring Reader` assignment is for Grafana's managed identity.
- The setup does not make the private AKS API reachable from the internet. Use a connected machine for Kubernetes checks.
- Monitoring workspace endpoints are not configured as private endpoints here. Authentication/RBAC protect them; add private networking only if required by policy.
- Log Analytics ingestion/retention and Standard Managed Grafana incur Azure charges. Review current Azure pricing and the plan before provisioning.
- Terraform owns these resources. Prefer Terraform for changes rather than making portal-only changes that create configuration drift.
- Do not delete the workspaces while the AKS cluster or Grafana still relies on them.

## Rebuild checklist

- [ ] Confirm AzureRM provider and Terraform versions.
- [ ] Configure subscription, resource group, location, and AKS inputs.
- [ ] Confirm Terraform identity can provision resources and assign roles.
- [ ] `terraform init`, `fmt -check`, `validate`, and review `plan`.
- [ ] Confirm AKS has `oms_agent` and `monitor_metrics`.
- [ ] Confirm Log Analytics workspace, Azure Monitor workspace, DCE, DCR, DCR association, and Grafana are in the plan.
- [ ] Confirm Grafana has a system-assigned identity and workspace integration.
- [ ] Confirm Grafana identity has `Monitoring Reader` on the Azure Monitor workspace.
- [ ] Apply Terraform and allow initial data ingestion time.
- [ ] Verify `ama-` pods, query `ContainerLogV2`, and run a PromQL query in Grafana.
- [ ] Assign human viewers the Grafana access role separately.
- [ ] Understand workspace/Grafana costs and that private endpoints are not part of this configuration.
