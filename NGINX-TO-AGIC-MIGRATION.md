# AKS NGINX Ingress to Application Gateway + AGIC

This guide records the migration stages, current state, verification commands, rollback, and errors encountered while moving the private AKS website from its internal NGINX Ingress to a private Azure Application Gateway managed by AGIC.

## Status and last confirmed state

The last cluster output shared on 2026-11-20 showed both Ingresses and working DNS. The user deferred promotion on 2026-11-20 and approved it on 2026-11-27. The chart/workflow source has now been updated to make AGIC primary and retain NGINX for rollback; deployment of this updated source to the cluster is still pending.

The website's DNS cutover to Application Gateway was already working before chart promotion. The chart now describes AGIC as the primary/default Ingress and NGINX as an enabled rollback route, but the cluster has not yet been updated with this chart revision. Both controllers and routes should be retained. No NGINX cleanup has been performed.

The latest reported command was:

```text
NAME                          CLASS                       HOSTS                        ADDRESS       PORTS   AGE
nginx-site-nginx-site         nginx-internal              nginx.internal.example.com   10.20.0.6     80      7d3h
nginx-site-nginx-site-appgw   azure-application-gateway   nginx.internal.example.com   10.20.4.250   80      118m
```

Current addresses:

- NGINX internal load balancer: `10.20.0.6`
- Private Application Gateway frontend: `10.20.4.250`
- Website hostname: `nginx.internal.example.com`
- Tested protocol: HTTP/80; TLS/HTTPS is not configured in this migration.

The hostname resolves to `10.20.4.250` from the tested peered Linux VM, and HTTP returns the website. Therefore, requests made by hostname already reach Application Gateway. Requests sent directly to `10.20.0.6` still reach NGINX.

## Understand the two Ingresses

Both Ingress objects are expected during the parallel-test and rollback stages. They have the same hostname, path, and Service backend, but different Ingress classes and frontends:

| Ingress | Class | Address | Purpose |
|---|---|---:|---|
| `nginx-site-nginx-site` | `nginx-internal` | `10.20.0.6` | Existing NGINX route and rollback path |
| `nginx-site-nginx-site-appgw` | `azure-application-gateway` | `10.20.4.250` | AGIC route through the private Application Gateway |

`CLASS` says which controller handles a particular Ingress; it does not rank or disable the other Ingress. AGIC watches its Ingress and configures Application Gateway. AGIC is not itself a proxy in the live HTTP path.

There are two related paths:

```text
Configuration: Helm -> Kubernetes Ingress -> AGIC -> Application Gateway configuration

HTTP via the website hostname:
Client -> private DNS (10.20.4.250) -> Application Gateway -> website backend

HTTP directly to the NGINX address:
Client -> 10.20.0.6 -> nginx-internal controller -> website backend
```

### What “promote AGIC” means

DNS cutover and Helm/chart promotion are separate:

1. **DNS/traffic cutover:** The website hostname points at Application Gateway. This has already been tested successfully.
2. **Chart promotion:** Change the Helm chart's source-of-truth so AGIC is its primary Ingress and NGINX is explicitly the rollback route. This source change is prepared; its GitHub Actions deployment is pending.
3. **NGINX removal:** A separate later decision after the rollback window and dependency checks. This has **not** been done and is not required for AGIC traffic.

Promoting the chart while preserving both routes should leave `kubectl get ingress -n web` showing two Ingresses with the same names, classes, and addresses. Promotion is not “delete the NGINX Ingress,” and it does not require changing DNS again. Keep the NGINX controller until you intentionally end the rollback period.

## Migration steps completed

### 1. Keep the existing NGINX route as the baseline

The AKS application-routing add-on and the `nginx-internal` controller provide a private load balancer. The website's original Helm Ingress uses class `nginx-internal`. Its load balancer address is `10.20.0.6`.

The add-on's unused default NGINX controller is disabled with `default_nginx_controller = "None"` in [main.tf](./main.tf). This does not disable the application-routing add-on or the separate `nginx-internal` controller. Do not remove the add-on or controller while relying on NGINX for rollback.

Before changing infrastructure or DNS, record the current NGINX address and prove the old route works:

```bash
kubectl get ingress -n web -o wide
kubectl get service nginx-internal-0 -n app-routing-system -o wide
kubectl get endpoints nginx-site-nginx-site -n web
```

Use the current NGINX service IP (historically `10.20.0.6`) and the Ingress hostname:

```bash
curl -i --connect-timeout 5 \
  -H "Host: nginx.internal.example.com" \
  "http://<CURRENT_NGINX_PRIVATE_IP>/"
```

Keep the output/IP for rollback. If this baseline route does not work, resolve that first; otherwise a later test failure could be confused with a pre-existing NGINX issue.

### 2. Provision the private Application Gateway and enable AGIC

Terraform in [application_gateway.tf](./application_gateway.tf) creates a dedicated Application Gateway subnet delegated to `Microsoft.Network/applicationGateways` and a private Standard_v2 gateway. The current example uses:

- Gateway subnet: `10.20.4.0/24`
- Static private frontend: `10.20.4.250`
- Frontend protocol/port: HTTP/80

The values are configurable in [variables.tf](./variables.tf) and can be overridden in ignored `terraform.tfvars`:

```hcl
application_gateway_subnet_prefix = "10.20.4.0/24"
application_gateway_private_ip    = "10.20.4.250"
```

The subnet must be dedicated to Application Gateway and fit inside the VNet without overlapping the AKS subnet or other connected ranges. The AKS cluster in [main.tf](./main.tf) enables the AGIC add-on using:

```hcl
ingress_application_gateway {
  gateway_id = azurerm_application_gateway.aks.id
}
```

The private-only gateway also requires the subscription's `Microsoft.Network/EnableApplicationGatewayNetworkIsolation` feature to be registered. Check its state and register it before applying if it is not already enabled:

```powershell
az feature register --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network
az feature show --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network --query properties.state -o tsv
```

Wait until the feature state is `Registered`, then refresh the provider registration:

```powershell
az provider register --namespace Microsoft.Network
```

AGIC's add-on identity needs the following permissions, managed in Terraform:

- `Contributor` on the Application Gateway, to read and update gateway configuration.
- `Reader` on the resource group, to read required Azure resources.
- `Network Contributor` on the Application Gateway subnet, including subnet join permission.

Run Terraform from the directory containing the configuration. Before applying, format/validate and review the plan; confirm it does not unexpectedly replace the AKS cluster or existing gateway:

```bash
terraform fmt -check
terraform validate
terraform plan
```

Apply only after reviewing the plan:

```bash
terraform apply
```

The first apply can create the subnet and gateway and enable the AKS add-on. If the gateway fails after subnet creation, keep the successfully created subnet in Terraform state and fix the reported feature or permission issue before retrying. Role assignments can take several minutes to propagate.

The Application Gateway resource includes initial listener/rule/backend placeholders so Azure can create the gateway. AGIC later manages the listeners, backend pools/settings, probes, and routing configuration. The Terraform lifecycle ignores those AGIC-managed blocks and tags to prevent Terraform from overwriting AGIC's configuration. Review each plan for unrelated changes before applying.

Check infrastructure and controller readiness:

```bash
az aks show --resource-group "<resource-group>" --name "<cluster-name>" \
  --query addonProfiles.ingressApplicationGateway.enabled -o tsv
kubectl get pods -n kube-system | grep ingress-appgw
az network application-gateway show --resource-group "<resource-group>" \
  --name "<cluster-name>-appgw" --query operationalState -o tsv
terraform output -raw application_gateway_private_ip
```

Expected: add-on `true`, AGIC pod `Running`/Ready, gateway `Running`, and the frontend IP `10.20.4.250`. A running AGIC pod alone does not prove that the gateway route is configured; check the Ingress and gateway backend health too.

### 3. Add an AGIC Ingress alongside NGINX

Before promotion, the Helm chart used `ingress.className: nginx-internal` for the original Ingress. The optional AGIC template created a second Ingress when `ingress.applicationGateway.enabled` was true. The promoted chart now defines the AGIC Ingress as primary in [ingress.yaml](./charts/nginx-site/templates/ingress.yaml) and preserves NGINX in [ingress-nginx-rollback.yaml](./charts/nginx-site/templates/ingress-nginx-rollback.yaml).

Because this gateway has only a private frontend, the AGIC Ingress must include:

```yaml
appgw.ingress.kubernetes.io/use-private-ip: "true"
```

The AGIC Ingress is named `<Helm-release>-<chart-name>-appgw`; with release and chart name both `nginx-site`, its name is `nginx-site-nginx-site-appgw`. The NGINX Ingress keeps its existing name `nginx-site-nginx-site`. Both point to Service `nginx-site-nginx-site`, port 80. Keeping the two Ingresses separate allows each controller to process only its own class while both routes target the same pods.

The parallel-test workflow previously enabled AGIC with:

```bash
--set ingress.applicationGateway.enabled=true
```

The promoted workflow now enables the NGINX rollback route with:

```bash
--set ingress.nginxRollback.enabled=true
```

The workflow is manually started from **Actions → Build and deploy nginx site → Run workflow**. It builds/pushes the website image, gets AKS credentials, applies [deploy/nginx-internal-controller.yaml](./deploy/nginx-internal-controller.yaml), and runs Helm. Since the AKS API is private, its self-hosted runner needs private network and DNS access to that API.

The existing workflow uses GitHub OIDC with `azure/login@v2`; it does not require an Azure client secret. The runner must also reach GitHub and ACR and have Docker, Azure CLI, and Helm. The OIDC deployment identity needs `AcrPush` on the registry and `Azure Kubernetes Service Cluster Admin Role` on the AKS cluster because this workflow requests `az aks get-credentials --admin`. OIDC app/federated-credential creation, exact GitHub subject matching, role assignment, and the `AADSTS700213` troubleshooting procedure are documented in [README.md](./README.md#create-a-github-deployment-identity-with-oidc). Required workflow secrets are `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ACR_NAME`, `ACR_LOGIN_SERVER`, `AKS_RESOURCE_GROUP`, `AKS_CLUSTER_NAME`, and `NGINX_HOST`.

Inspect both routes:

```bash
kubectl get ingress -n web -o wide
```

The AGIC Ingress `ADDRESS` can be blank while AGIC is reconciling. Use the private IP from `terraform output -raw application_gateway_private_ip` for the direct HTTP test, and check Ingress events and AGIC logs if reconciliation does not complete.

### 4. Test AGIC directly before relying on DNS

Use the gateway private IP and a matching `Host` header. This tests the Application Gateway route without DNS:

```bash
APPGW_IP="$(terraform output -raw application_gateway_private_ip)"
NGINX_HOST="nginx.internal.example.com"
curl -i --connect-timeout 5 -H "Host: $NGINX_HOST" "http://$APPGW_IP/"
```

The successful test returned HTTP 200 and the website HTML from `10.20.4.250`. If it fails, check:

```bash
kubectl describe ingress nginx-site-nginx-site-appgw -n web
kubectl logs -n kube-system deployment/ingress-appgw-deployment --tail=100
az network application-gateway show-backend-health \
  --resource-group "<resource-group>" \
  --name "<cluster-name>-appgw" \
  --output table
```

Do not remove the working NGINX route while diagnosing AGIC.

### 5. Create website Private DNS separately from the AKS API DNS

The website uses its own Private DNS zone in [dns.tf](./dns.tf), currently `internal.example.com`, with record `nginx`. The website FQDN is `nginx.internal.example.com`. Its A record targets the Application Gateway IP by default because `website_dns_target_ip` is null.

This is separate from the AKS private API zone. Keep `private_dns_zone_id = "System"` in [main.tf](./main.tf); it lets AKS manage its API endpoint DNS. Do not use the AKS API zone as the website zone.

Terraform links the website zone to the AKS VNet. If clients are in another/peered VNet, set `website_client_vnet_id` in ignored `terraform.tfvars` to that client VNet's resource ID. Private DNS VNet links are per-VNet; VNet peering does not make the zone resolvable in the peer. The DNS link must show `Completed`. If the client VNet uses custom DNS, configure forwarding for the website private zone.

The AzureRM schema used here expects zone names and resource group names for the link and record resources:

- `azurerm_private_dns_zone_virtual_network_link`: `private_dns_zone_name` and `resource_group_name`
- `azurerm_private_dns_a_record`: `zone_name` and `resource_group_name`

Review the plan, verify it targets `10.20.4.250`, and apply:

```bash
terraform plan
terraform apply
```

Inspect the created DNS record and VNet links in Azure if needed:

```bash
RG="$(terraform output -raw resource_group_name)"
az network private-dns record-set a show \
  --resource-group "$RG" \
  --zone-name internal.example.com \
  --name nginx \
  --output table
az network private-dns link vnet list \
  --resource-group "$RG" \
  --zone-name internal.example.com \
  --output table
```

Verify from a connected Linux client:

```bash
nslookup nginx.internal.example.com 168.63.129.16
getent hosts nginx.internal.example.com
curl --fail --show-error http://nginx.internal.example.com/
```

The reported test resolved the hostname to `10.20.4.250` with both Azure DNS and the VM's system resolver, and `curl` returned the website.

The same values are configurable in [variables.tf](./variables.tf). The current defaults are `website_dns_zone_name = "internal.example.com"`, `website_dns_record_name = "nginx"`, `website_dns_target_ip = null` (use the gateway IP), and `website_client_vnet_id = ""` (no additional client VNet link). For the peered client, the actual client VNet resource ID was set in ignored `terraform.tfvars` through `website_client_vnet_id`.

## Rollback while retaining NGINX

The NGINX controller and Ingress remain available. If Application Gateway has a problem and you need the hostname to use NGINX again, first verify the current `nginx-internal-0` Service IP:

```bash
kubectl get service nginx-internal-0 -n app-routing-system -o wide
```

Then set the website DNS target to that IP (currently `10.20.0.6`) and review/apply the Terraform change:

```bash
terraform plan -var='website_dns_target_ip=10.20.0.6'
terraform apply -var='website_dns_target_ip=10.20.0.6'
```

To return the website DNS record to Application Gateway, apply with `website_dns_target_ip = null` (the default) and verify the plan before applying. Use the actual current NGINX service IP if it differs from `10.20.0.6`. The Terraform A record TTL is 300 seconds, but client/recursive resolver caches can affect when the changed answer is observed. Verify DNS and HTTP after the change; keep both ingress routes running during rollback.

## Promote AGIC and keep NGINX for rollback

The DNS cutover is already complete and the current source changes are ready to deploy. The latest cluster output shared was the original NGINX Ingress plus the parallel AGIC Ingress. The next deployment changes the chart's defaults/ownership intent while keeping both routes.

### Changes made for promotion

- `values.yaml` now defaults `ingress.className` to `azure-application-gateway`.
- The existing AGIC object name remains `nginx-site-nginx-site-appgw`; the primary template includes `appgw.ingress.kubernetes.io/use-private-ip: "true"`.
- The old NGINX object name remains `nginx-site-nginx-site`; the new rollback template renders it with class `nginx-internal`.
- `ingress.nginxRollback.enabled` defaults to `true`, and the workflow explicitly passes `--set ingress.nginxRollback.enabled=true`.
- The workflow still applies `deploy/nginx-internal-controller.yaml`, so the NGINX controller remains in place.
- The old optional AGIC template was replaced by the primary AGIC template; resource names, host, path, and Service backend are preserved so Helm should update the same two Ingresses, not delete and recreate them.
- No Terraform/DNS changes are required for this promotion. The hostname already points to Application Gateway.

### Deploy the promotion

The changes are not live merely because files were edited. To promote:

```bash
git status --short
git diff --check
```

Review the changes, commit/push the chart and workflow to the intended branch, then manually run **Actions → Build and deploy nginx site → Run workflow** and select that branch. The workflow is `workflow_dispatch`; a push alone does not deploy. The self-hosted runner needs private DNS/network reachability to the AKS API, as before.

The workflow builds/pushes a fresh application image, applies the NGINX controller resource, and upgrades the Helm release. The image update is independent of ingress promotion but occurs in the same workflow.

### Verify after the workflow succeeds

From a host that can access the private AKS API and application networks, inspect Helm values and both live routes:

```bash
helm get values nginx-site --namespace web
helm get manifest nginx-site --namespace web
kubectl get deployment,service,ingress -n web -o wide
kubectl get nginxingresscontroller nginx-internal
kubectl get service nginx-internal-0 -n app-routing-system -o wide
```

Expected:

- The Helm user-supplied values show `ingress.nginxRollback.enabled: true`; the chart default primary class is `azure-application-gateway`.
- `nginx-site-nginx-site-appgw` is class `azure-application-gateway` and points to the gateway private frontend.
- `nginx-site-nginx-site` is class `nginx-internal`.
- The NGINX controller and its internal Service remain Ready with a private IP.

`kubectl get ingress` should still show two entries. That is expected and is not evidence that promotion failed. Promotion changes which controller the chart treats as primary and preserves the alternate route; it does not make the other Ingress disappear.

Test the direct routes and DNS hostname:

```bash
# Direct AGIC test; use a Host header matching the Ingress.
curl --fail --show-error --connect-timeout 5 \
  -H "Host: nginx.internal.example.com" \
  http://10.20.4.250/

# Direct NGINX rollback test; use the current nginx-internal-0 IP.
curl --fail --show-error --connect-timeout 5 \
  -H "Host: nginx.internal.example.com" \
  http://10.20.0.6/

# Normal client request should use the Application Gateway DNS target.
getent hosts nginx.internal.example.com
curl --fail --show-error http://nginx.internal.example.com/
```

Replace the example IPs with current values from Terraform/Kubernetes. The DNS response should be the Application Gateway IP; the direct NGINX test intentionally bypasses DNS. Repeat hostname/DNS and connectivity checks from each required client network.

If AGIC does not reconcile, inspect:

```bash
kubectl describe ingress nginx-site-nginx-site-appgw --namespace web
kubectl logs -n kube-system deployment/ingress-appgw-deployment --tail=100
az network application-gateway show-backend-health \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw cluster_name)-appgw" \
  --output table
```

Do not delete the NGINX controller/Ingress during the rollback period. If the gateway route is unhealthy and you need normal hostname traffic to use NGINX, change `website_dns_target_ip` to the current NGINX Service IP through Terraform, review the plan, apply, and retest DNS and HTTP. When ready to return to AGIC, set the override back to null and apply after reviewing the plan.

Final NGINX cleanup is not part of promotion. Only do it after the rollback window and after confirming no other workloads use `nginx-internal`.

## Errors and resolutions encountered

### Private-only Application Gateway rejected for `Standard_v2`

**Error:** `ApplicationGatewayFeatureCannotBeEnabledForSelectedSku` said the selected `Standard_v2` tier did not support an Application Gateway without a public IP.

**Cause and resolution:** Register the subscription feature `EnableApplicationGatewayNetworkIsolation` for `Microsoft.Network`, wait until it reports `Registered`, and re-register the provider. Then review and rerun Terraform:

```powershell
az feature register --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network
az feature show --name EnableApplicationGatewayNetworkIsolation --namespace Microsoft.Network --query properties.state -o tsv
az provider register --namespace Microsoft.Network
```

The subnet had already been created successfully when the gateway failed. Keep it in Terraform state and retry after feature registration completes.

### AGIC cannot read or update Application Gateway (403)

**Error:** AGIC logs/events included `ErrorApplicationGatewayForbidden`, `AuthorizationFailed`, or a 403 for `Microsoft.Network/applicationGateways/read`; the message identified missing `Reader` on the resource group and/or `Contributor` on the gateway.

**Fix:** Assign the AGIC add-on identity `Reader` on the resource group and `Contributor` on the Application Gateway. These assignments are in [application_gateway.tf](./application_gateway.tf). Allow time for role propagation, then inspect the AGIC pod and logs.

### AGIC cannot join the Application Gateway subnet

**Error:** `ApplicationGatewayInsufficientPermissionOnSubnet` reported missing `Microsoft.Network/virtualNetworks/subnets/join/action`.

**Fix:** Assign the AGIC identity `Network Contributor` scoped to the dedicated Application Gateway subnet. This assignment is in [application_gateway.tf](./application_gateway.tf). Reapply after reviewing the plan and allow time for role propagation; AGIC should retry.

### The AGIC pod appeared to be “not running,” but was healthy

In the reported `kubectl describe pod` output, the pod was `Running`, `Ready: True`, and `1/1`. The relevant failure was a `FailedApplyingAppGwConfig` event, not a pod startup failure. Check the pod's Events and AGIC logs to identify why it cannot reconcile the Azure gateway. In this case, the event identified the missing subnet join permission above.

### `kubectl describe ingress` returns `NotFound`

`kubectl describe ingress <name>` without a namespace searches the current/default namespace. The website Ingress is in namespace `web`; use:

```bash
kubectl describe ingress nginx-site-nginx-site-appgw --namespace web
```

### AGIC reports `NoPublicIP` and requests return `502 Bad Gateway`

**Cause:** The gateway intentionally has no public frontend, and AGIC had not been told to use its private frontend.

**Fix:** Add `appgw.ingress.kubernetes.io/use-private-ip: "true"` to the AGIC Ingress. The current optional AGIC template includes it. The live Ingress was annotated and reconciled; its `ADDRESS` became `10.20.4.250` and a request with the matching Host header returned HTTP 200. If needed, annotate it immediately:

```bash
kubectl annotate ingress nginx-site-nginx-site-appgw \
  --namespace web \
  appgw.ingress.kubernetes.io/use-private-ip="true" \
  --overwrite
```

Then verify the event is gone and retest. If 502 continues, inspect Application Gateway backend health and AGIC logs.

### Terraform DNS validation rejects `private_dns_zone_id`

**Error:** `terraform validate` said `private_dns_zone_name`, `resource_group_name`, and/or `zone_name` were missing, and `private_dns_zone_id` was unsupported.

**Cause and fix:** The selected AzureRM provider schema requires the zone name and resource group arguments for these resources. [dns.tf](./dns.tf) uses `private_dns_zone_name` plus `resource_group_name` for the VNet link, and `zone_name` plus `resource_group_name` for the A record. Match the schema of the provider pinned in `versions.tf`.

### DNS resolves in Azure DNS but not in a peered VM

**Symptom:** A direct query to `168.63.129.16` returned `10.20.4.250`, but `getent`/`curl` from the peered VM initially could not resolve the hostname.

**Cause:** A Private DNS zone link to the AKS VNet does not automatically cover a peered VNet.

**Fix:** Set `website_client_vnet_id` to the client VM's VNet resource ID and apply. Verify the extra VNet link is `Completed`. If `nslookup` succeeds but `getent` still fails, inspect the VNet's custom DNS settings and configure conditional forwarding.

### Terraform plan wants to remove AGIC gateway tags

AGIC adds tags such as `ingress-for-aks-cluster-id` and `managed-by-k8s-ingress`. Terraform may then propose removing them because AGIC changed the gateway outside Terraform. The gateway resource ignores `tags` and AGIC-managed configuration blocks in its lifecycle settings. Keep those ignores so Terraform does not fight the AGIC controller; review plans for unrelated changes before applying.

### Terraform output is blank or joined to the next shell command

The user initially saw a blank result from `terraform output -raw application_gateway_private_ip` and later saw the FQDN output run directly into the next shell command. First confirm the command is running in the Terraform root directory and against the expected workspace/state, then inspect declared outputs with `terraform output`. A missing value can mean the current state does not contain that output yet; do not infer that the Azure resource is absent without checking Azure and Terraform state.

Also, `terraform output -raw` prints without a trailing newline. Run it by itself, press Enter, or add `echo` before the next command. This formatting issue does not indicate a bad DNS record. Confirm the record with `nslookup`/`getent`.

## Verification checklist

- [ ] Record existing NGINX Service private IP and verify the NGINX route before changes.
- [ ] Check/register `EnableApplicationGatewayNetworkIsolation`; wait for `Registered` and re-register `Microsoft.Network`.
- [ ] Confirm the dedicated gateway subnet fits the VNet, is not overlapping, and is used only by Application Gateway.
- [ ] Review `terraform fmt -check`, `terraform validate`, and `terraform plan`; do not apply an unexpected AKS replacement.
- [ ] Apply Terraform and verify AGIC's gateway, resource-group, and subnet role assignments.
- [ ] AGIC add-on enabled and controller pod healthy.
- [ ] Application Gateway operational at its current private IP.
- [ ] Private-IP annotation is present on the AGIC Ingress.
- [ ] Both Ingresses exist with their intended classes.
- [ ] Direct request to the gateway IP with the correct Host header returns the website.
- [ ] Website DNS A record points to Application Gateway and all required VNet links show `Completed`.
- [ ] `getent hosts nginx.internal.example.com` resolves to the current intended DNS target.
- [ ] `curl --fail --show-error http://nginx.internal.example.com/` returns the website from every required client network.
- [ ] NGINX controller and Ingress remain available for rollback.
- [ ] No chart promotion or NGINX cleanup is considered complete until explicitly reviewed and deployed.
