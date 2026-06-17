# Splunk Edge Processor on Azure AKS

Run Splunk Edge Processor nodes in **Azure Kubernetes Service (AKS)** — the Azure equivalent of Splunk’s [Running Edge Processor nodes in Amazon EKS (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Running_Edge_Processor_nodes_in_Amazon_EKS_(OnPrem)) guide.

This repo mirrors Splunk’s EKS workflow and swaps AWS-specific pieces for Azure:


| EKS (Splunk doc)                      | AKS (this repo)                                         |
| ------------------------------------- | ------------------------------------------------------- |
| Amazon ECR                            | Azure Container Registry (ACR)                          |
| AWS NLB via `LoadBalancer` Service    | Azure Standard Load Balancer via `LoadBalancer` Service |
| Manual metrics-server install         | Usually pre-installed on AKS                            |
| `kubectl apply -f edgeprocessor.yaml` | `k8s/deployment.yaml` + supporting manifests            |


## What’s in this repo

```
EP_AKS/
├── docker/                  # Edge Processor container (Splunk does not ship an official image)
│   ├── Dockerfile
│   └── entrypoint.sh
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.example.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
├── scripts/
│   ├── setup-aks.sh                 # Create RG, ACR, AKS
│   ├── build-and-push-acr.sh        # Build and push image to ACR
│   ├── create-secret.sh             # Store DMX token in Kubernetes
│   ├── create-configmap-from-splunk.sh
│   └── deploy.sh
├── env.template              # Visible copy — use this to create .env
└── .env.example              # Same content (may be hidden in file explorer)
```

Splunk’s downloadable `edgeprocessor.yaml` and `entrypoint.sh` are not publicly fetchable from Lantern, so this repo implements them from Splunk’s documented behavior in:

- [Building an Edge Processor container (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Building_an_Edge_Processor_container_(OnPrem))
- [Establishing authentication requirements (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Establishing_authentication_requirements_for_node_scaling_automation_(OnPrem))
- [Understanding the Edge Processor startup script (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Understanding_the_Edge_Processor_startup_script_(OnPrem))
- [Load balancing traffic to Edge Processors in Amazon EKS](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Load_balancing_traffic_to_Edge_Processors_in_Amazon_EKS)

---

## Prerequisites

1. **Splunk OnPrem Data Management control plane** with Edge Processor enabled
2. **Splunk token authentication** enabled on the control plane
3. **Edge Processor group** already created in Splunk UI
4. **Azure subscription** with permissions to create AKS, ACR, and Load Balancers
5. Local tools:
  - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`)
  - [kubectl](https://kubernetes.io/docs/tasks/tools/)
  - [Docker](https://docs.docker.com/get-docker/)
  - `jq` and `curl`

---

## Step-by-step setup

### Step 1 — Log in to Azure

```bash
az login
az account set --subscription "<your-subscription-id>"
cp env.template .env
# Edit .env with your values (see env.template in the project root)
```

> **Can't see `.env` in the sidebar?** Files starting with `.` are often hidden.
> Use **Cmd+P** (Mac) or **Ctrl+P** (Windows) and type `.env` to open it,
> or edit the visible `env.template` file and copy it: `cp env.template .env`

### Step 2 — Create AKS (+ optional ACR)

#### Option A — GitHub Actions + GHCR (no local Docker required)

Use **GitHub Container Registry** (`ghcr.io`) and let GitHub Actions build the image for you.
You do not need Docker installed on your laptop.

**What you still need:** AKS runs containers — Splunk does not ship an official image, so something
must build it. GitHub Actions does that in the cloud when you push this repo.

1. Push this project to a GitHub repo:

```bash
cd /Users/joshal/Desktop/EP_AKS
git init
git add .
git commit -m "Splunk Edge Processor on AKS"
git remote add origin https://github.com/YOUR_USERNAME/EP_AKS.git
git push -u origin main
```

1. Run the workflow: **GitHub repo → Actions → "Build Edge Processor Image" → Run workflow**
  Or push any change under `docker/` — the workflow runs automatically.
2. After it succeeds, your image is at:

```
ghcr.io/YOUR_USERNAME/edgeprocessor:latest
```

1. Link the package to your repo (first time only): **GitHub profile → Packages → edgeprocessor → Package settings → Connect repository**
2. Create AKS (no ACR):

```bash
./scripts/setup-aks-no-acr.sh ep-rg ep-aks eastus
```

1. Let AKS pull from GHCR (private package — recommended):
  Create a GitHub PAT with `**read:packages**` scope at [github.com/settings/tokens](https://github.com/settings/tokens)

```bash
./scripts/create-ghcr-secret.sh YOUR_USERNAME ghp_xxxxxxxx
```

1. Update `k8s/deployment.yaml`:

```yaml
imagePullSecrets:
  - name: registry-pull-secret
containers:
  - name: ep
    image: ghcr.io/YOUR_USERNAME/edgeprocessor:latest
```

Then continue from **Step 5** below (Splunk token, ConfigMap, deploy).

> **Public vs private:** GHCR packages are private by default. Keep them private and use
> `imagePullSecrets`. Making the package public avoids the secret but exposes your image.

---

#### Option B — Docker Hub (requires local Docker)

The `--attach-acr` flag needs permission to create **role assignments** on the subscription.
If you see *"Could not create a role assignment for ACR"*, skip ACR entirely and use **Docker Hub**
(or GitHub above). Splunk’s docs say any compatible registry works — ACR is just the Azure default.

```bash
chmod +x scripts/*.sh

# Create AKS only — no registry, no role assignment needed
./scripts/setup-aks-no-acr.sh ep-rg ep-aks eastus

# Log in to Docker Hub (free account: https://hub.docker.com)
docker login

# Build and push the Edge Processor image
./scripts/build-and-push-dockerhub.sh yourusername latest
```

Update `k8s/deployment.yaml`:

```yaml
image: yourusername/edgeprocessor:latest
```

**Private Docker Hub repo** (recommended — don’t leave the image public):

1. Create a private repo at hub.docker.com named `edgeprocessor`
2. Create an access token: Docker Hub → Account Settings → Security → New Access Token
3. Store pull credentials in Kubernetes:

```bash
./scripts/create-registry-secret.sh dockerhub yourusername <access-token>
```

1. Uncomment `imagePullSecrets` in `k8s/deployment.yaml`:

```yaml
imagePullSecrets:
  - name: registry-pull-secret
```

Then continue from **Step 5** below (Splunk token, ConfigMap, deploy).

---

#### Option C — AKS + ACR (requires subscription Owner or User Access Administrator)

**Option C1: Use the helper script**

```bash
chmod +x scripts/*.sh
./scripts/setup-aks.sh ep-rg ep-aks mycompanyacr eastus
```

**Option C2: Manual commands**

```bash
az group create --name ep-rg --location eastus

az acr create --resource-group ep-rg --name mycompanyacr --sku Standard

az aks create \
  --resource-group ep-rg \
  --name ep-aks \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --enable-managed-identity \
  --attach-acr mycompanyacr \
  --generate-ssh-keys

az aks get-credentials --resource-group ep-rg --name ep-aks
kubectl get nodes
```

`--attach-acr` lets AKS pull images from ACR without image pull secrets.

### Step 3 — Build and push the Edge Processor image

**Skip this step if you used GitHub Actions (Option A)** — the image is already in GHCR.

**If using ACR (Option C):**

```bash
./scripts/build-and-push-acr.sh mycompanyacr latest
```

This creates `mycompanyacr.azurecr.io/edgeprocessor:latest`.

**Test locally first (optional):**

```bash
docker build -t edgeprocessor ./docker

docker run --rm \
  -e GROUP_ID="<edge-processor-group-guid>" \
  -e DMX_HOST="splunk-cp.example.com" \
  -e DMX_ENV=production \
  -e DMX_TOKEN="<your-token>" \
  edgeprocessor
```

Verify the instance appears healthy in Splunk **Manage instances**. Stop cleanly:

```bash
docker exec <container-id> sh -c 'kill $(pidof splunk-edge)'
```

### Step 4 — Create a Splunk provisioning token

Create a token on the **control plane** Splunk instance (not indexers/search heads).

**API (recommended):**

```bash
curl --location "https://<DMX_HOST>:8089/services/authorization/tokens?output_mode=json" \
  --header "Content-Type: application/json" \
  --header "Authorization: Basic <base64-user-pass>" \
  --data "name=ep-aks-token&audience=ep-instance&expires_on=%2B90d"
```

Save the `token` value from the JSON response.

**UI alternative:**  
`https://<DMX_HOST>/en-US/manager/splunk_pipeline_builders/authorization/tokens`

### Step 5 — Create Kubernetes secret for the token

```bash
./scripts/create-secret.sh "<your-dmx-token>" splunk-edge edge-processor-secrets
```

This stores the token as `DMX_TOKEN` in the pod via `secretKeyRef`.

### Step 6 — Create ConfigMap for Edge Processor group IDs

Each replica needs a `GROUP_ID` (GUID). Use human-readable keys in a ConfigMap.

**Option A: From Splunk API**

```bash
./scripts/create-configmap-from-splunk.sh \
  splunk-cp.example.com \
  "<your-dmx-token>" \
  splunk-edge \
  ep-instance-guids
```

**Option B: Manual**

Copy the group GUID from Splunk UI → Edge Processor → open group → use the ID shown in Manage instances.

```bash
cp k8s/configmap.example.yaml k8s/configmap.yaml
# Edit EP_CORP_DC_1 (or your key) with the real GUID
kubectl apply -f k8s/configmap.yaml
```

### Step 7 — Edit the deployment manifest

Update `k8s/deployment.yaml`:


| Field                 | Value                                              |
| --------------------- | -------------------------------------------------- |
| `image`               | `mycompanyacr.azurecr.io/edgeprocessor:latest`     |
| `DMX_HOST`            | Your control plane hostname (no `https://`)        |
| `configMapKeyRef.key` | Key matching your Edge Processor name in ConfigMap |


If package auto-discovery fails, copy `SPLUNK_EDGE_PACKAGE_URL` and `SPLUNK_EDGE_PACKAGE_CHECKSUM` from the **Manage instances** install script in Splunk UI and uncomment those env vars.

For lab environments with self-signed TLS on the control plane, uncomment `DMX_INSECURE: "true"`.

### Step 8 — Deploy to AKS

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml   # or configmap.example.yaml if edited in place
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

Or:

```bash
./scripts/deploy.sh
```

Watch pods come up:

```bash
kubectl get pods -n splunk-edge -w
kubectl logs -n splunk-edge -l app=ep -f
```

Confirm instances show **Healthy** in Splunk **Manage instances**.

### Step 9 — Expose Edge Processor via Azure Load Balancer

The `k8s/service.yaml` creates a `LoadBalancer` Service. On AKS, Azure provisions a **Standard Load Balancer** with a public IP (unless you set the internal annotation).

```bash
kubectl get svc ep-service -n splunk-edge
```

Wait until `EXTERNAL-IP` shows an IP (not `<pending>`):

```
NAME         TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)
ep-service   LoadBalancer   10.0.123.45    20.x.x.x        9997:30001/TCP,8088:30002/TCP
```

Point data sources at:

- **Splunk forwarders (S2S):** `20.x.x.x:9997`
- **HEC:** `20.x.x.x:8088`

Add syslog or other ports in `service.yaml` if needed.

**Internal LB only (private IP):** uncomment in `service.yaml`:

```yaml
service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

### Step 10 — Enable horizontal pod autoscaling (optional)

AKS usually includes **metrics-server** already. Verify:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods -n splunk-edge
```

If metrics work, apply HPA:

```bash
kubectl apply -f k8s/hpa.yaml
kubectl get hpa -n splunk-edge
```

Default HPA: 2–10 replicas, scale at 70% CPU and memory.

> **Note:** Splunk Edge Processor `GROUP_ID` is tied to a specific Edge Processor group. Scaling replicas gives multiple instances under the **same** group — which matches Splunk’s EKS scaling pattern. If you need separate groups per site, create separate Deployments with different ConfigMap keys.

### Step 11 — Monitor

**Splunk platform:**

```spl
index=_internal sourcetype="edge-log"
```

```spl
| mcatalog values(metric_name) WHERE index=_metrics AND sourcetype="edge-metrics"
```

**Kubernetes:**

```bash
kubectl logs -n splunk-edge -l app=ep
kubectl describe pod -n splunk-edge -l app=ep
```

Pod logs also land under `/opt/splunk-edge/splunk-edge/var/log/edge.log` inside the container.

---

## Troubleshooting


| Symptom                   | Likely cause                                              | Fix                                                                                          |
| ------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Pod `CrashLoopBackOff`    | Bad token, wrong `GROUP_ID`, or control plane unreachable | Check logs; verify secret and ConfigMap; test `curl https://$DMX_HOST:8089` from a debug pod |
| Package download fails    | API discovery path differs by Splunk version              | Set `SPLUNK_EDGE_PACKAGE_URL` from Manage instances script                                   |
| TLS errors                | Self-signed cert on control plane                         | Set `DMX_INSECURE=true` (lab only) or mount trusted CA                                       |
| `ImagePullBackOff`        | ACR not attached                                          | Run `az aks update --attach-acr mycompanyacr` or add `imagePullSecrets`                      |
| Service stuck `<pending>` | LB quota / subnet                                         | Check `kubectl describe svc ep-service`; verify Azure LB permissions                         |
| Orphaned instances in UI  | Pod killed without offboard                               | Use graceful shutdown; entrypoint and `preStop` hook call `offboard`                         |


**Debug pod for network tests:**

```bash
kubectl run -it --rm debug --image=ubuntu:22.04 -n splunk-edge -- bash
apt-get update && apt-get install -y curl
curl -vk "https://<DMX_HOST>:8089"
```

---

## Security notes

- Never commit real tokens. Use `scripts/create-secret.sh` or Azure Key Vault + [Secrets Store CSI Driver](https://learn.microsoft.com/en-us/azure/aks/csi-secrets-store-driver).
- Restrict Load Balancer ingress with NSG rules or an internal LB + private connectivity.
- Rotate Splunk tokens on a schedule (`expires_on` in token API).
- Run AKS with Azure AD / RBAC and least-privilege kubeconfig access.

---

## Cleanup

```bash
kubectl delete namespace splunk-edge
az aks delete --resource-group ep-rg --name ep-aks --yes
az acr delete --resource-group ep-rg --name mycompanyacr --yes
az group delete --name ep-rg --yes
```

---

## References

- [Running Edge Processor nodes in Amazon EKS (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Running_Edge_Processor_nodes_in_Amazon_EKS_(OnPrem))
- [Load balancing traffic to Edge Processors in Amazon EKS](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Load_balancing_traffic_to_Edge_Processors_in_Amazon_EKS)
- [Azure AKS documentation](https://learn.microsoft.com/en-us/azure/aks/)
- [Attach ACR to AKS](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration)

