#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <dmx-control-plane-host> <bearer-token> [namespace] [configmap-name]"
  echo "Example: $0 splunk-cp.example.com eyJraWQi... splunk-edge ep-instance-guids"
  exit 1
fi

DMX_HOST="$1"
TOKEN="$2"
NAMESPACE="${3:-splunk-edge}"
CONFIGMAP_NAME="${4:-ep-instance-guids}"

TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

curl -fsSL \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://${DMX_HOST}:8089/servicesNS/-/splunk_pipeline_builders/edge/v1alpha3/processors" \
  -o "${TMP_FILE}"

if ! jq -e 'type == "array"' "${TMP_FILE}" >/dev/null 2>&1; then
  echo "Unexpected API response. Save response to inspect:"
  cat "${TMP_FILE}"
  exit 1
fi

LITERALS=()
while IFS='=' read -r key value; do
  [[ -n "${key}" && -n "${value}" ]] || continue
  LITERALS+=(--from-literal="${key}=${value}")
done < <(jq -r '.[] | "\(.name)=\(.id)"' "${TMP_FILE}")

if [[ ${#LITERALS[@]} -eq 0 ]]; then
  echo "No Edge Processor groups returned from API."
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap "${CONFIGMAP_NAME}" \
  --namespace "${NAMESPACE}" \
  "${LITERALS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ConfigMap ${CONFIGMAP_NAME} updated in namespace ${NAMESPACE}"
kubectl get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" -o yaml
