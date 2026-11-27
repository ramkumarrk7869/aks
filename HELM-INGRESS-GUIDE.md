# Beginner's Guide to Helm and Ingress

This guide explains how this repository deploys its NGINX website to AKS using Docker, Azure Container Registry (ACR), Helm, and two private ingress routes. The chart defines AGIC/Application Gateway as the primary route and retains the AKS-managed `nginx-internal` route for rollback. The latest Helm values and manifest shared on 2026-11-27 confirm that this promoted configuration is installed in the release; check the live Ingresses and controllers to verify reconciliation.

The website hostname was verified through Application Gateway at `10.20.4.250`. The NGINX rollback route was previously tested at `10.20.0.6`. These are last-reported values; check the current addresses before testing.

## 1. The big picture

These are separate pieces that work together:

- **Docker image:** A package containing NGINX and the website's HTML.
- **ACR:** Azure's private container image registry. The workflow stores the image here.
- **Kubernetes Deployment:** Keeps the requested number of website pods running.
- **Kubernetes Service:** Provides a stable in-cluster address for those pods.
- **Ingress:** A set of HTTP routing rules. It says which host and path should go to which Service.
- **Ingress controllers:** AGIC watches its Ingress and configures Application Gateway; NGINX remains as a separate rollback controller.
- **Helm chart:** A reusable collection of Kubernetes templates and default settings. Helm fills in the templates and installs or updates the Kubernetes resources.
- **Private Application Gateway:** Provides the primary frontend IP. The retained NGINX controller has its own internal Azure Load Balancer IP.

The request path looks like this:

```text
Configuration path:
Helm Ingress -> AGIC -> Application Gateway listener/backend

Primary HTTP path:
Browser/curl -> private DNS -> Application Gateway -> website backend -> NGINX pod

Rollback HTTP path:
Browser/curl -> NGINX internal load balancer -> nginx-internal controller
             -> website backend -> NGINX pod
```

An Ingress is only a rule; it does not run a web server. AGIC watches its Ingress and configures the gateway; AGIC is not itself a proxy in the request path. The Service and Deployment are created by the Helm chart.

## 2. Files involved

| File | Purpose |
|---|---|
| `site/index.html` | The web page shown by NGINX. |
| `Dockerfile` | Packages the page into an NGINX container image. |
| `.github/workflows/deploy.yml` | Builds and pushes the image, then installs the controller configuration and Helm chart. |
| `deploy/nginx-internal-controller.yaml` | Asks AKS application routing to create a dedicated internal NGINX controller. |
| `charts/nginx-site/Chart.yaml` | Identifies the Helm chart. |
| `charts/nginx-site/values.yaml` | Provides default settings for the chart. |
| `charts/nginx-site/templates/_helpers.tpl` | Defines shared names and labels used by the templates. |
| `charts/nginx-site/templates/deployment.yaml` | Defines the website pods. |
| `charts/nginx-site/templates/service.yaml` | Defines the stable in-cluster Service for those pods. |
| `charts/nginx-site/templates/ingress.yaml` | Defines the primary AGIC host/path rule and private frontend annotation. |
| `charts/nginx-site/templates/ingress-nginx-rollback.yaml` | Keeps the optional `nginx-internal` rollback route. |
| `main.tf` | Enables AKS application routing and configures the AKS node pools. |

## 3. The web page and container image

### `site/index.html`

This is the page served by NGINX:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>AKS NGINX Demo</title>
  </head>
  <body>
    <h1>Hello from NGINX on private AKS</h1>
    <p>This site is deployed with Docker, Azure Container Registry, Helm, and GitHub Actions.</p>
  </body>
</html>
```

### `Dockerfile`

```dockerfile
FROM nginx:alpine

COPY site/index.html /usr/share/nginx/html/index.html
```

- `FROM nginx:alpine` starts with the official NGINX image, using its small Alpine Linux base.
- `COPY` puts this project's page in NGINX's standard location for the default website.
- The workflow builds this Dockerfile and adds a unique tag based on the Git commit. It then pushes that image to ACR so AKS can download it.

## 4. Helm chart basics

A Helm chart is a directory of Kubernetes YAML templates. Values such as image name and website host are supplied separately, so the same chart can be reused with different settings.

### `charts/nginx-site/Chart.yaml`

```yaml
apiVersion: v2
name: nginx-site
description: A small NGINX website for deployment to private AKS
type: application
version: 0.1.0
appVersion: "1.0.0"
```

- `apiVersion: v2` identifies this as a Helm 3 chart.
- `name` is the chart's name.
- `type: application` means this chart installs an application.
- `version` is the chart package version.
- `appVersion` describes the application version; the workflow's image tag is separately set to the current Git commit.

### `charts/nginx-site/values.yaml`

These are the defaults Helm uses unless a value is overridden:

```yaml
replicaCount: 2

image:
  repository: nginx
  tag: alpine
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

ingress:
  className: azure-application-gateway
  host: nginx.internal.example.com
  path: /
  pathType: Prefix
  nginxRollback:
    enabled: true
    className: nginx-internal
```

- `replicaCount: 2` asks Kubernetes to run two website pods.
- `image.repository` and `image.tag` identify a container image. The workflow replaces these defaults with the image it just pushed to ACR.
- `pullPolicy` tells Kubernetes when to fetch the image. `IfNotPresent` reuses a copy already cached on the node.
- `service.type: ClusterIP` means the website Service is reachable inside Kubernetes, not directly from the public internet.
- The Service listens on port `80`.
- `ingress.className` selects AGIC for the primary route.
- `host` and `path` describe which web requests should match the Ingress. The workflow supplies the configured `NGINX_HOST` value for the host.
- `pathType: Prefix` means `/` and paths below it match this rule.
- `ingress.nginxRollback.enabled` creates the second Ingress using `nginx-internal`; the workflow enables it so NGINX remains available for rollback.
- The default for `ingress.nginxRollback.enabled` is `true` in the promoted chart so a deployment does not accidentally drop the rollback route.

The default image and hostname are fallback values. During the actual Actions deployment, the workflow provides the ACR image and configured host explicitly.

### How `values.yaml` connects to the templates

The `values.yaml` file is the chart's default settings file. In a template, `.Values` means “the final set of chart settings Helm is using.” The part after `.Values` selects a setting. For example:

```gotemplate
replicas: {{ .Values.replicaCount }}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

These read `replicaCount`, `image.repository`, and `image.tag` from the YAML values tree. In the workflow, `--set-string image.repository=...` and `--set-string image.tag=...` replace those two defaults for that deployment. `--set-string ingress.host=...` similarly replaces `.Values.ingress.host`. Values not overridden, such as `replicaCount`, `service.port`, and `ingress.className`, keep their defaults from `values.yaml`.

The usual precedence is: chart defaults in `values.yaml`, then any values files supplied to Helm, then command-line `--set`/`--set-string` values. Later overrides take precedence. `--set-string` tells Helm to treat a supplied value as text, which is useful for image tags and hostnames.

### `charts/nginx-site/templates/_helpers.tpl`

```gotemplate
{{- define "nginx-site.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nginx-site.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "nginx-site.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "nginx-site.labels" -}}
app.kubernetes.io/name: {{ include "nginx-site.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
```

These are small reusable Helm templates:

- `nginx-site.name` returns the chart name.
- `nginx-site.fullname` combines the Helm release name and chart name. With the release name `nginx-site`, the resulting Kubernetes resource name is `nginx-site-nginx-site`.
- `nginx-site.labels` creates a block of identifying labels for Kubernetes resources.
- `trunc 63` keeps generated names within Kubernetes naming limits; `trimSuffix "-"` removes a trailing dash if truncation leaves one.

The `{{ ... }}` sections are Helm template expressions. Helm replaces them with actual names and values when it renders the chart. `define` gives a helper a name; `include` runs that named helper and inserts its result. The `.` passes the current chart context, which lets the helper read information such as `.Chart.Name` or `.Release.Name`. The dashes in `{{-` and `-}}` trim extra whitespace from the generated YAML. `nindent 4` adds a newline and indents the included labels so they fit under `metadata.labels`.

The templates use the helpers in several places: Deployment, Service, and Ingress names use `include "nginx-site.fullname" .`, while their resource metadata uses `include "nginx-site.labels" .`. The pod template has its own `name` and `instance` labels, because the Deployment selector and Service selector need to match those pod labels. The shared `nginx-site.labels` helper is not used for pod labels in this chart.

### `charts/nginx-site/templates/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "nginx-site.fullname" . }}
  labels:
    {{- include "nginx-site.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "nginx-site.name" . }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ include "nginx-site.name" . }}
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: nginx
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /
              port: http
          livenessProbe:
            httpGet:
              path: /
              port: http
```

- A `Deployment` tells Kubernetes how to run and maintain the website pods.
- `replicas` is set from `values.yaml`; Kubernetes tries to keep two pods running.
- The selector and pod labels must match. The Deployment uses them to find and manage its pods.
- The `image` combines the repository and tag. In Actions, this becomes the tagged image in ACR.
- `containerPort: 80` documents the HTTP port inside the container.
- The readiness probe asks whether the page can respond before Kubernetes sends traffic to that pod.
- The liveness probe checks whether the container is still responding; Kubernetes can restart it if the check repeatedly fails.

### `charts/nginx-site/templates/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "nginx-site.fullname" . }}
  labels:
    {{- include "nginx-site.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: {{ include "nginx-site.name" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
```

- The Service gives the website pods a stable Kubernetes address even if individual pods are replaced.
- `ClusterIP` makes that address internal to the cluster.
- `port` is the Service port; `targetPort: http` forwards to the container port named `http` in the Deployment.
- The selector must match the website pod labels. This is how Kubernetes knows which pods should receive requests.
- The Ingress sends matching website requests to this Service.

### `charts/nginx-site/templates/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ printf "%s-appgw" (include "nginx-site.fullname" .) | trunc 63 | trimSuffix "-" }}
  annotations:
    appgw.ingress.kubernetes.io/use-private-ip: "true"
  labels:
    {{- include "nginx-site.labels" . | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className | quote }}
  rules:
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: {{ .Values.ingress.pathType }}
            backend:
              service:
                name: {{ include "nginx-site.fullname" . }}
                port:
                  number: {{ .Values.service.port }}
```

- `ingressClassName` tells the cluster which controller handles this rule: `azure-application-gateway`.
- The `-appgw` name preserves the existing AGIC Ingress object during chart promotion.
- The private-IP annotation tells AGIC to use this gateway's private frontend.
- `host` matches the HTTP host name, for example `nginx.internal.example.com`.
- `path` matches the requested URL path.
- `backend.service` points to the website Service and its port.
- The Ingress does not create DNS or allocate the gateway/load balancer. Those are separate Azure resources.
- `quote` makes the rendered host a quoted YAML string, which helps avoid YAML parsing ambiguity.

### `charts/nginx-site/templates/ingress-nginx-rollback.yaml`

This optional template sends the same host/path to the same Service but selects `ingressClassName: nginx-internal`. It preserves the original Ingress name (`nginx-site-nginx-site`) so the existing NGINX route can remain available as rollback without replacing the object.

## 5. The internal ingress controller

### `deploy/nginx-internal-controller.yaml`

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

This is an AKS application-routing custom resource, not part of the Helm website chart:

- `apiVersion` selects the AKS application-routing API.
- `kind: NginxIngressController` asks the AKS add-on to provision a managed controller.
- `metadata.name` identifies this controller configuration.
- `ingressClassName` must match the Helm Ingress's class name, so the controller handles the website's Ingress.
- `controllerNamePrefix` gives the controller's Kubernetes resources a recognizable name prefix.
- `scaling.minReplicas: 1` allows the managed controller to scale down to one pod when demand is low. AKS application routing manages the controller pods; this setting changes the number of pods, not each pod's CPU or memory requests and limits.
- The Azure load-balancer annotation requests an **internal** load balancer with a private IP. It is not a public website endpoint.

The AKS-managed `NginxIngressController` configuration does not provide fields for per-pod CPU or memory requests/limits. Do not edit the generated controller Deployment to tune them: the add-on owns those resources and can reconcile manual edits away. The supported resource setting here is the replica scaling policy. Reducing the minimum from its default of two to one reduces the controller's baseline reserved capacity by roughly one pod, but leaves only one controller pod at low demand. That reduces redundancy during a pod or node failure and during maintenance. The controller can still scale above one when demand increases.

To see actual use, requests, and limits separately:

```bash
# Current usage (requires the Metrics API).
kubectl top pods --namespace app-routing-system

# The resource requests and limits configured on each pod.
kubectl describe pods --namespace app-routing-system
```

In the screenshots for this deployment, each internal controller pod used about `1m` CPU and `46Mi` memory, while the displayed CPU and memory requests were `500m` and `127Mi`. `kubectl top` reports current use; it does not report configured requests or limits. Check `kubectl describe pods` for the actual limits, if any.

The AKS application-routing add-on must be enabled for this custom resource to work. Terraform declares it in the AKS resource in `main.tf`:

```hcl
web_app_routing {
  dns_zone_ids             = []
  default_nginx_controller = "AnnotationControlled"
}
```

- `web_app_routing` enables/configures the AKS application-routing add-on.
- `dns_zone_ids = []` means no Azure DNS zone is attached by this setting; private DNS can be configured separately.
- `AnnotationControlled` leaves selection of the NGINX ingress class to the Ingress resource. Here the chart's rollback Ingress selects `nginx-internal`; the primary Ingress selects AGIC.

### When is `app-routing-system` created?

The `app-routing-system` namespace is part of the AKS application-routing add-on. Azure creates and manages it when the add-on is enabled on the cluster; the add-on runs its controller components and supporting Services there. When the workflow applies `deploy/nginx-internal-controller.yaml`, the add-on observes that custom resource and creates the requested internal controller and its resources in the managed namespace.

This is different from the website namespace, `web`. The workflow's Helm command uses `--namespace web --create-namespace`, so Helm creates `web` if it is missing, then installs the website Deployment, Service, primary AGIC Ingress, and NGINX rollback Ingress there. It does not create `app-routing-system`; that namespace belongs to the AKS add-on. Do not create or manage the add-on's namespace yourself.

The workflow applies the controller resource before installing the chart. This ordering ensures the cluster has the internal controller configuration before the website Ingress is installed. The namespace may already exist from enabling the add-on; applying the custom resource requests the specific internal controller.

After changing `deploy/nginx-internal-controller.yaml`, apply the change from a machine that has access to the private AKS API:

```bash
kubectl apply -f deploy/nginx-internal-controller.yaml
kubectl get nginxingresscontroller nginx-internal -o yaml
kubectl get pods --namespace app-routing-system -o wide
```

The GitHub Actions workflow also applies this manifest on every deployment. To apply a change through Actions, start the workflow manually after the change is pushed; pushes by themselves do not deploy. The controller may take time to scale down. Verify the resulting pod count and make sure the remaining pod is `Running` and ready. To restore the previous two-pod minimum, change `minReplicas` back to `2` and apply the manifest again.

## 6. How GitHub Actions deploys the site

The workflow file is `.github/workflows/deploy.yml`. It is started manually from **Actions → Build and deploy nginx site → Run workflow**. Pushes to branches are ignored, so editing or pushing code does not automatically deploy it.

The runner is configured as:

```yaml
jobs:
  build-and-deploy:
    runs-on: [self-hosted, linux, aks-private]
```

Because the AKS API server is private, this must be a self-hosted Linux runner that can connect to the AKS private network. The runner also needs Docker and Azure CLI.

The workflow's deployment settings include:

```yaml
env:
  ACR_NAME: ${{ secrets.ACR_NAME }}
  ACR_LOGIN_SERVER: ${{ secrets.ACR_LOGIN_SERVER }}
  AKS_RESOURCE_GROUP: ${{ secrets.AKS_RESOURCE_GROUP }}
  AKS_CLUSTER_NAME: ${{ secrets.AKS_CLUSTER_NAME }}
  NGINX_HOST: ${{ secrets.NGINX_HOST }}
  IMAGE_NAME: nginx-site
  IMAGE_TAG: ${{ github.sha }}
```

- Values under `secrets` are set in GitHub repository **Settings → Secrets and variables → Actions**.
- `IMAGE_NAME` is the image's repository name in ACR.
- `github.sha` is the identifier for the commit being deployed; it gives each build a unique image tag.
- `NGINX_HOST` needs to be the same host used by the Ingress and private DNS record.

The workflow's important steps are:

```yaml
- name: Check out source
  uses: actions/checkout@v4

- name: Sign in to Azure with OIDC
  uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

The checkout step makes the repository files available to the runner. Azure sign-in uses GitHub's OIDC identity rather than a stored Azure client secret.

```yaml
- name: Validate deployment configuration
  run: |
    for name in ACR_NAME ACR_LOGIN_SERVER AKS_RESOURCE_GROUP AKS_CLUSTER_NAME NGINX_HOST; do
      if [ -z "${!name}" ]; then
        echo "::error::Set the GitHub Actions secret $name."
        exit 1
      fi
    done
```

This stops the workflow early with a clear error if a required repository secret is empty.

```yaml
- name: Set up Helm
  uses: azure/setup-helm@v4
  with:
    version: v3.17.3

- name: Sign in to ACR
  run: az acr login --name "$ACR_NAME"

- name: Build and push image
  run: |
    docker build --tag "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG" .
    docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
```

Helm is installed on the runner. The runner signs in to ACR, builds the Dockerfile, tags the image as `registry/image:commit`, and pushes it to ACR.

```yaml
- name: Connect to private AKS
  run: az aks get-credentials --resource-group "$AKS_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --admin --overwrite-existing

- name: Create internal ingress controller
  run: kubectl apply -f deploy/nginx-internal-controller.yaml
```

`az aks get-credentials` configures `kubectl` to use the cluster. `kubectl apply` creates or updates the internal-controller custom resource. The runner needs network access to the private AKS API for these commands.

The chart install/update step is:

```yaml
- name: Deploy website with Helm
  run: |
    helm upgrade --install nginx-site ./charts/nginx-site \
      --namespace web \
      --create-namespace \
      --set-string image.repository="$ACR_LOGIN_SERVER/$IMAGE_NAME" \
      --set-string image.tag="$IMAGE_TAG" \
      --set-string ingress.host="$NGINX_HOST" \
      --set ingress.nginxRollback.enabled=true \
      --wait \
      --timeout 5m
```

- `helm upgrade --install` updates an existing Helm release or installs it if it does not exist.
- `nginx-site` is the Helm **release name**. It is not the chart directory name.
- `./charts/nginx-site` is the chart path.
- `--namespace web` puts the website resources in the `web` namespace.
- `--create-namespace` creates that namespace if it does not exist.
- Each `--set-string` overrides a chart value for this deployment. The image comes from ACR and uses the commit tag. The Ingress host comes from the `NGINX_HOST` secret.
- `--set ingress.nginxRollback.enabled=true` explicitly retains the NGINX Ingress. The chart's primary Ingress is AGIC.
- `--wait --timeout 5m` asks Helm to wait for resources to become ready, for up to five minutes, before reporting success or failure.

Finally, the workflow prints useful resource details:

```yaml
- name: Show deployment and both ingress routes
  run: |
    kubectl get deployment,service,ingress -n web
    kubectl get nginxingresscontroller nginx-internal
    kubectl get service -n app-routing-system
```

This shows the website's Deployment, Service, and both Ingresses; the NGINX controller configuration; and its Service where the rollback load-balancer IP appears.

In the final command, `-n app-routing-system` is shorthand for `--namespace app-routing-system`. It tells `kubectl` to list Services in the namespace managed by the AKS application-routing add-on. The website resources are listed separately from namespace `web`.

## 7. Deploy or update manually

Normally GitHub Actions performs these steps. If you have `kubectl`, Helm, Azure CLI, permissions, and network access to the private cluster, the essential commands are:

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
  --set ingress.nginxRollback.enabled=true \
  --wait \
  --timeout 5m
```

Replace the values in angle brackets with the real cluster, registry, and image details. The image must already exist in ACR and be pullable by AKS. The standard GitHub workflow builds and pushes that image before running Helm.

To preview the Kubernetes YAML Helm would generate without installing it:

```bash
helm template nginx-site ./charts/nginx-site \
  --namespace web \
  --set-string image.repository="<ACR-login-server>/nginx-site" \
  --set-string image.tag="<image-tag>" \
  --set-string ingress.host="nginx.internal.example.com" \
  --set ingress.nginxRollback.enabled=true
```

## 8. Check that the deployment is ready

Run:

```bash
kubectl get nodes
kubectl get pods --namespace web -o wide
kubectl get pods --namespace app-routing-system -o wide
kubectl get deployment,service,ingress --namespace web
kubectl get nginxingresscontroller nginx-internal
kubectl get service --namespace app-routing-system
```

Look for:

- Website pods showing `Running` and `1/1` ready.
- The AGIC Ingress `nginx-site-nginx-site-appgw` showing class `azure-application-gateway` and the Application Gateway private IP.
- The rollback Ingress `nginx-site-nginx-site` showing class `nginx-internal`.
- AGIC pod in `kube-system` showing `Running` and ready.
- NGINX controller pods in `app-routing-system` showing `Running` and ready.
- The `nginx-internal-0` Service showing a private IP under `EXTERNAL-IP`, not `<pending>`.

The term `EXTERNAL-IP` in Kubernetes output means the address assigned to the NGINX controller's load balancer; in this case it is still a private, internal address. The AGIC Ingress `ADDRESS` shows the Application Gateway frontend.

## 9. Test the website

### Test the primary Application Gateway route by IP (DNS not required)

Run this from a client that can reach the private Application Gateway IP:

```bash
APPGW_IP="$(terraform output -raw application_gateway_private_ip)"
NGINX_HOST="nginx.internal.example.com"

curl --fail --show-error --connect-timeout 5 \
  -H "Host: $NGINX_HOST" \
  "http://$APPGW_IP/"
```

The `Host` header must match the AGIC Ingress hostname. This test bypasses DNS but still tests the client network path, Application Gateway listener, AGIC-configured routing, website backend, and pods. If it fails, inspect the AGIC Ingress events, AGIC logs, and Application Gateway backend health before changing DNS:

```bash
kubectl describe ingress nginx-site-nginx-site-appgw --namespace web
kubectl logs -n kube-system deployment/ingress-appgw-deployment --tail=100
az network application-gateway show-backend-health \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw cluster_name)-appgw" \
  --output table
```

### Test the NGINX rollback route by IP

Find the current NGINX controller address:

```bash
kubectl get service nginx-internal-0 --namespace app-routing-system -o wide
```

Then test it directly:

```bash
NGINX_IP="<private-ip-from-nginx-internal-0>"
NGINX_HOST="nginx.internal.example.com"
curl --fail --show-error --connect-timeout 5 \
  -H "Host: $NGINX_HOST" \
  "http://$NGINX_IP/"
```

This confirms the NGINX rollback path remains usable. The website hostname itself resolves to Application Gateway, so this direct-IP test is separate.

A successful result contains HTML with:

```html
<h1>Hello from NGINX on private AKS</h1>
```

The successful Application Gateway test returned HTML containing the heading above. The separate NGINX route had also been tested successfully during the original deployment.

### Test the website Service directly

Port-forwarding is useful for checking the website without involving the load balancer or ingress controller. Keep the first command running in one terminal:

```bash
kubectl port-forward --namespace web service/nginx-site-nginx-site 8080:80
```

In another terminal:

```bash
curl http://127.0.0.1:8080/
```

This confirms the Service and website respond through the Kubernetes API tunnel. It does **not** prove that the private load balancer or ingress is reachable from your client.

## 10. DNS and browser access

The host name in the Ingress is a routing name, not a DNS record by itself. For a browser to use `http://nginx.internal.example.com/`, DNS must resolve that name to the current private ingress IP.

Use an Azure Private DNS zone or your organization's internal DNS. For the primary route, the hostname should resolve to the Application Gateway IP. Azure Private DNS zones need VNet links for client VNets, and on-premises clients may need DNS forwarding. The client also needs routes and firewall rules permitting traffic to the private Application Gateway IP. The rollback NGINX load balancer has a different private IP.

The `example.com` hostname in this project is an example placeholder. For a real setup, choose a hostname in an internal DNS zone your organization controls, then use that same hostname in:

1. The GitHub Actions `NGINX_HOST` secret.
2. The Helm Ingress host.
3. The private DNS A record.
4. The browser URL or `curl` request.

Once DNS is configured, check and test it from a connected client:

```bash
getent hosts nginx.internal.example.com
curl --fail --show-error http://nginx.internal.example.com/
```

If you are on a Linux VM, you can also open `http://nginx.internal.example.com/` in its browser. The internal IP is not reachable from an ordinary public internet connection.

## 11. Troubleshooting

### The `nginx-internal-0` Service has `<pending>` as its IP

The Azure load balancer has not received an address yet, or the controller is not ready. Check the controller pods and configuration:

```bash
kubectl get pods --namespace app-routing-system -o wide
kubectl describe nginxingresscontroller nginx-internal
kubectl get events --namespace app-routing-system --sort-by=.lastTimestamp
```

Wait for the controller to become ready and check the Service again.

### An ingress-controller pod is `Pending` with `Insufficient cpu`

Kubernetes uses CPU **requests** (reserved capacity) to decide whether it can place a pod on a node. A node may have some CPU idle at that moment and still not have enough unreserved CPU to schedule the pod.

Inspect the pod's scheduling reason and nodes:

```bash
kubectl describe pod --namespace app-routing-system <pending-pod-name>
kubectl describe nodes
```

In this deployment, the one-node cluster had almost all allocatable CPU already requested. Adding a separate one-node `workload` pool gave the cluster more capacity, after which the internal ingress became reachable and returned the website. More nodes or a larger VM size add Azure cost. Make node-pool changes through Terraform when Terraform manages the cluster.

### `kubectl top` says the Metrics API is not available

`kubectl top` needs a working Kubernetes Metrics API. If it is unavailable, that command cannot report current CPU usage. It is separate from the scheduler's CPU requests: scheduling events and the `Allocated resources` section of `kubectl describe node` can still show that requested CPU is full.

### `curl` times out connecting to the private IP

Check that you are using the current private IP of `nginx-internal-0`, and that your client has network connectivity to the AKS VNet. Check VPN/peering, routes, and firewall/NSG rules for TCP port 80. A private IP cannot be reached from an unrelated public network.

### Direct Service test works but Ingress test does not

Check that the controller pods are ready, the controller's load-balancer Service has an IP, and the Ingress host and class match:

```bash
kubectl get ingress --namespace web -o yaml
kubectl get nginxingresscontroller nginx-internal -o yaml
kubectl get service --namespace app-routing-system
```

The Ingress `host` must match the `Host` header in the direct curl test, and its `ingressClassName` must be `nginx-internal`.

### The controller works but the browser cannot find the host

This is usually a DNS issue. Check that the hostname resolves to the current internal IP from the same client running the browser. Confirm the DNS zone and record are linked or forwarded to that client's network. DNS resolution alone does not provide network routing to the private IP.

## 12. Useful Helm commands

```bash
# List Helm releases in the website namespace.
helm list --namespace web

# See the values used by the installed release.
helm get values nginx-site --namespace web

# See the Kubernetes YAML rendered and installed by Helm.
helm get manifest nginx-site --namespace web

# Show website and ingress resources.
kubectl get deployment,service,ingress --namespace web

# Show the website pod logs.
kubectl logs --namespace web deployment/nginx-site-nginx-site
```

Helm tracks the installation as the `nginx-site` release. Updating the chart with the same release name changes its resources instead of creating a second website.
