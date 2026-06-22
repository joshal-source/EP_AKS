# Splunk Edge Processor on Azure AKS

Run Splunk Edge Processor nodes in **Azure Kubernetes Service (AKS)** — the Azure equivalent of Splunk’s [Running Edge Processor nodes in Amazon EKS (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Running_Edge_Processor_nodes_in_Amazon_EKS_(OnPrem)) guide.

This repo mirrors Splunk’s EKS workflow and swaps AWS-specific pieces for Azure:


| EKS (Splunk doc)                      | AKS (this repo)                                         |
| ------------------------------------- | ------------------------------------------------------- |
| Amazon ECR                            | Azure Container Registry (ACR)                          |
| AWS NLB via `LoadBalancer` Service    | Azure Standard Load Balancer via `LoadBalancer` Service |
| Manual metrics-server install         | Usually pre-installed on AKS                            |
| `kubectl apply -f edgeprocessor.yaml` | **Helm chart** `helm/edge-processor` + install script |


## What’s in this repo

```
EP_AKS/
├── docker/                  # Edge Processor container (Splunk does not ship an official image)
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── mgmt-proxy.py
├── helm/edge-processor/     # Helm chart — primary deploy path (values.yaml)
│   ├── values.yaml
│   ├── values-local.yaml.example
│   └── templates/
├── k8s/                     # Legacy flat YAML (use Helm instead)
├── scripts/
│   ├── setup-from-install-script.sh
│   ├── helm-deploy.sh
│   ├── show-ep-endpoints.sh
│   ├── setup-aks.sh
│   ├── setup-aks-with-acr.sh        # Optional: AKS + Azure Container Registry
│   └── ...
├── env.template
└── .env.example
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
  - [Helm 3](https://helm.sh/docs/intro/install/)
  - GitHub PAT with `read:packages` (for private GHCR image)
  - `jq` and `curl`

---

## Quick start

Complete **Splunk control plane setup** below first, then:

```bash
cd EP_AKS
cp env.template .env
# Splunk UI → Manage instances → Install → save as install-script.txt

az login
./scripts/setup-aks.sh
./scripts/create-ghcr-secret.sh YOUR_GITHUB_USER ghp_<pat>
./scripts/setup-from-install-script.sh install-script.txt --apply
./scripts/show-ep-endpoints.sh
```

**Optional** — change node size/count or pod replicas before deploy:

```bash
cp helm/edge-processor/values-local.yaml.example helm/edge-processor/values-local.yaml
# edit .env (AKS_NODE_COUNT, AKS_NODE_VM_SIZE) and/or values-local.yaml (hpa, resources)
```

**Verify**

- Splunk UI → Manage instances → instances **Healthy**
- HEC test uses your **HEC token** (not the JWT from the install script)
- Open Splunk firewall for new AKS **outbound SNAT IP** on ports **8089** and **9997**

**Redeploy** (cluster already exists):

```bash
az aks get-credentials --resource-group ep-rg --name ep-aks --overwrite-existing
./scripts/setup-from-install-script.sh install-script.txt --apply
./scripts/show-ep-endpoints.sh
```

---

## Splunk control plane setup (do this first)

These steps run on your **Splunk Data Management control plane** host (the instance where you manage Edge Processors in the UI — not indexers/search heads alone).

### 1. TLS on management port 8089

Splunk must listen with TLS on **8089** (default for `enableSplunkdSSL`).

```bash
# In $SPLUNK_HOME/etc/system/local/server.conf
[sslConfig]
enableSplunkdSSL = true
```

Restart Splunk after changes.

### 2. Advertise HTTPS URLs (recommended)

So install scripts and package metadata use `https://` instead of `http://`:

```bash
# In $SPLUNK_HOME/etc/system/local/web.conf
[settings]
proxyHostPort = https://<DMX_HOST>:8089
```

Restart Splunk, then **re-download the install script** from the UI and confirm URLs use `https://`.

> **Note:** Even with `proxyHostPort`, OpAMP may still return `http://` package URLs. This repo’s container sets `MGMT_PROXY_ENABLED=true` by default to rewrite those locally. Do **not** set `mgmtUri` in `server.conf` — that is not the correct setting for this issue.

### 3. Enable S2S receiving on the indexer (required for data in Splunk)

The Edge Processor forwards processed data to your Splunk indexer over **S2S port 9997**. Without this, HEC returns `Success` but events never appear in Search.

On the Splunk instance that receives indexer traffic (often the same control-plane host in small deployments):

```bash
$SPLUNK_HOME/bin/splunk enable listen 9997 -auth admin:changeme
$SPLUNK_HOME/bin/splunk restart
```

**Network:** open **TCP 9997** on the Splunk host security group/firewall to your AKS cluster outbound IPs (or the NAT/LB egress used by AKS nodes).

Verify from your laptop or a debug pod:

```bash
nc -zv <DMX_HOST> 9997
```

### 4. Two different tokens (do not mix them up)

| Token | Purpose | Where to get it |
| ----- | ------- | --------------- |
| **Provisioning token** (`ep-instance`) | Pod registration, OpAMP, package download | Install script from **Manage instances**, or Tokens UI with audience `ep-instance` |
| **HEC token** | Sending events **to** the Edge Processor | Splunk UI → Edge Processor → your HEC source / receiver configuration |

The provisioning token is a long **JWT** (`eyJ...`) in the install script (`echo "eyJ..." > splunk-edge/var/token`). It is **not** the same as a generic Splunk REST API token or the HEC token used to send events.

---

## Customize deployment

### Azure node pool (VM size, count, OS)

Set in `.env` (from `env.template`), then create the cluster:

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `AKS_NODE_COUNT` | `3` | Worker nodes |
| `AKS_NODE_VM_SIZE` | `Standard_D4s_v5` | VM SKU (4 vCPU, 16 GiB) |
| `AKS_K8S_VERSION` | (latest) | Optional Kubernetes version |

```bash
cp env.template .env
# edit AKS_NODE_COUNT, AKS_NODE_VM_SIZE
./scripts/setup-aks.sh
```

Node OS is **Ubuntu 22.04** (AKS managed image). EP **container** OS is **Ubuntu 22.04** in `docker/Dockerfile`.

### Kubernetes / EP pods (Helm)

Copy the example overrides file and edit:

```bash
cp helm/edge-processor/values-local.yaml.example helm/edge-processor/values-local.yaml
```

| values key | Controls |
| ---------- | -------- |
| `replicaCount` | Pod count when `hpa.enabled: false` |
| `hpa.minReplicas` / `maxReplicas` | Autoscaling bounds (default 2–10) |
| `hpa.enabled` | Set `false` for a fixed pod count |
| `resources` | CPU/memory per pod |
| `image.repository` / `tag` | Container image |
| `strategy.rollingUpdate.maxSurge` | `0` = no extra pod during rollouts (avoids 3rd Splunk instance) |
| `service.annotations` | e.g. internal Azure Load Balancer |
| `terminationGracePeriodSeconds` | Time for Splunk offboard on pod shutdown |

Splunk-specific settings (`dmxHost`, package URL, `groupId`, etc.) come from **`values-install.yaml`**, generated by `setup-from-install-script.sh` (gitignored).

**Value file order** (later overrides earlier):

1. `helm/edge-processor/values.yaml` — defaults (committed)
2. `helm/edge-processor/values-local.yaml` — your sizing (optional, gitignored)
3. `helm/edge-processor/values-install.yaml` — from Splunk install script (gitignored)

Deploy or upgrade without re-parsing the install script:

```bash
./scripts/helm-deploy.sh
helm upgrade edge-processor ./helm/edge-processor -f helm/edge-processor/values-local.yaml --reuse-values  # example
```

Preview rendered manifests:

```bash
helm template edge-processor ./helm/edge-processor \
  -f helm/edge-processor/values.yaml \
  -f helm/edge-processor/values-install.yaml
```

---

## Step-by-step setup (manual alternative)

Use this section if you prefer to configure each piece yourself instead of `setup-from-install-script.sh`.

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
./scripts/setup-aks.sh
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
./scripts/setup-aks.sh

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
./scripts/setup-aks-with-acr.sh ep-rg ep-aks mycompanyacr eastus
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

### Step 4 — Get the install script

In Splunk UI: **Edge Processor → your group → Manage instances → Install**.

Copy the install script to `install-script.txt`, then either:

**Automated (recommended):**

```bash
./scripts/setup-from-install-script.sh install-script.txt --apply
```

**Manual:** continue with Steps 5–8 below.

The provisioning JWT is the long `eyJ...` string written to `splunk-edge/var/token` in the script — not `DMX_TOKEN=...` (that name is only used inside the container).

Optional — test the token before deploying:

```bash
./scripts/test-splunk-token.sh --insecure <DMX_HOST> "<provisioning-token-jwt>"
```

**API alternative** (if you prefer creating a new token instead of the install-script JWT):

```bash
curl --location "https://<DMX_HOST>:8089/services/authorization/tokens?output_mode=json" \
  --header "Content-Type: application/json" \
  --header "Authorization: Basic <base64-user-pass>" \
  --data "name=ep-aks-token&audience=ep-instance&expires_on=%2B90d"
```

### Step 5 — Create Kubernetes secret for the provisioning token (manual)

Use the **install-script JWT**, not a REST API token:

```bash
./scripts/create-secret.sh "<provisioning-token-from-install-script>" splunk-edge edge-processor-secrets
```

This stores the token as `DMX_TOKEN` in the pod via `secretKeyRef`. After updating the secret, restart pods:

```bash
kubectl rollout restart deployment/ep-deployment -n splunk-edge
```

### Step 6 — Create ConfigMap for Edge Processor group IDs (manual)

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

### Step 7 — Edit the deployment manifest (manual)

Update `k8s/deployment.yaml`:


| Field | Value |
| ----- | ----- |
| `image` | Your registry image (e.g. `ghcr.io/YOUR_USERNAME/edgeprocessor:latest`) |
| `DMX_HOST` | Control plane hostname (no `https://`) |
| `GROUP_ID` / `configMapKeyRef.key` | Key matching your Edge Processor name in ConfigMap |
| `SPLUNK_EDGE_PACKAGE_URL` | **Required** — from install script (see Step 4) |
| `SPLUNK_EDGE_PACKAGE_CHECKSUM` | **Required** — SHA-256 from install script |
| `DMX_INSECURE` | `"true"` if control plane uses self-signed TLS on 8089 |
| `MGMT_PROXY_ENABLED` | `"true"` (default) — rewrites `http://` package URLs in OpAMP |

Example env block (adjust values for your environment):

```yaml
            - name: DMX_HOST
              value: "splunk-cp.example.com"
            - name: SPLUNK_EDGE_PACKAGE_URL
              value: "https://splunk-cp.example.com:8089/servicesNS/-/splunk_pipeline_builders/dmx/packages/splunk-edge/.../splunk-edge.tar.gz"
            - name: SPLUNK_EDGE_PACKAGE_CHECKSUM
              value: "<sha256-from-install-script>"
            - name: DMX_INSECURE
              value: "true"
            - name: MGMT_PROXY_ENABLED
              value: "true"
```

The container downloads the bootstrap package using `--resolve` to the real indexer IP, then starts a local TLS proxy on `dmx-mgmt-proxy:8089` for OpAMP only. It does **not** alias your real `DMX_HOST` to `127.0.0.1`, so S2S export to the indexer on port **9997** still works.

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

Verify inside the pod (all three should be present after ~2 minutes):

```bash
kubectl exec -n splunk-edge deploy/ep-deployment -- ps aux
# Expect: splunk-edge, splunksup, edge_linux_amd64
```

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

Point data sources at the **LoadBalancer EXTERNAL-IP**:

| Protocol | Address | Notes |
| -------- | ------- | ----- |
| **HEC** | `http://<EXTERNAL-IP>:8088/services/collector/event` | Plain HTTP; use HEC token (see below) |
| **S2S** | `<EXTERNAL-IP>:9997` | Universal forwarders |

Add syslog or other ports in `service.yaml` if needed (syslog listens on **10514** inside the pod by default but is not exposed on the Service until you add it).

**Internal LB only (private IP):** uncomment in `service.yaml`:

```yaml
service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

### Step 10 — Send data to the Edge Processor

Get the public HEC and S2S addresses (waits for the LoadBalancer IP if still pending):

```bash
./scripts/show-ep-endpoints.sh
```

**HEC** (requires the HEC token from your EP HEC source — not the provisioning JWT):

```bash
curl -X POST "http://<EXTERNAL-IP>:8088/services/collector/event" \
  -H "Content-Type: application/json" \
  -H "Authorization: Splunk <hec-token-value>" \
  -d '{"event":"hello from test","sourcetype":"myapp","source":"manual-test"}'
```

`{"text": "Success", "code": 0}` means the EP accepted the event. Data then flows through pipelines and S2S to your Splunk indexer on `<DMX_HOST>:9997`.

**Find events in Splunk Search** (until you apply a pipeline that routes to `main`):

```spl
index=_internal sourcetype=myapp earliest=-15m
```

```spl
index=* sourcetype=myapp earliest=-15m
```

The `index` field in your JSON event only applies if a **pipeline** on the EP group routes data to that index.

**Splunk forwarder (S2S):**

```ini
# outputs.conf
[tcpout:ep-aks]
server = <EXTERNAL-IP>:9997
```

### Step 11 — Enable horizontal pod autoscaling (optional)

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

### Step 12 — Monitor

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


| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Pod `CrashLoopBackOff` | Bad provisioning token, wrong `GROUP_ID`, or control plane unreachable | Check logs; verify secret matches **install-script JWT**; `./scripts/test-splunk-token.sh` |
| `insecure package URL http://...` | OpAMP advertises HTTP package URLs | Keep `MGMT_PROXY_ENABLED=true`; or fix `proxyHostPort` on Splunk and restart |
| `cannot parse invalid wire-format` | Broken OpAMP proxy rewrite | Use current image (`mgmt-proxy.py` protobuf-aware rewrite) |
| Package download 404 | Wrong or stale package URL | Re-copy install script; update `SPLUNK_EDGE_PACKAGE_URL` + checksum |
| Checksum mismatch | SHA-256 vs SHA-512 | Install script uses SHA-256; set `SPLUNK_EDGE_PACKAGE_CHECKSUM` accordingly |
| Instance **Pending** in UI | `splunksup` / `edge` not started | Check install log; fix package URL or proxy; verify provisioning token |
| HEC returns `Success` but no data in Splunk | Indexer not listening on 9997, or wrong search index | `splunk enable listen 9997`; open firewall; search `index=_internal` or pipeline index |
| HEC returns `401 Unauthorized` | Missing or wrong **HEC token** | Use HEC token from EP HEC source, not provisioning JWT |
| S2S `connection refused` to indexer | Splunk not receiving on 9997 | Enable receiving; open security group from AKS |
| S2S connects to `127.0.0.1:9997` | Old image aliased `DMX_HOST` in `/etc/hosts` | Use current image (`dmx-mgmt-proxy` hostname only) |
| TLS errors to control plane | Self-signed cert on 8089 | Set `DMX_INSECURE=true` (lab) or mount trusted CA |
| `ImagePullBackOff` | GHCR private without pull secret | `./scripts/create-ghcr-secret.sh` + `imagePullSecrets` |
| Service stuck `<pending>` | LB quota / subnet | `kubectl describe svc ep-service` |
| Orphaned instances in UI | Pod killed without offboard | Entrypoint calls `offboard` on shutdown; avoid force-delete during bootstrap |

**Useful log paths inside the pod:**

```bash
kubectl exec -n splunk-edge deploy/ep-deployment -- tail -50 /opt/splunk-edge/splunk-edge/var/log/install-splunk-edge.out
kubectl exec -n splunk-edge deploy/ep-deployment -- tail -50 /opt/splunk-edge/splunk-edge/var/log/edge.log
```

**Debug pod for network tests:**

```bash
kubectl run -it --rm debug --image=ubuntu:22.04 -n splunk-edge -- bash
apt-get update && apt-get install -y curl
curl -vk "https://<DMX_HOST>:8089"
```

---

## Security notes

- Never commit real tokens. Install script output (`values-install.yaml`) is gitignored.
- Restrict Load Balancer ingress with NSG rules or an internal LB + private connectivity.
- Rotate Splunk tokens on a schedule (`expires_on` in token API).
- Run AKS with Azure AD / RBAC and least-privilege kubeconfig access.

---

## Cleanup

```bash
kubectl delete namespace splunk-edge
az aks delete --resource-group ep-rg --name ep-aks --yes
az group delete --name ep-rg --yes
```

---

## References

- [Running Edge Processor nodes in Amazon EKS (OnPrem)](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Running_Edge_Processor_nodes_in_Amazon_EKS_(OnPrem))
- [Load balancing traffic to Edge Processors in Amazon EKS](https://lantern.splunk.com/Platform_Data_Management/Transform_Pipelines/Load_balancing_traffic_to_Edge_Processors_in_Amazon_EKS)
- [Azure AKS documentation](https://learn.microsoft.com/en-us/azure/aks/)
- [Attach ACR to AKS](https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration)

