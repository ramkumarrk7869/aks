# Private AKS Terraform

This project provisions a private AKS cluster and Azure Container Registry (ACR), builds a small NGINX website into a Docker image, and deploys it with Helm and GitHub Actions. AKS uses Azure CNI Overlay and a user-assigned control-plane identity.

For a beginner-friendly, file-by-file explanation of the Helm chart, website Ingress, internal controller, workflow, and testing steps, see the [Helm and Ingress guide](./HELM-INGRESS-GUIDE.md).

## Contents

- [Project at a glance](#project-at-a-glance)
- [Prerequisites](#prerequisites)
- [Provision AKS and ACR](#provision-aks-and-acr)
- [Enable monitoring](#enable-monitoring)
- [Stage the private Application Gateway](#stage-the-private-application-gateway)
- [Promote AGIC and keep NGINX for rollback](#promote-agic-and-keep-nginx-for-rollback)
- [Configure GitHub Actions](#configure-github-actions)
- [Internal access](#internal-access)
- [Operate and troubleshoot](#operate-and-troubleshoot)
- [Important files](#important-files)

## Project at a glance

This repository provisions and deploys a small private website. The major components and their owners are:

| Component | What it does | Managed/configured by |
|---|---|---|
| Resource group, VNet, subnet, AKS, ACR, identities, role assignments | Azure infrastructure and cluster access | Terraform |
| Log Analytics, Azure Monitor workspace, collection rule, and Managed Grafana | AKS container logs and Prometheus metrics | Terraform in `monitoring.tf` |
| Private Application Gateway v2 and AGIC add-on | Serving the website through the private DNS hostname; NGINX remains available for rollback pending final cleanup | Terraform in `application_gateway.tf` and `main.tf` |
| Website private DNS zone and A record | Resolves the website hostname to the Application Gateway private IP from linked VNets | Terraform in `dns.tf` |
| `system` node pool | Runs Kubernetes system components and workloads | Terraform, through `node_count` and `node_vm_size` |
| `workload` node pool | Adds compute capacity for workloads | Terraform, currently one node in `main.tf` |
| Application-routing add-on and `app-routing-system` namespace | Provides the managed NGINX ingress controller platform | AKS |
| Default NGINX controller | Disabled because this project does not use its `webapprouting.kubernetes.azure.com` class or public load balancer | `web_app_routing.default_nginx_controller = "None"` in `main.tf` |
| `nginx-internal` controller configuration | Requests a private load balancer and sets the controller's minimum replica count | `deploy/nginx-internal-controller.yaml`, applied by GitHub Actions |
| Website Deployment, Service, and AGIC/NGINX Ingresses | Routes the hostname through AGIC and keeps NGINX available for rollback | Helm chart in `charts/nginx-site`, installed by GitHub Actions |
| Container image | NGINX plus `site/index.html` | Dockerfile, pushed to ACR by GitHub Actions |

AGIC watches the primary Ingress and configures Application Gateway; it is not itself in the HTTP data path. The current website request path is:

```text
Client on a connected private network
  -> private DNS resolves hostname to Application Gateway private IP
  -> Application Gateway listener/backend configured by AGIC
  -> Ingress rule in namespace web
  -> website Service in namespace web
  -> one of the NGINX website pods
```

The AKS API server and website load balancer are private. A successful GitHub Actions workflow means the build and Kubernetes deployment steps completed; it does not make the website publicly reachable. Clients also need private DNS resolution (or a Host header for testing) and network connectivity to the AKS VNet.

The repository's example settings use one `system` node and one `workload` node of the same VM size. Confirm the settings in your own ignored `terraform.tfvars` and the live cluster before assuming the deployed size or node count. Node VMs incur Azure charges.

## Prerequisites

- Terraform 1.5 or later
- Azure CLI, authenticated to the subscription
- Azure permissions to create resource groups, networking resources, and AKS clusters, including permission to create role assignments on the AKS subnet
- For GitHub deployment: a self-hosted Linux Actions runner labeled `aks-private`, with private network/DNS access to the AKS API, Docker, and Azure CLI. The workflow installs Helm.
- For private website access: a client machine connected to the AKS VNet or a peered network, plus private DNS configuration if you want to use a browser hostname.

## Provision AKS and ACR

1. Copy `terraform.tfvars.example` to `terraform.tfvars` and set your Azure subscription ID and desired values.
2. Run:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your subscription ID and desired values.
   terraform init
   terraform validate
   terraform plan
   terraform apply
   ```

Terraform creates a Basic ACR with its admin account disabled, then grants the AKS kubelet identity `AcrPull` on that registry. The registry name is generated from the cluster name and subscription ID; see the `acr_name` and `acr_login_server` outputs. AKS has the configured default `system` node pool plus a one-node `workload` user pool. Both use `var.node_vm_size`, the AKS subnet, and the same upgrade settings. The additional pool provides compute capacity for application and ingress workloads. It is managed as a separate Terraform resource, so `terraform plan` should show it as `azurerm_kubernetes_cluster_node_pool.workload`; review the plan before applying changes. The additional node incurs extra Azure compute cost. Change `node_count` to resize the default system pool; the workload pool is currently configured with one node in [main.tf](./main.tf).

### Terraform state and safe changes

Terraform state records which Azure resources Terraform owns. Keep the state file and its backup safe and private; do not commit them or delete them to “start over.” This repository's `.gitignore` excludes state files and `terraform.tfvars`. Keep a secure backup or use a properly protected remote state backend before moving machines or collaborating with others. If the state is lost, Terraform can propose creating resources that already exist; stop and recover/import state rather than blindly applying that plan.

For any infrastructure change:

```bash
terraform fmt -check
terraform validate
terraform plan
```

Read the plan before applying. If it proposes replacing or destroying the cluster, networking, registry, or other resources unexpectedly, stop and investigate. Apply only after confirming the proposed changes:

```bash
terraform apply
```

After an apply, check the Terraform-managed and live node pools:

```bash
terraform output
az aks nodepool list \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --cluster-name "$(terraform output -raw cluster_name)" \
  --output table
kubectl get nodes -o wide
```

## Enable monitoring

Monitoring is provisioned with the AKS cluster in [monitoring.tf](./monitoring.tf):

```text
AKS Azure Monitor agent
  -> container logs -> Log Analytics workspace
  -> Prometheus metrics -> Azure Monitor workspace -> Azure Managed Grafana
```

The `oms_agent` block in [main.tf](./main.tf) sends container logs to Log Analytics. The `monitor_metrics` block enables Managed Prometheus; the collection endpoint, rule, and association route those metrics to the Azure Monitor workspace. Grafana is linked to that workspace and receives the `Monitoring Reader` role so it can query metrics.

Run the existing Terraform commands (`terraform init`, `terraform plan`, then `terraform apply`) to create monitoring with the cluster. The Azure account running Terraform needs permission to create the resources and assign the Grafana role (typically Contributor plus User Access Administrator, or equivalent). Open the Grafana URL with:

```bash
terraform output -raw grafana_endpoint
```

This keeps the monitoring components simple and managed by Azure, but it does not reproduce the image's Private Link Scope, private endpoints, or private DNS zones. The Grafana and monitoring workspaces use their public Azure endpoints; access is controlled by Azure authentication and RBAC. Add private endpoints and DNS only if your network policy requires private-only access. Log ingestion and Managed Grafana incur Azure charges.

### Check monitoring after deployment

1. Apply the Terraform changes and wait a few minutes for Azure Monitor to start collecting data.
2. In the Azure portal, open the AKS resource and select **Insights** to check cluster and workload health. Open the Log Analytics workspace and select **Logs** to query collected container logs. For example:

   ```kusto
   ContainerLogV2
   | where TimeGenerated > ago(30m)
   | project TimeGenerated, PodNamespace, PodName, ContainerName, LogMessage
   | sort by TimeGenerated desc
   | take 50
   ```

3. Check that the agents are running. Because this AKS cluster is private, run `kubectl` from a machine that can reach its private API endpoint:

   ```powershell
   az aks get-credentials --resource-group (terraform output -raw resource_group_name) --name (terraform output -raw cluster_name)
   kubectl get nodes
   kubectl get pods --namespace kube-system | Select-String "ama-"
   ```

4. Open the Grafana endpoint:

   ```powershell
   terraform output -raw grafana_endpoint
   ```

   Sign in with Microsoft Entra ID. Your user needs the **Azure Managed Grafana Viewer** role (or a higher Grafana role) to open dashboards. The `Monitoring Reader` role in Terraform is assigned to Grafana's managed identity so it can query metrics; it does not grant your user access to Grafana.

5. In Grafana, open **Explore**, choose the Prometheus data source for the linked Azure Monitor workspace, and try `up` or `kube_node_info`. Seeing results confirms Prometheus metrics are arriving. Use the dashboard browser to open or create Kubernetes dashboards.

If logs or metrics are empty, confirm the Terraform apply completed, the `ama-` pods are healthy, the DCR association exists on the AKS resource, and the Azure Monitor workspace is linked to Grafana. Allow a few minutes after initial deployment for data to appear.

## Stage the private Application Gateway

This is the infrastructure-only first step of moving from the internal NGINX ingress to the stable **Application Gateway v2 + AGIC add-on**. It creates a private-only Standard_v2 gateway, a dedicated subnet, and enables the AKS-managed AGIC add-on. The website Ingress and NGINX controller are intentionally unchanged, so website traffic still uses NGINX until a later cutover.

The default network settings use `10.20.0.0/16` for the VNet and `10.20.0.0/22` for AKS. The gateway uses `10.20.4.0/24` and frontend IP `10.20.4.250` by default. Check that the subnet is unused and both addresses fit your actual VNet before applying. Override them in ignored `terraform.tfvars` if needed:

```hcl
application_gateway_subnet_prefix = "10.20.4.0/24"
application_gateway_private_ip    = "10.20.4.250"
```

Before creating a private-only v2 gateway, register the required Azure feature once for the subscription. This enables the production-supported private Application Gateway capability; the portal may label the opt-in flow as a preview feature:

```powershell
az feature register --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network
az feature show --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network --query properties.state -o tsv
```

Wait until the state is `Registered`, then refresh the network resource provider:

```powershell
az provider register --namespace Microsoft.Network
```

Run `terraform plan` and verify the AKS cluster is updated in place, not replaced. After reviewing the plan, apply it. The Azure identity running Terraform must be allowed to create the gateway/network resources and the AGIC add-on role assignments.

From a machine with access to the private AKS API, check that the add-on is enabled, its controller pod is running, and the gateway is operational:

```powershell
$rg = terraform output -raw resource_group_name
$cluster = terraform output -raw cluster_name
az aks show --resource-group $rg --name $cluster --query addonProfiles.ingressApplicationGateway.enabled -o tsv
kubectl get pods --namespace kube-system | Select-String "ingress-appgw"
az network application-gateway show --resource-group $rg --name "$cluster-appgw" --query operationalState -o tsv
terraform output -raw application_gateway_private_ip
```

The first output should be `true`; the controller pod should be `Running` and `1/1 Ready`; the gateway should report `Running`; and the final command prints its private frontend IP. Infrastructure readiness alone does not configure an application route. The separate AGIC Ingress has been tested successfully at `10.20.4.250`, and the website hostname now resolves to that IP. NGINX remains available as a rollback option while the final migration cleanup is pending. Terraform ignores AGIC-managed listeners, backend rules, and tags so later plans don't overwrite or remove AGIC's configuration.

## Promote AGIC and keep NGINX for rollback

The direct-IP AGIC test and private DNS cutover succeeded. The chart and workflow source are now set so AGIC is the primary/default Ingress while the existing NGINX Ingress and controller remain enabled for rollback. The source change is prepared but is **not live until the updated workflow is manually run**. Promotion does not remove either Ingress or change DNS; `kubectl get ingress` should still show both routes.

The chart preserves the current Kubernetes resource names to avoid deleting/recreating the live routes:

- `nginx-site-nginx-site-appgw`: primary class `azure-application-gateway`, private-IP annotation enabled.
- `nginx-site-nginx-site`: rollback class `nginx-internal`.

To apply the promotion:

1. Review the chart/workflow changes and commit/push them to your deployment branch.
2. In GitHub Actions, manually run **Build and deploy nginx site** for that branch. Pushes alone do not trigger deployment.
3. From a connected machine, verify the release and routes:

   ```bash
   helm get values nginx-site --namespace web
   kubectl get ingress -n web -o wide
   kubectl get nginxingresscontroller nginx-internal
   kubectl get service nginx-internal-0 -n app-routing-system -o wide
   ```

   Expect both Ingress names/classes/addresses to remain: AGIC at the gateway IP (`10.20.4.250` in the last report) and NGINX at its internal load-balancer IP (`10.20.0.6` in the last report). A blank address during reconciliation is not by itself a failure.
4. Verify DNS and the user path from each required client network:

   ```bash
   getent hosts nginx.internal.example.com
   curl --fail --show-error http://nginx.internal.example.com/
   ```

   **Previously verified (2026-11-20):** Azure DNS and the tested Linux VM resolved the hostname to `10.20.4.250`; the HTTP request returned the website. Repeat after deployment and for other required networks.
5. Verify the NGINX rollback route directly:

   ```bash
   curl --fail --show-error \
     -H "Host: nginx.internal.example.com" \
     http://<CURRENT_NGINX_PRIVATE_IP>/
   ```

Keep the controller and rollback Ingress until the rollback window ends and no other workloads depend on it. If needed, point the Terraform-managed DNS record back to the current NGINX IP using `website_dns_target_ip`, review the plan, apply, and retest. NGINX removal is a separate later cleanup and is not included in this promotion.

## Configure GitHub Actions

The workflow at `.github/workflows/deploy.yml` builds and pushes the image to ACR, then deploys the website and its NGINX and AGIC Kubernetes `Ingress` resources with Helm. During this migration test, AKS application routing continues to manage the internal NGINX ingress controller and internal Azure Load Balancer for the `nginx-internal` class; AGIC separately configures the Application Gateway route.

> **Support lifecycle:** This project currently uses AKS-managed NGINX Ingress. Upstream ingress-nginx maintenance ended in March 2026, and Microsoft's stated support for the AKS-managed NGINX Ingress resources ends in November 2026. This is a short-lived/learning setup, not a recommended long-term ingress choice. Before continuing to rely on it, check Microsoft's current support notice and plan migration to Gateway API or Application Gateway for Containers. See the [AKS application routing documentation](https://learn.microsoft.com/azure/aks/app-routing).

### Enable AKS application routing

The `web_app_routing` block in [main.tf](./main.tf) declares the AKS application-routing add-on so Terraform tracks it and does not plan to remove it. Its empty `dns_zone_ids` list means this project is not attaching a custom Azure DNS zone. The add-on provides the managed controller platform and `NginxIngressController` resource type used by the dedicated internal controller manifest and website Ingress. In this project, `default_nginx_controller = "None"` disables creation of the add-on's **default** NGINX controller. It does not disable the application-routing add-on or the separate `nginx-internal` controller. The website Ingress uses the `nginx-internal` class, not the default `webapprouting.kubernetes.azure.com` class. Disabling the unused default controller avoids running its extra controller pods and public load-balancer Service when they are not needed.

#### Exact change made in `main.tf`

Inside the `azurerm_kubernetes_cluster` resource, the `web_app_routing` block remains in place. Only the value of `default_nginx_controller` changed:

```diff
 web_app_routing {
   dns_zone_ids             = []
-  default_nginx_controller = "AnnotationControlled"
+  default_nginx_controller = "None"
 }
```

`AnnotationControlled` allowed AKS application routing to create its default NGINX controller. `"None"` tells the add-on not to create that default controller. Keeping the `web_app_routing` block enabled is important: it preserves the add-on and the custom `NginxIngressController` support that the separate `nginx-internal` controller uses. The internal controller is configured independently in `deploy/nginx-internal-controller.yaml`, so this change does not change its private IP, ingress class, or minimum replica setting.

The internal controller manifest at [deploy/nginx-internal-controller.yaml](./deploy/nginx-internal-controller.yaml) requests a private load balancer and sets its supported minimum replica count to one. This reduces baseline capacity but also controller redundancy. Per-pod CPU and memory requests/limits are managed by the AKS add-on and are not configurable through this manifest.

#### Disable and remove the unused default controller

The setting in `main.tf` is the desired configuration for future Terraform applies. To update an existing cluster, first check whether any Ingress uses the default class:

```bash
kubectl get ingress --all-namespaces -o wide
kubectl get ingressclass
kubectl get nginxingresscontroller
```

In this project the website Ingress uses class `nginx-internal`; the default controller uses class `webapprouting.kubernetes.azure.com`. Only remove the default controller if no application needs that default class. Do not delete the whole application-routing add-on, because the internal controller depends on it.

From the Terraform working directory, review and apply the configuration change:

```bash
terraform fmt -check
terraform validate
terraform plan
```

Confirm that the plan keeps the AKS cluster and the `web_app_routing` add-on, and does not unexpectedly replace or destroy the cluster. If the plan is unexpected, stop and investigate rather than applying it. If it is understood and safe:

```bash
terraform apply
```

Setting the default controller type to `None` prevents the add-on from creating the default controller, but on an existing cluster it does not automatically delete the existing default `NginxIngressController` custom resource. After the Terraform update succeeds, and after confirming it is unused, remove only that resource:

```bash
kubectl delete nginxingresscontroller default
```

Deleting this custom resource asks the add-on to remove the default controller's Deployment, pods, and public `nginx` Service/load balancer. Do not delete `nginx-internal`; that is the controller serving the website. Verify the remaining controller, Service, Ingress, and website:

```bash
kubectl get nginxingresscontroller
kubectl get pods,services --namespace app-routing-system -o wide
kubectl get ingress --all-namespaces -o wide
kubectl get endpoints --namespace web
```

Expected: `nginx-internal` remains, the website Ingress still uses class `nginx-internal`, and its internal load balancer still has a private IP. The default `nginx` controller and its public load-balancer Service should be gone. If the default controller reappears, check that Terraform still says `None` and that no separate Azure CLI or configuration-management action is setting it back.

Prefer Terraform as the source of truth for this setting. Avoid changing the setting only with `az aks approuting update`, because that can leave Terraform configuration and Azure out of sync.

If you need to enable the add-on manually on an existing cluster, Azure CLI can do so through the Azure management plane without direct access to the private Kubernetes API:

```bash
az aks approuting enable --resource-group "rg-private-aks" --name "aks-private"
```

You can instead let Terraform enable/manage the add-on by applying the `web_app_routing` block; don't alternate between Terraform and Azure CLI without keeping the Terraform configuration aligned. The workflow applies [deploy/nginx-internal-controller.yaml](./deploy/nginx-internal-controller.yaml), which creates a dedicated internal controller. It must exist before Helm creates the website Ingress. The workflow's `kubectl` and Helm deployment steps need a self-hosted runner with private network access to the AKS API.

### GitHub runner requirements

Because the AKS API server is private, use a **self-hosted Linux GitHub Actions runner** with the label `aks-private`, connected to the cluster VNet or a peered network with private DNS resolution. The runner needs Azure CLI, Docker with a running daemon, network access to GitHub and ACR, and Helm (the workflow installs Helm).

### Create a GitHub deployment identity with OIDC

OIDC is preferred over a long-lived service-principal password. The workflow uses a Microsoft Entra application and service principal with a federated credential, so **there is no Azure client secret to create or rotate**. The client, tenant, subscription, and deployment settings will still be stored as GitHub Actions secrets as requested.

From your Ubuntu VM terminal, sign in as an Azure administrator, select the subscription containing AKS/ACR, and set your GitHub owner/repository. The account creating the identity must be allowed to create Entra applications and assign Azure roles:

```bash
az login
az account set --subscription "<subscription-id>"

OWNER="<GITHUB_OWNER>"
REPO="<GITHUB_REPOSITORY>"
gh auth login
OWNER_ID="$(gh api "repos/${OWNER}/${REPO}" --jq '.owner.id')"
REPOSITORY_ID="$(gh api "repos/${OWNER}/${REPO}" --jq '.id')"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
TENANT_ID="$(az account show --query tenantId --output tsv)"

APP_ID="$(az ad app create --display-name "gh-aks-nginx-deployer" --query appId --output tsv)"
SP_OBJECT_ID="$(az ad sp create --id "$APP_ID" --query id --output tsv)"

cat > github-federated-credential.json <<EOF
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${OWNER}@${OWNER_ID}/${REPO}@${REPOSITORY_ID}:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters @github-federated-credential.json
rm github-federated-credential.json
```

GitHub's OIDC subject for this repository includes immutable owner and repository IDs. It should look like `repo:OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID:ref:refs/heads/main`. If your repository uses a different branch, update both the federated credential subject and the workflow trigger to match.

#### Fix `AADSTS700213: No matching federated identity record found`

The workflow's Azure login error prints the exact OIDC subject, issuer, and audience it presented. The federated credential must match all three exactly. For example, if the log shows:

```text
issuer: https://token.actions.githubusercontent.com
subject: repo:ramkumarrk7869@210393011/aks@1455095806:ref:refs/heads/main
audience: api://AzureADTokenExchange
```

then a credential using the older `repo:OWNER/REPOSITORY:ref:...` subject will not match. Add a new federated credential to the **same Entra application whose client ID is stored in the `AZURE_CLIENT_ID` GitHub secret**. Do not leave the example placeholder in `APP_ID`; it must be the actual application (client) ID, usually a GUID. Find candidate IDs with:

```bash
az ad app list \
  --display-name "gh-aks-nginx-deployer" \
  --query "[].{name:displayName,clientId:appId}" \
  --output table
```

Copy the `clientId` that matches the `AZURE_CLIENT_ID` secret in GitHub. Verify it resolves to an application:

```bash
APP_ID="<paste-the-actual-client-id-guid-here>"
az ad app show --id "$APP_ID" --query appId --output tsv
```

Then create a credential using your actual repository values. `jq` inserts the values safely; the resulting JSON will not contain literal `${OWNER}` or `${REPOSITORY_ID}` placeholders:

```bash
OWNER="ramkumarrk7869"
REPO="aks"
OWNER_ID="$(gh api "repos/${OWNER}/${REPO}" --jq '.owner.id')"
REPOSITORY_ID="$(gh api "repos/${OWNER}/${REPO}" --jq '.id')"

credential_file="$(mktemp)"
jq -n \
  --arg subject "repo:${OWNER}@${OWNER_ID}/${REPO}@${REPOSITORY_ID}:ref:refs/heads/main" \
  '{
    name: "github-main-immutable-subject",
    issuer: "https://token.actions.githubusercontent.com",
    subject: $subject,
    audiences: ["api://AzureADTokenExchange"]
  }' > "$credential_file"

cat "$credential_file"

az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "@$credential_file"
rm "$credential_file"
```

The generated subject should equal the subject printed in the workflow log. Keep the existing GitHub secrets and rerun the workflow after the credential is created.

### Grant least-privilege Azure roles

The service principal needs `AcrPush` scoped to ACR and `Azure Kubernetes Service Cluster Admin Role` scoped to this AKS cluster. The latter is needed because the workflow requests admin kubeconfig with `az aks get-credentials --admin`.

```bash
APP_ID="<ENTRA_APPLICATION_CLIENT_ID>"
SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id --output tsv)"
ACR_NAME="$(terraform output -raw acr_name)"
RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
CLUSTER_NAME="$(terraform output -raw cluster_name)"
ACR_ID="$(az acr show --name "$ACR_NAME" --query id --output tsv)"
CLUSTER_ID="$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query id --output tsv)"

az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role AcrPush \
  --scope "$ACR_ID"
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service Cluster Admin Role" \
  --scope "$CLUSTER_ID"
```

Role assignments can take a few minutes to propagate. Your account needs permission to create role assignments.

### Add repository Actions secrets

Install and authenticate GitHub CLI (`gh auth login`) or add these under **GitHub repository → Settings → Secrets and variables → Actions → New repository secret**. Use **secrets**, not Actions variables, for every value consumed by this workflow.

With GitHub CLI authenticated to the target repository, set the shell variables and secrets. Set `OWNER` and `REPO` to the actual GitHub repository owner and repository name. `APP_ID` must be the client ID of the Entra application whose federated credential was created above:

```bash
OWNER="<GITHUB_OWNER>"
REPO="<GITHUB_REPOSITORY>"
APP_ID="<ENTRA_APPLICATION_CLIENT_ID>"
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
TENANT_ID="$(az account show --query tenantId --output tsv)"
RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
CLUSTER_NAME="$(terraform output -raw cluster_name)"
ACR_NAME="$(terraform output -raw acr_name)"
ACR_LOGIN_SERVER="$(terraform output -raw acr_login_server)"
NGINX_HOST="nginx.internal.example.com"

gh secret set AZURE_CLIENT_ID --repo "${OWNER}/${REPO}" --body "$APP_ID"
gh secret set AZURE_TENANT_ID --repo "${OWNER}/${REPO}" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo "${OWNER}/${REPO}" --body "$SUBSCRIPTION_ID"
gh secret set ACR_NAME --repo "${OWNER}/${REPO}" --body "$ACR_NAME"
gh secret set ACR_LOGIN_SERVER --repo "${OWNER}/${REPO}" --body "$ACR_LOGIN_SERVER"
gh secret set AKS_RESOURCE_GROUP --repo "${OWNER}/${REPO}" --body "$RESOURCE_GROUP"
gh secret set AKS_CLUSTER_NAME --repo "${OWNER}/${REPO}" --body "$CLUSTER_NAME"
gh secret set NGINX_HOST --repo "${OWNER}/${REPO}" --body "$NGINX_HOST"
```

After enabling the add-on, setting up the runner, and granting roles, start the deployment manually: open **GitHub repository → Actions → Build and deploy nginx site → Run workflow**, select the branch, and confirm **Run workflow**. The workflow is configured not to run on pushes to any branch.

The workflow builds an image tagged with the commit SHA, pushes it to ACR, gets AKS credentials, applies `deploy/nginx-internal-controller.yaml`, and deploys the chart to namespace `web` with `helm upgrade --install`. The Helm command passes the configured ACR image, image tag, and `NGINX_HOST`, and includes:

```bash
--set ingress.nginxRollback.enabled=true
```

The chart's main Ingress uses class `azure-application-gateway`; this flag keeps the additional `nginx-internal` rollback Ingress. Both route the same host/path to the website Service. The workflow applies the NGINX controller manifest before the Helm release, so the rollback controller remains provisioned. The workflow prints both routes. DNS already points to Application Gateway and is not changed by Helm. Follow [Promote AGIC and keep NGINX for rollback](#promote-agic-and-keep-nginx-for-rollback) to deploy and verify. See [HELM-INGRESS-GUIDE.md](./HELM-INGRESS-GUIDE.md) for chart/workflow details.

## Internal access

The chart creates two Ingresses for `NGINX_HOST`: the primary `azure-application-gateway` route and the `nginx-internal` rollback route. DNS points the hostname to Application Gateway; the NGINX internal load balancer remains available for rollback. Inspect both routes and the controller with:

```bash
kubectl get ingress --namespace web
kubectl get nginxingresscontroller nginx-internal
kubectl get service --namespace app-routing-system \
  --output custom-columns=NAME:.metadata.name,TYPE:.spec.type,IP:.status.loadBalancer.ingress[0].ip
```

The `IP` column is the NGINX controller's load balancer IP (`10.20.0.6` in the current cluster); keep it available for rollback. The Application Gateway route was tested at `10.20.4.250`. Terraform now manages the separate private zone `internal.example.com`, its VNet links, and the `nginx.internal.example.com` A record pointing to the Application Gateway.

**Do not use the AKS API server's private DNS zone for the website.** In [main.tf](./main.tf), `private_dns_zone_id = "System"` lets AKS manage its private API endpoint zone and record in the AKS node resource group. That record resolves the Kubernetes API endpoint, not `nginx.internal.example.com`; leave it unchanged.

Terraform manages a separate website private DNS zone, links it to the AKS VNet and the peered client VNet, and creates the website A record. Defaults are zone `internal.example.com` and record `nginx`, matching `NGINX_HOST=nginx.internal.example.com`. The record points to the Application Gateway private IP by default. For future DNS changes, review the plan before applying:

The DNS resource arguments must match the AzureRM version selected by `versions.tf`. With the provider schema used by this project, the VNet link uses `private_dns_zone_name` and `resource_group_name`, while the A record uses `zone_name` and `resource_group_name`.

```bash
terraform plan
```

Because the Linux test VM is in a peered VNet, add its VNet resource ID to the ignored `terraform.tfvars` file:

```hcl
website_client_vnet_id = "/subscriptions/<subscription-id>/resourceGroups/<client-vnet-rg>/providers/Microsoft.Network/virtualNetworks/<client-vnet-name>"
```

Then confirm the plan creates the website private zone, its AKS VNet link, the client-VNet link, and the A record pointing to `10.20.4.250`; confirm it does not replace the AKS cluster or Application Gateway. Apply after reviewing:

```bash
terraform plan
terraform apply
```

Check the resulting hostname and resolve it from a client in the linked VNet:

```bash
terraform output -raw website_private_dns_fqdn
getent hosts nginx.internal.example.com
curl --fail --show-error http://nginx.internal.example.com/
```

The private DNS zone only resolves for linked VNets (and networks with appropriate DNS forwarding). Add a link for each client VNet that needs access; do not set `website_client_vnet_id` to the AKS VNet, which already has its own link. For on-premises or corporate DNS clients, configure conditional forwarding through Azure DNS Private Resolver or a DNS forwarder.

**Verified 2026-11-20 from the peered Linux VM:** Azure DNS and `getent` both resolved the website hostname to `10.20.4.250`, and `curl` returned the website page. This verifies DNS and HTTP access from that VM; verify other required networks separately.

For rollback, leave NGINX running and apply with its current internal load-balancer IP as the DNS target:

```bash
terraform apply -var='website_dns_target_ip=10.20.0.6'
```

The default `website_dns_target_ip = null` restores the Application Gateway IP on the next apply. Change the override to the actual NGINX IP if it differs from `10.20.0.6`.

### Verify the deployed website

First confirm that the workload and ingress controller pods are ready and that the Ingress has the expected host and class:

```bash
kubectl get nodes
kubectl get pods --namespace web -o wide
kubectl get pods --namespace app-routing-system -o wide
kubectl get ingress --namespace web
kubectl get service --namespace app-routing-system
```

The internal controller service should have a private `EXTERNAL-IP` (for example, `10.20.0.6`); it must not be `<pending>`. Use the actual IP shown for `nginx-internal-0`, along with the exact hostname configured in the GitHub Actions `NGINX_HOST` secret and the Ingress.

#### Find the two values before running curl

The curl test needs two values: (1) the private IP of the internal ingress load balancer, and (2) the hostname configured on the deployed website Ingress. Do not assume the previous IP is still current.

Run the following inspection commands from a machine that has `kubectl` credentials and private network access to this AKS cluster, such as your connected Linux VM:

```bash
kubectl get service nginx-internal-0 --namespace app-routing-system -o wide
kubectl get ingress --namespace web
```

**Find the private IP:** in the first command's output, read the `EXTERNAL-IP` column for Service `nginx-internal-0`. In your successful test it was `10.20.0.6`. Use the current value shown now; `<pending>` means the load balancer is not ready yet.

You can ask Kubernetes to print only that IP:

```bash
kubectl get service nginx-internal-0 --namespace app-routing-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo
```

**Find the hostname:** in the second command's output, read the `HOSTS` column for the website Ingress (currently named `nginx-site-nginx-site`). The workflow reads this host from the GitHub Actions repository secret named `NGINX_HOST` and passes it to Helm as `ingress.host`. The chart writes that value into the Ingress rule. The chart's `values.yaml` has `nginx.internal.example.com` as a default, but the workflow's `--set-string ingress.host=...` overrides that default during deployment. Therefore, use the host shown by the live Ingress, not an assumed default or a different secret value.

Print only the actual host from the deployed Ingress:

```bash
kubectl get ingress nginx-site-nginx-site --namespace web \
  -o jsonpath='{.spec.rules[0].host}'
echo
```

If the Ingress name is different, use the name shown by `kubectl get ingress --namespace web`. The host shown in the live Ingress is the value the controller expects in the HTTP `Host` header.

#### Run the website test

Run this from your connected Linux VM or another client with a route to the AKS VNet/internal load balancer. Replace both example values with the values you just read:

```bash
curl -H "Host: <HOST-FROM-THE-WEBSITE-INGRESS>" \
  http://<EXTERNAL-IP-FROM-nginx-internal-0>/
```

For example, your successful test used:

```bash
curl -H "Host: nginx.internal.example.com" http://10.20.0.6/
```

The two parts come from different Kubernetes resources:

- `nginx.internal.example.com` is the host in the website Ingress, originally supplied by the GitHub secret `NGINX_HOST` through the workflow. It is sent as the HTTP `Host` header so the ingress controller can select the correct Ingress rule.
- `10.20.0.6` is the private `EXTERNAL-IP` for Service `nginx-internal-0` in namespace `app-routing-system`. The service is created for the internal ingress controller. This IP can change; find the current IP before each test.
- `http://` uses plain HTTP, and because no port is specified, curl connects to TCP port 80. The trailing `/` requests the website's root path.

The request uses the IP directly, so DNS is not involved. A `Host` header is still required because the ingress controller uses the hostname to choose the correct website rule.

A successful command prints HTML containing `Hello from NGINX on private AKS`. That confirms the request reached the internal load balancer, matched the Ingress host rule, reached the website Service, and was served by a website pod.

For a repeatable test without manually copying values, assign them from Kubernetes and then run curl:

```bash
INGRESS_IP="$(kubectl get service nginx-internal-0 --namespace app-routing-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
NGINX_HOST="$(kubectl get ingress nginx-site-nginx-site --namespace web \
  -o jsonpath='{.spec.rules[0].host}')"

printf 'Ingress IP: %s\nWebsite host: %s\n' "$INGRESS_IP" "$NGINX_HOST"
curl -H "Host: $NGINX_HOST" "http://$INGRESS_IP/"
```

If either variable prints empty, use the inspection commands above and confirm the Service has an IP and the Ingress exists with a host before testing.

If `curl` times out or cannot connect, first verify that the IP is current and that the machine is on a network with a route to the AKS VNet; check VPN/peering, routes, and firewall/NSG rules for TCP port 80. The private IP is not reachable from an ordinary public internet connection. If the connection succeeds but returns a different page or an error, check the Ingress host/class and backend endpoints:

```bash
kubectl get ingress --namespace web
kubectl get service,endpoints --namespace web
kubectl get pods --namespace app-routing-system -o wide
```

For a test that exits nonzero on HTTP errors and gives a connection timeout, use the same actual current IP and hostname:

```bash
INGRESS_IP="<private-ip-from-nginx-internal-0>"
NGINX_HOST="nginx.internal.example.com"
curl --fail --show-error --connect-timeout 5 \
  -H "Host: $NGINX_HOST" \
  "http://$INGRESS_IP/"
```

A successful response returns the NGINX demo page HTML. This Host-header test verifies load-balancer reachability and Ingress routing without requiring DNS to be configured yet. Always use the current service address.

To open the site by name in a browser, configure the private DNS A record as described above, then browse to `http://nginx.internal.example.com/` from a client that can resolve the private zone and route to the AKS VNet. An internal load balancer is not accessible from the public internet. If the direct curl test times out, check VNet/VPN connectivity, routing, and firewall/NSG rules for TCP port 80 to the private IP. If the controller pods are `Pending`, inspect scheduling events with `kubectl describe pod --namespace app-routing-system <pending-pod-name>`; insufficient CPU means the cluster needs additional requested-capacity headroom (for example, another node or larger VM size).

After DNS is configured, test name resolution and the website from a connected client:

```bash
getent hosts "$NGINX_HOST"
curl --fail --show-error "http://$NGINX_HOST/"
```

Set the GitHub Actions secret `NGINX_HOST` to the exact same hostname used in the DNS record and Helm Ingress. Organization clients need both DNS resolution and network routes/firewall rules that permit access to the private load balancer.

The default VNet, pod, and service address ranges are examples. Ensure they do not overlap each other or any connected organizational networks.

## Operate and troubleshoot

Run Kubernetes commands from a machine that has connectivity to the private AKS API (for example, the configured self-hosted runner or a VM in a connected VNet). Get or refresh cluster credentials with:

```bash
az aks get-credentials \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw cluster_name)" \
  --admin \
  --overwrite-existing
kubectl config current-context
```

The workflow uses `--admin`, so its deployment identity needs the cluster-admin role described above. For interactive human access, use your organization's preferred Azure RBAC/Kubernetes RBAC setup instead of sharing admin kubeconfig.

### Health-check commands

```bash
# See nodes and which node hosts each pod.
kubectl get nodes -o wide
kubectl get pods --all-namespaces -o wide

# Check the website, Ingress rule, managed controller, and private LB.
kubectl get deployment,service,ingress --namespace web
kubectl get nginxingresscontroller nginx-internal -o yaml
kubectl get pods,service --namespace app-routing-system -o wide

# Inspect events and details when something is Pending or not Ready.
kubectl get events --all-namespaces --sort-by=.lastTimestamp
kubectl describe pods --namespace web
kubectl describe pods --namespace app-routing-system
```

Expected steady state after promotion: website and controller pods are `Running` and ready; `kubectl get ingress -n web -o wide` shows both `azure-application-gateway` and `nginx-internal` classes; and the `nginx-internal-0` Service has a private IP rather than `<pending>`. Verify the hostname and direct NGINX rollback route using [Promote AGIC and keep NGINX for rollback](#promote-agic-and-keep-nginx-for-rollback). Keep NGINX until the rollback window ends.

### CPU usage, requests, limits, and node capacity

These are different measurements:

- **Usage** (`kubectl top`) is what a container is using now.
- **Request** is the CPU/memory Kubernetes reserves for scheduling. A pod can remain `Pending` with `Insufficient cpu` even when `kubectl top` shows low current usage, because available requested capacity is exhausted.
- **Limit** is a cap on what a container can use; it is not the same as the request.

Check current usage (requires the Kubernetes Metrics API) and configured pod resources:

```bash
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=cpu
kubectl describe pod --namespace app-routing-system <controller-pod-name>
kubectl describe nodes
```

The `kubectl describe node` output includes **Allocated resources**, which helps explain scheduler CPU/memory pressure. If `kubectl top` reports `Metrics API not available`, usage metrics are unavailable; inspect pod events and node `Allocated resources` instead.

In the recorded observation from this deployment, each internal controller pod used about `1m` CPU and `46Mi` memory, while the displayed requests were `500m` CPU and `127Mi` memory. These are point-in-time observations, not guaranteed steady-state values.

The internal controller is managed by the AKS application-routing add-on. The supported `NginxIngressController` settings in this project do **not** expose per-pod CPU or memory requests/limits; do not rely on manual edits to its generated Deployment, since AKS may reconcile them. The manifest at [deploy/nginx-internal-controller.yaml](./deploy/nginx-internal-controller.yaml) sets `scaling.minReplicas: 1`. This can lower baseline reserved capacity by allowing one controller pod, but reduces redundancy if that pod or node fails. The controller may scale above the minimum based on demand. Apply the manifest with `kubectl apply -f deploy/nginx-internal-controller.yaml` or let the GitHub workflow apply it. See [Microsoft's controller configuration reference](https://learn.microsoft.com/azure/aks/app-routing-nginx-configuration).

If a pod has `Insufficient cpu` events, first confirm the pod's request and each node's allocated requests. Then add node capacity or select a larger VM size through Terraform. Review `terraform plan` before applying. More nodes/VMs increase Azure cost. Do not edit the live AKS-managed ingress Deployment as a substitute for adding capacity.

### Common symptoms

| Symptom | Likely area | What to check |
|---|---|---|
| GitHub Actions says no matching federated identity (`AADSTS700213`) | OIDC identity | Compare the exact issuer, subject, and audience in the Actions log with the federated credential on the app whose client ID is `AZURE_CLIENT_ID`. See [the OIDC troubleshooting section](#fix-aadsts700213-no-matching-federated-identity-record-found). |
| Runner cannot connect to AKS | Private API connectivity | Ensure the self-hosted runner has VNet/peering, private DNS resolution, and route access to the private AKS API. |
| Image pull fails (`ImagePullBackOff`) | ACR/image | Confirm the workflow pushed the expected image/tag and AKS kubelet identity has `AcrPull` on the registry. Run `kubectl describe pod -n web <pod-name>` and inspect Events. |
| Website pod is `Pending`, event says `Insufficient cpu` | Node capacity / pod requests | Check `kubectl describe pod`, node Allocated resources, then increase node count or VM size through Terraform. |
| `nginx-internal-0` has `<pending>` external IP | Ingress controller / Azure LB | Check controller pod readiness, `kubectl describe nginxingresscontroller nginx-internal`, and namespace events. |
| Direct curl to the private IP times out | Network path | Use the current private IP. Check client VNet/VPN/peering, routes, and TCP 80 firewall/NSG access. The endpoint is not public. |
| Curl by IP works but hostname does not | DNS | Confirm the private A record points to the current IP, the client can resolve the zone, and VNet linking/conditional forwarding is configured. |
| Website Service port-forward works but Ingress test fails | Ingress/controller rule | Verify controller is Ready, the Ingress host/class match, and the backend Service has endpoints. |
| `kubectl top` says Metrics API is unavailable | Metrics API | This prevents usage metrics, but not inspection of requests or scheduler events. Check `kubectl describe nodes` and pod events. |
| Application Gateway reports `ApplicationGatewayFeatureCannotBeEnabledForSelectedSku` for private-only `Standard_v2` | Subscription feature registration | Register `EnableApplicationGatewayNetworkIsolation` for `Microsoft.Network`, wait for `Registered`, then re-register the provider and rerun Terraform. See [resolved errors](#resolved-errors). |
| AGIC pod is `Running` but not `Ready`, restarts, and logs show `ErrorApplicationGatewayForbidden` | AGIC Azure RBAC | Grant the add-on identity `Contributor` on the Application Gateway and `Reader` on its resource group. These assignments are managed in [application_gateway.tf](./application_gateway.tf). |
| AGIC pod events show `ApplicationGatewayInsufficientPermissionOnSubnet` | AGIC subnet permissions | Grant its identity `Network Contributor` on the dedicated Application Gateway subnet. This is managed in [application_gateway.tf](./application_gateway.tf). |
| AGIC Ingress has a blank `ADDRESS` | AGIC reconciliation | Use the private IP from `terraform output -raw application_gateway_private_ip`; check AGIC logs and Application Gateway backend health if the direct Host-header test fails. |
| AGIC Ingress event says `NoPublicIP` and Application Gateway returns `502` | Private frontend selection | Add `appgw.ingress.kubernetes.io/use-private-ip: "true"` to the AGIC Ingress. The Helm template sets this for the private-only gateway. |
| Terraform plans to remove `ingress-for-aks-cluster-id` or `managed-by-k8s-ingress` tags | AGIC/Terraform drift | AGIC adds these tags to the gateway. [application_gateway.tf](./application_gateway.tf) ignores gateway tags so Terraform preserves them. |
| Website hostname resolves in the AKS VNet but not a peered client VNet | Private DNS VNet link | Private DNS links are not transitive across VNet peering. Add a link for the client VNet with `website_client_vnet_id` and apply Terraform. |

Useful focused checks:

```bash
kubectl get ingress --namespace web -o yaml
kubectl get endpoints --namespace web
kubectl get service --namespace app-routing-system
kubectl describe nginxingresscontroller nginx-internal
kubectl get events --all-namespaces --sort-by=.lastTimestamp
```

### Resolved errors

Keep errors encountered during provisioning or operation here with the cause and verified resolution. Append new entries instead of replacing earlier ones.

#### Private-only Application Gateway rejected for `Standard_v2`

**Error:** `ApplicationGatewayFeatureCannotBeEnabledForSelectedSku`. Azure rejected the private-only frontend for `Standard_v2` and reported that private-only deployment wasn't supported for the selected SKU.

**Cause:** The subscription's `Microsoft.Network/EnableApplicationGatewayNetworkIsolation` feature had not been registered. Private-only Application Gateway v2 is production-supported, but the subscription must opt in to this feature first.

**Resolution:** Register the feature, wait until it reports `Registered` (this can take up to 30 minutes), and re-register the network provider:

```powershell
az feature register --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network
az feature show --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network --query properties.state -o tsv
az provider register --namespace Microsoft.Network
```

Then review and rerun `terraform plan` and `terraform apply`. The Application Gateway subnet had already been created successfully when this error occurred; keep it in Terraform state and let Terraform retry the gateway resource.

#### AGIC controller gets 403 when reading Application Gateway

**Error:** The `ingress-appgw-deployment` pod was `Running` but not `Ready`, repeatedly restarted, and its logs showed `ErrorApplicationGatewayForbidden` / `AuthorizationFailed` for `Microsoft.Network/applicationGateways/read`. The message named the missing `Reader` role on `rg-private-aks` and `Contributor` role on `aks-private-appgw`.

**Cause:** The AGIC add-on's managed identity did not have permission to read and update the Application Gateway.

**Resolution:** [application_gateway.tf](./application_gateway.tf) now assigns `Contributor` to that identity on the gateway and `Reader` on the resource group. Run `terraform plan`, verify it only adds these role assignments (and does not replace the cluster or gateway), then `terraform apply`. Allow time for role assignments to propagate; check the controller pod and logs again:

```bash
kubectl get pods --namespace kube-system | grep ingress-appgw
kubectl logs --namespace kube-system deployment/ingress-appgw-deployment
```

The pod log command without `-n kube-system` initially returned `NotFound` because `kubectl logs` defaults to the `default` namespace. Specify `--namespace kube-system` for this add-on.

#### `kubectl describe ingress` returns `NotFound`

**Cause and resolution:** `kubectl describe ingress <name>` searches the current namespace, which is often `default`. The website Ingress is in namespace `web`; specify it explicitly:

```bash
kubectl describe ingress nginx-site-nginx-site-appgw --namespace web
```

#### AGIC cannot join the Application Gateway subnet

**Error:** The pod event reports `ApplicationGatewayInsufficientPermissionOnSubnet` and says the AGIC identity lacks `Microsoft.Network/virtualNetworks/subnets/join/action` on the Application Gateway subnet.

**Cause:** The gateway and resource-group roles do not grant the AGIC identity permission to join the dedicated subnet.

**Fix:** [application_gateway.tf](./application_gateway.tf) now grants that identity `Network Contributor` scoped only to `azurerm_subnet.application_gateway`. Run `terraform plan`, confirm it adds the subnet role assignment without replacing the cluster or gateway, then apply. Allow Azure RBAC time to propagate; AGIC should retry automatically. Check recent events and logs with:

```bash
kubectl get events -n kube-system --sort-by=.lastTimestamp
kubectl logs -n kube-system deployment/ingress-appgw-deployment --tail=50
```

#### AGIC ignores an Ingress on a private-only gateway

**Error:** The Ingress event reports `NoPublicIP`, says the gateway needs a public IP or the private-IP annotation, and a request to the gateway returns `502 Bad Gateway`.

**Cause:** This Application Gateway intentionally has only a private frontend. AGIC needs the Ingress to opt in to that private frontend.

**Resolution:** The primary [AGIC Ingress template](./charts/nginx-site/templates/ingress.yaml) sets `appgw.ingress.kubernetes.io/use-private-ip: "true"`. During the initial parallel-route test, the live Ingress was annotated and AGIC reconciled it; `kubectl get ingress -n web -o wide` then showed address `10.20.4.250`, and a direct request with the matching Host header returned `HTTP 200`. If the live object is missing the annotation, apply it and redeploy the chart so Helm keeps the setting:

```bash
kubectl annotate ingress nginx-site-nginx-site-appgw \
  --namespace web \
  appgw.ingress.kubernetes.io/use-private-ip="true" \
  --overwrite
```

Then redeploy the updated chart through GitHub Actions so Helm keeps the annotation. Confirm the `NoPublicIP` event stops appearing and retest the private gateway IP with the hostname in the `Host` header.

#### Terraform reports missing Private DNS name and resource group arguments

**Error:** `terraform validate` reports missing `private_dns_zone_name` and `resource_group_name` for the VNet link, missing `zone_name` and `resource_group_name` for the A record, and rejects `private_dns_zone_id`.

**Cause and resolution:** The schema in the AzureRM provider selected by this project requires the zone name and resource group for these resources. [dns.tf](./dns.tf) now uses those required arguments and removes the unsupported `private_dns_zone_id`.

#### Website DNS does not resolve from a peered VNet

**Observation:** The A record exists and points to `10.20.4.250`, and the Private DNS link to the AKS VNet is `Completed`, but a VM in a peered VNet gets no DNS answer.

**Cause:** Azure Private DNS zone links are per-VNet; VNet peering does not make the zone resolvable from the peer.

**Fix:** Set `website_client_vnet_id` to the client VM's VNet resource ID in `terraform.tfvars` and apply. [dns.tf](./dns.tf) creates the additional link when this value is set. Verify the link is `Completed`, then check `getent hosts nginx.internal.example.com` and `curl --fail --show-error http://nginx.internal.example.com/` from the client VM. If a direct query to `168.63.129.16` succeeds but `getent` still fails, check whether the client VNet uses a custom DNS server and configure forwarding for the private zone.

#### Grafana major version rejected by the AzureRM provider

**Error:** Terraform validation reported `expected grafana_major_version to be one of ["11" "12"], got 13`.

**Cause and resolution:** The configured Grafana major version was not accepted by the AzureRM provider version in use. Set `grafana_major_version = 12` in [monitoring.tf](./monitoring.tf), then run `terraform validate` again.

### Redeploy, roll back, and uninstall the website

To redeploy, open **GitHub repository → Actions → Build and deploy nginx site → Run workflow**, select the branch containing the code to deploy, and confirm **Run workflow**. Pushes to branches do not start a deployment. The workflow uses the selected commit's SHA as the image tag, so each deployment points the chart to that build. Check the Actions run for failures and use the health checks above afterward.

List Helm releases and revisions:

```bash
helm list --namespace web
helm history nginx-site --namespace web
```

To roll back to a previously listed revision, replace `<revision>` with the desired revision number:

```bash
helm rollback nginx-site <revision> --namespace web --wait
```

This rolls back the Helm-managed website resources. The internal controller is a separate AKS custom resource and is not rolled back with the Helm release.

To remove only the website release (not AKS, ACR, the controller, or Azure resources):

```bash
helm uninstall nginx-site --namespace web
```

Do not run `terraform destroy` unless you intend to delete Terraform-managed Azure infrastructure. Review its plan carefully and preserve any data or resources you still need.

## Important files

| Path | Purpose |
|---|---|
| `main.tf`, `application_gateway.tf`, `dns.tf`, `monitoring.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | AKS, ingress gateway, private website DNS, monitoring, and Terraform configuration. |
| `terraform.tfvars.example` | Safe-to-commit sample input values. Copy it to ignored `terraform.tfvars` and fill in your own values. |
| `.gitignore` | Excludes Terraform state and actual `.tfvars` files. |
| `.github/workflows/deploy.yml` | Image build/push and AKS deployment workflow. |
| `Dockerfile`, `site/index.html` | Website container image and page content. |
| `charts/nginx-site/` | Helm chart for the website Deployment, Service, and Ingress. |
| `deploy/nginx-internal-controller.yaml` | AKS-managed internal ingress-controller configuration and minimum replica setting. |
| `HELM-INGRESS-GUIDE.md` | Beginner-friendly explanation of Helm, Ingress, every related template, testing, and troubleshooting. |
| `NGINX-INGRESS-IMPLEMENTATION.md` | Rebuild guide for the original internal NGINX Ingress, including deployment steps and errors/resolutions. |
| `AKS-MONITORING-IMPLEMENTATION.md` | Monitoring architecture, Terraform resources, verification steps, access requirements, and Grafana version troubleshooting. |
| `NGINX-TO-AGIC-MIGRATION.md` | Detailed migration record for the private Application Gateway/AGIC route, DNS, rollback, and encountered errors. |
