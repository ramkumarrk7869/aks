# Private AKS Terraform

This project provisions a private AKS cluster and Azure Container Registry (ACR), builds a small NGINX website into a Docker image, and deploys it with Helm and GitHub Actions. AKS uses Azure CNI Overlay and a user-assigned control-plane identity.

## Prerequisites

- Terraform 1.5 or later
- Azure CLI, authenticated to the subscription
- Azure permissions to create resource groups, networking resources, and AKS clusters, including permission to create role assignments on the AKS subnet

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

Terraform creates a Basic ACR with its admin account disabled, then grants the AKS kubelet identity `AcrPull` on that registry. The registry name is generated from the cluster name and subscription ID; see the `acr_name` and `acr_login_server` outputs.

## Configure GitHub Actions

The workflow at `.github/workflows/deploy.yml` builds and pushes the image to ACR, then deploys the website and a Kubernetes `Ingress` resource with Helm. AKS application routing manages an internal NGINX ingress controller and internal Azure Load Balancer for the `nginx-internal` ingress class.

> **Assignment / support lifecycle:** This uses the AKS-managed NGINX Ingress option to satisfy an Ingress-resource requirement. Upstream ingress-nginx maintenance ended in March 2026, and AKS support for its managed NGINX Ingress resources ends in November 2026. For a longer-lived deployment, use Gateway API or Application Gateway for Containers instead. See the [AKS application routing documentation](https://learn.microsoft.com/azure/aks/app-routing).

### Enable AKS application routing

The `web_app_routing` block in [main.tf](./main.tf) declares AKS application routing so Terraform tracks the add-on and does not plan to remove it. Its empty `dns_zone_ids` list means this project is not attaching a custom Azure DNS zone. The `AnnotationControlled` setting leaves Ingress class selection to each Ingress resource. The add-on provides the managed controller and `NginxIngressController` resource type used by the internal controller manifest and website Ingress.

If enabling it outside Terraform, as you already did, this command does that through Azure's management plane and does not require direct access to the private Kubernetes API:

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
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
TENANT_ID="$(az account show --query tenantId --output tsv)"

APP_ID="$(az ad app create --display-name "gh-aks-nginx-deployer" --query appId --output tsv)"
SP_OBJECT_ID="$(az ad sp create --id "$APP_ID" --query id --output tsv)"

cat > github-federated-credential.json <<EOF
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${OWNER}/${REPO}:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters @github-federated-credential.json
rm github-federated-credential.json
```

The resulting subject must look like `repo:OWNER/REPOSITORY:ref:refs/heads/main`. If your repository uses a different default branch, update both the federated credential subject and the workflow trigger to match.

### Grant least-privilege Azure roles

The service principal needs `AcrPush` scoped to ACR and `Azure Kubernetes Service Cluster Admin Role` scoped to this AKS cluster. The latter is needed because the workflow requests admin kubeconfig with `az aks get-credentials --admin`.

```bash
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

With GitHub CLI authenticated to the target repository, run:

```bash
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

After enabling the add-on, setting up the runner, and granting roles, push to `main` or run **Actions → Build and deploy nginx site → Run workflow**.

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

Test from a machine that has network connectivity to the AKS VNet/load balancer and can resolve the zone:

```bash
getent hosts "$NGINX_HOST"
curl --fail --show-error "http://$NGINX_HOST/"
```

Also set the GitHub Actions secret `NGINX_HOST` to the exact same hostname used in the DNS record and Helm Ingress. Organization clients need both DNS resolution and network routes/firewall rules that permit access to the private load balancer.

The default VNet, pod, and service address ranges are examples. Ensure they do not overlap each other or any connected organizational networks.
