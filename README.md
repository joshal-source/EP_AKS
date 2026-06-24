# Splunk Edge Processor on Azure AKS

---

## Prerequisites

1. **Splunk OnPrem Data Management control plane** with Edge Processor enabled
2. **Splunk token authentication** enabled on the control plane
3. **Edge Processor group** already created in Splunk UI
4. **Azure subscription** with permissions to create AKS, ACR, and Load Balancers
5. Local tools:
  - [Docker](https://docs.docker.com/engine/install/) (build images locally)
  - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`)
  - [kubectl](https://kubernetes.io/docs/tasks/tools/)
  - [Helm 3](https://helm.sh/docs/intro/install/)
  - `jq` and `curl`

**ACR name:** `ACR_NAME` in `.env` must be globally unique (lowercase alphanumeric, 5–50 chars). Example: `epacr` → `epacr.azurecr.io`.

---

## Architecture (default deploy)

Images are built on your machine with Docker, pushed to Azure Container Registry (ACR), and pulled by AKS using an **`acr-pull-secret`**.

```mermaid
flowchart LR
  subgraph local["Your machine"]
    docker["Docker engine<br/>build-local.sh"]
  end

  subgraph sources["Data sources"]
    HEC["HEC clients"]
    UF["Forwarders / S2S"]
  end

  subgraph azure["Azure — resource group ep-rg"]
    acr["ACR epacr.azurecr.io"]
    subgraph aks["AKS cluster ep-aks — worker nodes from .env"]
      subgraph ns["namespace splunk-edge"]
        pullsec["Secret acr-pull-secret"]
        dep["Deployment ep-deployment<br/>replicaCount pods"]
        svc["Service ep-service"]
        cm["ConfigMap ep-instance-guids<br/>GROUP_ID"]
        sec["Secret edge-processor-secrets<br/>provisioning JWT"]
      end
    end
    lb["Azure Standard Load Balancer<br/>public EXTERNAL-IP"]
  end

  splunk["Splunk control plane<br/>DMX_HOST"]

  docker -->|"docker push"| acr
  pullsec --> dep
  acr -.->|"pull via secret"| dep
  HEC -->|"TCP 8088"| lb
  UF -->|"TCP 9997"| lb
  lb --> svc
  svc --> dep
  cm --> dep
  sec --> dep
  dep -->|"TCP 8089 OpAMP + package download"| splunk
  dep -->|"TCP 9997 processed data S2S"| splunk
```

| Layer | Default | Purpose |
| ----- | ------- | ------- |
| **AKS cluster** | `ep-aks` in `ep-rg` | Runs Kubernetes |
| **Worker nodes** | 2 × `Standard_D4s_v5` (from `.env`) | Host EP pods (Ubuntu 22.04) |
| **EP pods** | 2 (`replicaCount` in values) | One Splunk instance per pod, same Edge Processor group |
| **LoadBalancer** | `ep-service` public IP | Single entry for HEC `:8088` and S2S `:9997` |
| **Image** | `<ACR_NAME>.azurecr.io/edgeprocessor:latest` | Built locally; pulled via `acr-pull-secret` |
| **Splunk outbound** | AKS SNAT IP → `:8089`, `:9997` | Registration, packages, and exported data to your indexer |

Each pod runs `splunk-edge`, `splunksup`, and `edge_linux_amd64`. All replicas share one **GROUP_ID** from the install script and appear as separate instances under the same Edge Processor group in Splunk UI.

---

## Quick start

Complete **[Splunk control plane setup](#splunk-control-plane-setup-do-this-first)** on your Data Management host before deploying to AKS.

### 1. Clone and configure Azure

```bash
cd EP_AKS
cp env.template .env
```

Edit `.env` if needed:

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `AZURE_RESOURCE_GROUP` | `ep-rg` | Azure resource group |
| `AZURE_LOCATION` | `eastus` | Region |
| `AKS_CLUSTER_NAME` | `ep-aks` | AKS cluster name |
| `AKS_NODE_COUNT` | `2` | Worker nodes |
| `AKS_NODE_VM_SIZE` | `Standard_D4s_v5` | VM SKU (4 vCPU, 16 GiB) |
| `ACR_NAME` | `epacr` | Azure Container Registry (globally unique name) |
| `IMAGE_NAME` | `edgeprocessor` | Image name in ACR |
| `IMAGE_TAG` | `latest` | Image tag |

### 2. Helm overrides (pod count and image)

```bash
cp helm/edge-processor/values-local.yaml.example helm/edge-processor/values-local.yaml
```

Edit `helm/edge-processor/values-local.yaml` — set `replicaCount` and match `image.repository` to your ACR:

```yaml
replicaCount: 2
image:
  repository: epacr.azurecr.io/edgeprocessor   # must match ACR_NAME in .env
  tag: latest
```

Ensure nodes can fit all pods (`replicaCount` × `resources` per pod). Increase `AKS_NODE_COUNT` or `AKS_NODE_VM_SIZE` in `.env` if needed.

### 3. Splunk install script

In Splunk UI → **Manage instances** → **Install** → download and save as `install-script.txt` in the repo root.

This file contains the **provisioning JWT** (`ep-instance` audience) and `GROUP_ID` — not your HEC token.

### 4. Create AKS, build image, and deploy

```bash
az login

./scripts/setup-aks.sh              # creates AKS + ACR (ACR_NAME from .env)
./scripts/build-local.sh --push     # docker build on your machine, push to ACR
./scripts/create-acr-secret.sh      # ACR admin creds → acr-pull-secret in Kubernetes
./scripts/setup-from-install-script.sh install-script.txt --apply
./scripts/show-ep-endpoints.sh
```

`build-local.sh` uses your local Docker engine. `--push` tags and uploads to `${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}`.

`create-acr-secret.sh` is required — AKS pulls the image using this Kubernetes secret (not managed identity).

`setup-from-install-script.sh --apply` also refreshes `acr-pull-secret` automatically if `ACR_NAME` is in `.env`.

`show-ep-endpoints.sh` waits for the LoadBalancer IP and prints HEC/S2S URLs plus a sample `curl`.

### 5. Verify

1. Splunk UI → **Manage instances** → EP instances show **Healthy**
2. Open Splunk firewall for AKS **outbound SNAT IP** on **8089** (OpAMP/packages) and **9997** (S2S data)
3. Send a test HEC event using your **HEC token** from the Splunk UI (not the install-script JWT):

```bash
./scripts/show-ep-endpoints.sh   # prints curl example with LB IP
```

### Redeploy (cluster already exists)

After changing `docker/` or Splunk config:

```bash
az aks get-credentials --resource-group ep-rg --name ep-aks --overwrite-existing
./scripts/build-local.sh --push     # if the container image changed
./scripts/setup-from-install-script.sh install-script.txt --apply
./scripts/show-ep-endpoints.sh
```

Re-download `install-script.txt` from Splunk if you regenerated the provisioning token or changed the EP group.

### Local Docker only (no Kubernetes)

Run a single EP container on your laptop for testing:

```bash
./scripts/run-local-docker.sh install-script.txt
```

HEC and S2S listen on `localhost:8088` and `localhost:9997`. Splunk still needs network access to your machine for outbound registration and S2S export.

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
| `AKS_NODE_COUNT` | `2` | Worker nodes |
| `AKS_NODE_VM_SIZE` | `Standard_D4s_v5` | VM SKU (4 vCPU, 16 GiB) |
| `ACR_NAME` | `epacr` | Creates ACR; image pulls use `acr-pull-secret` |
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
| `replicaCount` | Fixed EP pod count (default 2) |
| `image.repository` / `tag` | ACR image (must match `build-local.sh --push`) |
| `resources` | CPU/memory per pod |
| `strategy.rollingUpdate.maxSurge` | `0` = no extra pod during rollouts (avoids 3rd Splunk instance) |
| `service.annotations` | e.g. internal Azure Load Balancer |
| `terminationGracePeriodSeconds` | Time for Splunk offboard on pod shutdown |

Splunk-specific settings (`dmxHost`, package URL, `groupId`, etc.) come from **`values-install.yaml`**, generated by `setup-from-install-script.sh`.

---

## Cleanup

```bash
kubectl delete namespace splunk-edge
az aks delete --resource-group ep-rg --name ep-aks --yes
az group delete --name ep-rg --yes
```

