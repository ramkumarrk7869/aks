# Private AKS Terraform

This project provisions a private AKS cluster and Azure Container Registry (ACR), builds a small NGINX website into a Docker image, and deploys it with Helm and GitHub Actions. AKS uses Azure CNI Overlay and a user-assigned control-plane identity.

For a beginner-friendly, file-by-file explanation of the Helm chart, website Ingress, internal controller, workflow, and testing steps, see the [Helm and Ingress guide](./HELM-INGRESS-GUIDE.md).

## Contents

- [Project at a glance](#project-at-a-glance)
- [Prerequisites](#prerequisites)
- [Provision AKS and ACR](#provision-aks-and-acr)
- [Configure GitHub Actions](#configure-github-actions)
- [Internal access](#internal-access)
- [Operate and troubleshoot](#operate-and-troubleshoot)
- [Important files](#important-files)

## Project at a glance

This repository provisions and deploys a small private website. The major components and their owners are:

| Component | What it does | Managed/configured by |
|---|---|---|
| Resource group, VNet, subnet, AKS, ACR, identities, role assignments | Azure infrastructure and cluster access | Terraform |
| `system` node pool | Runs Kubernetes system components and workloads | Terraform, through `node_count` and `node_vm_size` |
| `workload` node pool | Adds compute capacity for workloads | Terraform, currently one node in `main.tf` |
| Application-routing add-on and `app-routing-system` namespace | Provides the managed NGINX ingress controller platform | AKS |
| Default NGINX controller | Disabled because this project does not use its `webapprouting.kubernetes.azure.com` class or public load balancer | `web_app_routing.default_nginx_controller = "None"` in `main.tf` |
| `nginx-internal` controller configuration | Requests a private load balancer and sets the controller's minimum replica count | `deploy/nginx-internal-controller.yaml`, applied by GitHub Actions |
| Website Deployment, Service, and Ingress | Runs the website and routes matching HTTP requests | Helm chart in `charts/nginx-site`, installed by GitHub Actions |
| Container image | NGINX plus `site/index.html` | Dockerfile, pushed to ACR by GitHub Actions |

The website's request path uses the dedicated internal controller; the unused default controller is not part of this path:

```text
Client on a connected private network
  -> private Azure Load Balancer IP
  -> AKS-managed NGINX ingress controller
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

## Configure GitHub Actions

The workflow at `.github/workflows/deploy.yml` builds and pushes the image to ACR, then deploys the website and a Kubernetes `Ingress` resource with Helm. AKS application routing manages an internal NGINX ingress controller and internal Azure Load Balancer for the `nginx-internal` ingress class.

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

The workflow builds an image tagged with the commit SHA, pushes it to ACR, applies the internal controller manifest, and runs `helm upgrade --install` in namespace `web`. It prints the website resources and controller load-balancer Service at the end. See [HELM-INGRESS-GUIDE.md](./HELM-INGRESS-GUIDE.md) for a step-by-step explanation of the chart templates and workflow.

## Internal access

The Helm chart creates an `Ingress` for `NGINX_HOST` using the `nginx-internal` class. Its controller requests an internal Azure Load Balancer, so the endpoint is not public. After deployment, inspect the Ingress and controller with:

```bash
kubectl get ingress --namespace web
kubectl get nginxingresscontroller nginx-internal
kubectl get service --namespace app-routing-system \
  --output custom-columns=NAME:.metadata.name,TYPE:.spec.type,IP:.status.loadBalancer.ingress[0].ip
```

The `IP` column is the controller's load balancer IP. Wait for it to be assigned; it should be a private address. For Azure Private DNS, create a private zone for your organization's internal DNS suffix, link it to the AKS VNet (and any client VNets that need to resolve it), and create an A record. Replace the example domain with a DNS zone that your organization controls. The following example makes `nginx.internal.example.com` resolve to the private ingress IP:

```bash
RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
CLUSTER_NAME="$(terraform output -raw cluster_name)"
VNET_NAME="${CLUSTER_NAME}-vnet"
DNS_ZONE="internal.example.com"
NGINX_HOST="nginx.internal.example.com"
RECORD_NAME="${NGINX_HOST%.$DNS_ZONE}"

VNET_ID="$(az network vnet show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --query id --output tsv)"

az network private-dns zone create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DNS_ZONE"

az network private-dns link vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$DNS_ZONE" \
  --name "${CLUSTER_NAME}-dns-link" \
  --virtual-network "$VNET_ID" \
  --registration-enabled false

# Read the IP from the LoadBalancer service shown by kubectl above.
INGRESS_IP="<private-load-balancer-ip>"

az network private-dns record-set a create \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$DNS_ZONE" \
  --name "$RECORD_NAME" \
  --ttl 300

az network private-dns record-set a add-record \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$DNS_ZONE" \
  --record-set-name "$RECORD_NAME" \
  --ipv4-address "$INGRESS_IP"

az network private-dns record-set a show \
  --resource-group "$RESOURCE_GROUP" \
  --zone-name "$DNS_ZONE" \
  --name "$RECORD_NAME" \
  --output table
```

For an existing zone, skip the `zone create` command. For existing VNet links, skip creating a duplicate link. Link every VNet from which clients need to resolve this private zone. If clients are on-premises or use corporate DNS, an Azure Private DNS VNet link alone is not enough: configure your organization's DNS administrators to create the A record there or configure conditional forwarding to Azure DNS through an Azure DNS Private Resolver/DNS forwarder.

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

Expected steady state: website pods and ingress controller pod(s) are `Running` and ready; the website Ingress has the intended host and `nginx-internal` class; and the `nginx-internal-0` Service has a private IP rather than `<pending>`. Use the direct IP + Host-header curl in [Internal access](#internal-access) to separate DNS issues from load-balancer/routing issues.

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

Useful focused checks:

```bash
kubectl get ingress --namespace web -o yaml
kubectl get endpoints --namespace web
kubectl get service --namespace app-routing-system
kubectl describe nginxingresscontroller nginx-internal
kubectl get events --all-namespaces --sort-by=.lastTimestamp
```

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
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Azure resources and Terraform configuration. |
| `terraform.tfvars.example` | Safe-to-commit sample input values. Copy it to ignored `terraform.tfvars` and fill in your own values. |
| `.gitignore` | Excludes Terraform state and actual `.tfvars` files. |
| `.github/workflows/deploy.yml` | Image build/push and AKS deployment workflow. |
| `Dockerfile`, `site/index.html` | Website container image and page content. |
| `charts/nginx-site/` | Helm chart for the website Deployment, Service, and Ingress. |
| `deploy/nginx-internal-controller.yaml` | AKS-managed internal ingress-controller configuration and minimum replica setting. |
| `HELM-INGRESS-GUIDE.md` | Beginner-friendly explanation of Helm, Ingress, every related template, testing, and troubleshooting. |
