#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${1:-splunk-edge}"
SERVICE="${2:-ep-service}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_ep_env "${ROOT_DIR}"

usage() {
  cat <<EOF
Usage: $0 [namespace] [service-name]

Print public HEC and S2S endpoints for the Edge Processor LoadBalancer,
and AKS outbound SNAT IP(s) for Splunk/on-prem firewall rules.

Environment:
  WAIT_SECONDS   Max seconds to wait for EXTERNAL-IP (default: 300)

Example:
  $0
  $0 splunk-edge ep-service
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! kubectl get svc "${SERVICE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Service ${SERVICE} not found in namespace ${NAMESPACE}" >&2
  echo "Deploy first: ./scripts/setup-from-install-script.sh install-script.txt --apply" >&2
  exit 1
fi

get_external_ip() {
  kubectl get svc "${SERVICE}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}'
}

echo "Waiting for LoadBalancer external IP on ${SERVICE} (up to ${WAIT_SECONDS}s)..."
deadline=$((SECONDS + WAIT_SECONDS))
external_ip=""

while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  external_ip="$(get_external_ip || true)"
  if [[ -n "${external_ip}" && "${external_ip}" != "<pending>" ]]; then
    break
  fi
  external_ip=""
  sleep 5
done

if [[ -z "${external_ip}" ]]; then
  echo ""
  echo "EXTERNAL-IP is still pending. Check status with:"
  echo "  kubectl get svc ${SERVICE} -n ${NAMESPACE} -w"
  echo "  kubectl describe svc ${SERVICE} -n ${NAMESPACE}"
  exit 1
fi

hec_port="$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="hec")].port}')"
s2s_port="$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="s2s")].port}')"
hec_port="${hec_port:-8088}"
s2s_port="${s2s_port:-9997}"

cat <<EOF

Edge Processor public endpoints (${NAMESPACE}/${SERVICE}):
  HEC:  http://${external_ip}:${hec_port}/services/collector/event
  S2S:  ${external_ip}:${s2s_port}

Send a test HEC event (use your HEC token from Splunk UI — not the install-script JWT):

  curl "http://${external_ip}:${hec_port}/services/collector/event" \\
    -H "Authorization: Splunk <your-hec-token>" \\
    -H "Content-Type: application/json" \\
    -d '{"event":"ep deploy test","sourcetype":"ep_aks_test"}'

EOF

print_aks_snat_ips() {
  local rg="${AZURE_RESOURCE_GROUP:-}"
  local cluster="${AKS_CLUSTER_NAME:-}"

  if [[ -z "${rg}" || -z "${cluster}" ]]; then
    echo "AKS outbound SNAT IP(s): set AZURE_RESOURCE_GROUP and AKS_CLUSTER_NAME in .env to print"
    return 0
  fi

  if ! command -v az >/dev/null 2>&1; then
    echo "AKS outbound SNAT IP(s): install Azure CLI (az) to print"
    return 0
  fi

  if ! az aks show --resource-group "${rg}" --name "${cluster}" >/dev/null 2>&1; then
    echo "AKS outbound SNAT IP(s): cluster ${cluster} not found in ${rg}"
    return 0
  fi

  local -a ip_ids=()
  local id
  while IFS= read -r id; do
    [[ -n "${id}" ]] && ip_ids+=("${id}")
  done < <(az aks show \
    --resource-group "${rg}" \
    --name "${cluster}" \
    --query "networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id" \
    -o tsv 2>/dev/null || true)

  if ((${#ip_ids[@]} == 0)); then
    local node_rg
    node_rg="$(az aks show --resource-group "${rg}" --name "${cluster}" --query nodeResourceGroup -o tsv)"
    while IFS= read -r id; do
      [[ -n "${id}" ]] && ip_ids+=("${id}")
    done < <(az network public-ip list \
      --resource-group "${node_rg}" \
      --query "[].id" \
      -o tsv 2>/dev/null || true)
  fi

  if ((${#ip_ids[@]} == 0)); then
    echo "AKS outbound SNAT IP(s): none found (check Azure Portal → AKS → Networking)"
    return 0
  fi

  echo "AKS outbound SNAT IP(s) — allow inbound on Splunk/on-prem firewall:"
  local ip
  for id in "${ip_ids[@]}"; do
    ip="$(az network public-ip show --ids "${id}" --query ipAddress -o tsv 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      echo "  ${ip}"
    fi
  done
  cat <<EOF
  Ports from EP pods (via SNAT):
    TCP 8089       OpAMP + package download (DMX_HOST)
    TCP 9997       S2S data export
    TCP 443 or 8088 HEC export (port depends on HEC destination)
EOF
}

print_aks_snat_ips

cat <<EOF

Re-run anytime after redeploy:
  ./scripts/show-ep-endpoints.sh ${NAMESPACE} ${SERVICE}

EOF
