#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <configmap-key> <group-guid> [namespace] [configmap-name]"
  echo ""
  echo "Create ConfigMap manually when the Splunk API returns no groups."
  echo ""
  echo "Get the group GUID from Splunk UI:"
  echo "  Data Management → Edge Processor → open your processor → Manage instances"
  echo ""
  echo "Example:"
  echo "  $0 EP_CORP_DC_1 d81d22ae-6913-4ccf-a7d1-4afa6c7081bd"
  exit 1
fi

KEY="$1"
GUID="$2"
NAMESPACE="${3:-splunk-edge}"
CONFIGMAP_NAME="${4:-ep-instance-guids}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap "${CONFIGMAP_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal="${KEY}=${GUID}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ConfigMap ${CONFIGMAP_NAME} created with key ${KEY}"
kubectl get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" -o yaml
