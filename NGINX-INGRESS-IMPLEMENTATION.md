# Implementing the Internal NGINX Ingress on AKS

This is a repeatable reference for the original private website route using the AKS application-routing add-on, its managed `nginx-internal` controller, a Helm-deployed website, and an internal Azure Load Balancer. It records the actual configuration and operational issues encountered in this repository.

> **Scope and current state:** This guide documents the original NGINX Ingress implementation before Application Gateway/AGIC was added. The repository has since promoted AGIC as the chart's primary route and retains NGINX for rollback. The current chart does not reproduce an NGINX-only deployment by itself; use the historical configuration described here as a reference and adjust the chart templates deliberately if recreating that original state.

## 1. Architecture

The pieces have different jobs:

- **AKS application-routing add-on:** Provides the managed NGINX controller capability and the `NginxIngressController` Kubernetes resource type.
- **`NginxIngressController` resource:** Requests one dedicated controller, selects the `nginx-internal` class, and requests an internal load balancer.
- **Ingress resource:** A Kubernetes HTTP routing rule. It matches the website hostname and path and points to a Service.
- **NGINX ingress controller:** Reads Ingress resources for its class and proxies incoming HTTP requests to their Service backends.
- **ClusterIP Service:** Provides a stable in-cluster endpoint for the website pods.
- **Deployment and pods:** Run the website container.
- **Internal Azure Load Balancer:** Provides a private IP for traffic entering the controller. It is not a public endpoint.
- **Helm:** Installs and updates the Deployment, Service, and Ingress from the chart.
- **ACR and GitHub Actions:** Store the image and automate its build, push, and deployment.
- **Private DNS (optional):** Maps the website hostname to the current private load-balancer IP for clients that can resolve the zone.

Request path:

```text
Client on AKS VNet or a connected/peered network
  -> private Azure Load Balancer IP
  -> AKS-managed nginx-internal controller
  -> Ingress host/path rule in namespace web
  -> ClusterIP Service in namespace web
  -> one of the website pods
  -> website HTML
```

The Ingress is only a rule; it does not run NGINX. The Service and Deployment do not expose a public IP. Clients need network access to the private IP. For DNS access, they also need to resolve the private hostname.

## 2. Prerequisites and decisions

Before deploying, confirm:

1. AKS exists and the Kubernetes API is reachable from the machine or automation runner used for `kubectl` and Helm. This project uses a **private** AKS API.
2. AKS application routing is enabled. Its managed namespace is `app-routing-system`.
3. The AKS subnet and connected network ranges do not overlap.
4. The client can route to the AKS VNet or a peered VNet, and TCP port 80 is allowed to the internal load balancer.
5. If building/pushing the image, the runner has Docker, Azure CLI, Helm, GitHub connectivity, and ACR access.
6. Decide on the Ingress hostname. This project uses `nginx.internal.example.com` as an example; use a hostname in an internal DNS zone that you control.

Terraform manages the AKS configuration in [main.tf](./main.tf). The relevant shape is:

```hcl
web_app_routing {
  dns_zone_ids             = []
  default_nginx_controller = "None"
}
```

`default_nginx_controller = "None"` disables the add-on's **default** controller. It does not disable the add-on or the separately declared `nginx-internal` controller below. Do not remove the `web_app_routing` block while using the custom `NginxIngressController` resource.

For a cluster not yet provisioned, follow the repository's Terraform setup first. For an existing cluster, review the Terraform plan and confirm it does not unexpectedly replace the cluster:

```bash
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

Do not run `terraform apply` until the plan is understood.

## 3. Request the dedicated internal NGINX controller

The controller is managed by AKS application routing, not by the website Helm chart. The repository's [deploy/nginx-internal-controller.yaml](./deploy/nginx-internal-controller.yaml) is:

```yaml
apiVersion: approuting.kubernetes.azure.com/v1alpha1
kind: NginxIngressController
metadata:
  name: nginx-internal
spec:
  ingressClassName: nginx-internal
  controllerNamePrefix: nginx-internal
  scaling:
    minReplicas: 1
  loadBalancerAnnotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

What the fields do:

- `kind: NginxIngressController` asks the AKS add-on to provision a managed controller.
- `metadata.name` identifies the custom resource.
- `ingressClassName` is the class the website Ingress must use. The add-on creates/manages the corresponding `IngressClass`.
- `controllerNamePrefix` is a separate naming prefix for resources managed by the NGINX controller.
- `minReplicas: 1` reduces the minimum replica count; it also means less redundancy at low demand. The add-on can scale above this minimum.
- The Azure Load Balancer annotation requests an **internal** load balancer.

These two values can differ: one selects which Ingress resources the controller watches, while the other names the controller's managed resources. In this example both are `nginx-internal` for clarity. When configuring multiple controllers, use a unique `controllerNamePrefix` for each and make sure each Ingress uses the intended `ingressClassName`. Changing the prefix on an existing controller can affect its managed resource names, so do not change it casually. See [Microsoft's NGINX controller configuration reference](https://learn.microsoft.com/azure/aks/app-routing-nginx-configuration).

Connect to the cluster and apply the resource:

```bash
az aks get-credentials \
  --resource-group "<AKS-resource-group>" \
  --name "<AKS-cluster-name>" \
  --admin \
  --overwrite-existing

kubectl apply -f deploy/nginx-internal-controller.yaml
kubectl get nginxingresscontroller nginx-internal -o yaml
kubectl get pods --namespace app-routing-system -o wide
kubectl get services --namespace app-routing-system -o wide
```

`--admin` is used by this repository's current workflow. If choosing non-admin credentials, configure the appropriate AKS/Kubernetes authorization and permissions for the deployer. Never put kubeconfig credentials in the repository.

The add-on creates and manages `app-routing-system`; do not create or own that namespace yourself. The website is installed into a separate `web` namespace.

Wait for the generated controller pods to become Ready and for the controller Service (often named `nginx-internal-0`) to receive a private IP. `kubectl get services -n app-routing-system -o wide` shows its `EXTERNAL-IP`; despite that column's name, the address should be private, not publicly routable.

## 4. Deploy the website and its NGINX Ingress with Helm

The Helm chart is in [charts/nginx-site](./charts/nginx-site):

- [values.yaml](./charts/nginx-site/values.yaml): defaults to two replicas, `ClusterIP`, host `nginx.internal.example.com`, and Ingress class `nginx-internal`.
- [templates/deployment.yaml](./charts/nginx-site/templates/deployment.yaml): runs the website pods and HTTP readiness/liveness probes.
- [templates/service.yaml](./charts/nginx-site/templates/service.yaml): selects the pods and exposes port 80 inside the cluster.
- [templates/ingress.yaml](./charts/nginx-site/templates/ingress.yaml): matches the host and `/` path and sends traffic to the Service.
- [templates/_helpers.tpl](./charts/nginx-site/templates/_helpers.tpl): creates stable names and labels. With Helm release name `nginx-site`, the website resources are named `nginx-site-nginx-site`.
- [Dockerfile](./Dockerfile) and [site/index.html](./site/index.html): build the NGINX image and the example page.

The Service is `ClusterIP`, so it does not create a load balancer. The `NginxIngressController` resource creates the separate controller's internal load balancer.

### Manual deployment

Build and push the image to ACR first, or use an image already available to the AKS nodes. Then run from a machine that has private AKS API access:

```bash
az aks get-credentials \
  --resource-group "<AKS-resource-group>" \
  --name "<AKS-cluster-name>" \
  --admin \
  --overwrite-existing

kubectl apply -f deploy/nginx-internal-controller.yaml

helm upgrade --install nginx-site ./charts/nginx-site \
  --namespace web \
  --create-namespace \
  --set-string image.repository="<ACR-login-server>/nginx-site" \
  --set-string image.tag="<image-tag-present-in-ACR>" \
  --set-string ingress.host="nginx.internal.example.com" \
  --wait \
  --timeout 5m
```

Replace placeholders with the actual resource group, cluster, registry, image tag, and hostname. The image must exist in ACR and be pullable by AKS. The AKS kubelet identity needs `AcrPull` on ACR. Terraform in this repository assigns that role.

In the original chart, the primary Ingress used class `nginx-internal`, and the later parallel-test version added an optional AGIC Ingress using `ingress.applicationGateway.enabled=true`. The current chart no longer uses that optional setting: it defines AGIC as primary and renders the NGINX rollback route using `ingress.nginxRollback.enabled=true`. Do not apply the historical command unchanged and assume it creates an NGINX-only route.

Optionally render the resources before applying:

```bash
helm template nginx-site ./charts/nginx-site \
  --namespace web \
  --set-string image.repository="<ACR-login-server>/nginx-site" \
  --set-string image.tag="<image-tag>" \
  --set-string ingress.host="nginx.internal.example.com"
```

For subsequent releases, Helm updates this existing release with the same name:

```bash
helm upgrade --install nginx-site ./charts/nginx-site \
  --namespace web \
  --set-string image.repository="<ACR-login-server>/nginx-site" \
  --set-string image.tag="<image-tag>" \
  --set-string ingress.host="nginx.internal.example.com" \
  --wait \
  --timeout 5m
```

### GitHub Actions deployment used by this repository

The workflow is [.github/workflows/deploy.yml](./.github/workflows/deploy.yml). It is manually started from **GitHub repository → Actions → Build and deploy nginx site → Run workflow**; a push alone does not run it. Its stages are:

1. Check out the selected commit.
2. Sign in to Azure using GitHub OIDC and `azure/login@v2`.
3. Check required configuration.
4. Install Helm.
5. Sign in to ACR, build the Docker image, tag it with the Git commit SHA, and push it.
6. Get AKS credentials.
7. Apply `deploy/nginx-internal-controller.yaml`.
8. Run `helm upgrade --install` for the website in namespace `web`.
9. Print the Deployment, Service, Ingress, controller, and controller Service.

The runner is self-hosted because the AKS API is private. It must have private network/DNS access to AKS, Docker with a working daemon, Azure CLI, and outbound connectivity to GitHub and ACR. OIDC avoids a long-lived Azure client secret. The deployer identity needs `AcrPush` on the registry and currently `Azure Kubernetes Service Cluster Admin Role` on the cluster because the workflow requests `--admin` kubeconfig. Use least privilege and restrict who can run/modify the deployment workflow.

For the current OIDC workflow, an Azure administrator creates an Entra application/service principal and GitHub federated credential. The repository has an example identity-creation procedure in [README.md](./README.md#create-a-github-deployment-identity-with-oidc); the essential values are:

- Issuer: `https://token.actions.githubusercontent.com`
- Audience: `api://AzureADTokenExchange`
- Subject: exact GitHub repository/owner IDs and deployment ref (for example, the `main` branch)

The subject is case-sensitive and must match the subject emitted by the workflow. Assign the service principal `AcrPush` on ACR and `Azure Kubernetes Service Cluster Admin Role` on the AKS cluster, then configure the workflow's `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` secrets. OIDC uses no client secret. The identity creator needs Entra application-creation permission and Azure role-assignment permission.

If GitHub's Azure login fails with `AADSTS700213: No matching federated identity record found`, compare the exact issuer, subject, and audience in the Actions log with the federated credential on the application whose client ID is in `AZURE_CLIENT_ID`. A credential for an old subject format, wrong branch, or different application will not match.

Required repository Actions values/secrets in the current workflow:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`: OIDC app identity details.
- `ACR_NAME`, `ACR_LOGIN_SERVER`: registry name and login server.
- `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`: target cluster.
- `NGINX_HOST`: exact Ingress hostname, e.g. `nginx.internal.example.com`.

The image name is `nginx-site`; the image tag is `${{ github.sha }}`. The earlier parallel-test workflow additionally set `ingress.applicationGateway.enabled=true`. That setting belongs to the old chart configuration and is not used by the current promoted chart.

## 5. Verify the Kubernetes resources

Run:

```bash
kubectl get nodes -o wide
kubectl get pods --namespace web -o wide
kubectl get deployment,service,ingress --namespace web -o wide
kubectl get nginxingresscontroller nginx-internal
kubectl get pods,services --namespace app-routing-system -o wide
kubectl get endpoints --namespace web
```

Expected:

- Website Deployment has the requested replicas Available.
- Website pods are `Running` and Ready.
- The Service is `ClusterIP` on port 80 and has pod endpoints.
- The Ingress host is the configured hostname and its `CLASS` is `nginx-internal`.
- Controller pods in `app-routing-system` are Ready.
- Controller Service `nginx-internal-0` has a private IP, not `<pending>`.

Inspect events and logs for anything not Ready:

```bash
kubectl get events --all-namespaces --sort-by=.lastTimestamp
kubectl describe pods --namespace web
kubectl describe pods --namespace app-routing-system
kubectl logs --namespace app-routing-system <controller-pod-name> --tail=100
```

For a known resource name, always provide its namespace to `kubectl describe`, `logs`, `get`, or `delete` if it is not in the current namespace.

## 6. Test the route without DNS first

Find the current private IP:

```bash
kubectl get service nginx-internal-0 \
  --namespace app-routing-system \
  -o wide
```

Send a request with the same Host value as the Ingress. Replace the IP if the current Service has a different one:

```bash
curl --fail --show-error --connect-timeout 5 \
  -H "Host: nginx.internal.example.com" \
  "http://10.20.0.6/"
```

A successful page contains `Hello from NGINX on private AKS`. This verifies the client-to-private-load-balancer network path, controller, Ingress host rule, Service, and website pod. A Host header is necessary for an IP-based request because the controller selects a route by host.

To check the website independently of Ingress, port-forward the Service:

```bash
kubectl port-forward --namespace web service/nginx-site-nginx-site 8080:80
```

In another terminal:

```bash
curl --fail --show-error http://127.0.0.1:8080/
```

This only verifies the Service and website; it does not test the ingress controller or private load balancer.

## 7. Configure private DNS (optional)

The Ingress hostname is not automatically a DNS record. To browse by name, create an A record in an internal DNS zone pointing to the current NGINX load-balancer IP. This project later used Terraform-managed Azure Private DNS:

- Zone: `internal.example.com`
- Record: `nginx`
- FQDN: `nginx.internal.example.com`
- Initial NGINX address: `10.20.0.6`

Link the Private DNS zone to every client VNet that needs to resolve it. A link to the AKS VNet does not automatically make the zone resolvable in a peered client VNet. If clients use custom DNS or are on premises, configure conditional forwarding (for example via Azure DNS Private Resolver or a DNS forwarder). DNS resolution and network reachability are separate requirements.

Check resolution and HTTP from the actual client:

```bash
getent hosts nginx.internal.example.com
curl --fail --show-error http://nginx.internal.example.com/
```

If `getent` fails, test Azure's DNS resolver directly where applicable:

```bash
nslookup nginx.internal.example.com 168.63.129.16
```

If this direct query works but `getent` does not, check the client's configured resolver/custom DNS forwarding. Private IPs are not reachable from an unrelated public network.

## 8. Capacity and controller sizing

At the time the original controller was introduced, the one-node cluster had nearly all allocatable CPU already reserved by pod requests. The ingress pod stayed `Pending` with `Insufficient cpu`, even though current CPU usage could appear low. The solution was to add a separate one-node `workload` node pool through Terraform. This created scheduling headroom, after which the NGINX controller became reachable and served the website. More nodes or a larger VM size increase Azure cost.

Always inspect scheduling events and requests, not only live usage:

```bash
kubectl describe pod --namespace app-routing-system <pending-pod-name>
kubectl describe nodes
kubectl top nodes
kubectl top pods --namespace app-routing-system
```

`kubectl top` requires the Metrics API and reports current usage. Scheduler placement is based on requests and allocatable capacity. If capacity is insufficient, change node counts/size through Terraform, review its plan, and apply. The AKS-managed controller's per-pod requests/limits are not configurable through this `NginxIngressController` manifest; avoid editing the add-on-owned Deployment because AKS can reconcile those edits away.

The controller manifest sets `minReplicas: 1` to reduce baseline requested capacity. That also reduces redundancy at low demand; the controller can scale above one. Choose a minimum appropriate for the service's availability needs.

## 9. Roll back or remove the website release

View releases and history:

```bash
helm list --namespace web
helm history nginx-site --namespace web
```

Roll back the Helm-managed website resources to a previous revision:

```bash
helm rollback nginx-site <revision> --namespace web --wait
```

The controller custom resource is separate and is not changed by Helm rollback. To remove only the website:

```bash
helm uninstall nginx-site --namespace web
```

Do not delete `nginx-internal` or the whole application-routing add-on if other websites still use it. Do not run `terraform destroy` unless deleting the Azure infrastructure is intended and its plan has been reviewed.

## Errors encountered and how they were resolved

### Controller pod Pending: `Insufficient cpu`

**Symptom:** A managed NGINX ingress-controller pod was `Pending` and its Events reported `Insufficient cpu`.

**Cause:** Kubernetes scheduling accounts for CPU requests reserved by existing pods, not only current CPU usage. The original one-node cluster had insufficient unrequested/allocatable capacity for another controller pod.

**Resolution:** Added a separate one-node `workload` pool through Terraform. The controller then scheduled and the NGINX route became reachable. For a recurrence, inspect `kubectl describe pod` and node Allocated resources, then add capacity or select a larger VM size with Terraform. Review the plan and account for the added cost.

### Controller Service has `<pending>` IP

**Symptom:** `nginx-internal-0` did not yet show an IP.

**Checks:** Verify the controller custom resource and pods, then examine namespace events:

```bash
kubectl get nginxingresscontroller nginx-internal -o yaml
kubectl get pods --namespace app-routing-system -o wide
kubectl describe nginxingresscontroller nginx-internal
kubectl get events --namespace app-routing-system --sort-by=.lastTimestamp
```

The internal load balancer can take time to provision. If it remains pending, use the events to identify Azure networking/permissions issues and ensure the AKS identity can manage load balancer resources on the AKS subnet.

### `kubectl top` reports Metrics API unavailable

**Symptom:** `kubectl top` could not report pod/node usage.

**Impact:** This only prevents current-usage metrics. It does not prevent scheduling diagnostics. Use `kubectl describe pod`, `kubectl describe nodes`, and node Allocated resources to investigate requests and capacity.

### Curl to the private IP times out

**Cause:** The client may not have a route to the AKS VNet, may be using a stale IP, or TCP 80 may be blocked.

**Resolution:** Re-read the current IP from `nginx-internal-0`; confirm VNet/peering/VPN routes, DNS if relevant, and firewall/NSG access to TCP 80. The endpoint is private and cannot be reached from an unrelated public network.

### IP/Service test works but Ingress test does not

Check all of these:

```bash
kubectl get ingress --namespace web -o yaml
kubectl get nginxingresscontroller nginx-internal -o yaml
kubectl get service --namespace app-routing-system -o wide
kubectl get endpoints --namespace web
```

The Ingress must use class `nginx-internal`; its `host` must match the HTTP `Host` header; its backend Service name/port must match the Helm Service; controller pods must be Ready; and the Service must have website pod endpoints.

### Browser cannot resolve the hostname

**Cause:** DNS record is missing/wrong, the zone is not linked to the client VNet, custom DNS forwarding is missing, or the client is using a stale cached answer.

**Resolution:** Check `getent hosts` on the same client, query the configured DNS resolver, verify the record points to the current private IP, and verify a VNet link exists for the client VNet. For peered VNets, create an explicit link for each VNet that needs the private zone.

### `kubectl describe` or `kubectl logs` returns `NotFound`

**Cause:** Kubernetes commands default to the current namespace, commonly `default`. The website is in `web`; the controller is in `app-routing-system`; the AGIC add-on (later migration stage) is in `kube-system`.

**Resolution:** Specify the correct namespace, for example:

```bash
kubectl describe ingress nginx-site-nginx-site --namespace web
kubectl logs --namespace app-routing-system <controller-pod-name>
```

## Rebuild checklist

- [ ] AKS application-routing add-on enabled in Terraform; do not disable the add-on itself.
- [ ] AKS private API reachable from the deployment machine/runner.
- [ ] `NginxIngressController/nginx-internal` applied successfully.
- [ ] Controller pods Ready; `nginx-internal-0` has a private IP.
- [ ] Website image exists in ACR and AKS kubelet identity has `AcrPull`.
- [ ] Helm installs website Deployment, ClusterIP Service, and `nginx-internal` Ingress in `web`.
- [ ] Ingress class, hostname, backend Service, and port match.
- [ ] Host-header curl to the private controller IP returns the website.
- [ ] Optional private DNS resolves to the current NGINX private IP from each required client VNet.
- [ ] Controller and website pods have enough requested node capacity.
- [ ] NGINX-only deployment does not enable the optional AGIC Ingress.
