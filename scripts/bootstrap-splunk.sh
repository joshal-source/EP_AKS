#!/usr/bin/env bash
# Local bootstrap only — do NOT commit tokens into this file.
# Usage:
#   export DMX_HOST=ec2-3-138-156-139.us-east-2.compute.amazonaws.com
#   export SPLUNK_TOKEN='eyJ...'
#   export EP_CONFIG_KEY=EP_CORP_DC_1          # optional, default EP_CORP_DC_1
#   export EP_GROUP_GUID=                    # optional if API returns groups
#   ./scripts/bootstrap-splunk.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DMX_HOST="${DMX_HOST:-ec2-3-138-156-139.us-east-2.compute.amazonaws.com}"
EP_CONFIG_KEY="${EP_CONFIG_KEY:-EP_CORP_DC_1}"

if [[ -z "${SPLUNK_TOKEN:-}" ]]; then
  echo "Set SPLUNK_TOKEN first, e.g.:"
  echo "  export SPLUNK_TOKEN='eyJ...'"
  exit 1
fi

echo "DMX_HOST: ${DMX_HOST}"
echo "Creating Splunk token secret..."
"${SCRIPT_DIR}/create-secret.sh" "${SPLUNK_TOKEN}"

if [[ -n "${EP_GROUP_GUID:-}" ]]; then
  echo "Creating ConfigMap manually (key=${EP_CONFIG_KEY})..."
  "${SCRIPT_DIR}/create-configmap-manual.sh" "${EP_CONFIG_KEY}" "${EP_GROUP_GUID}"
else
  echo "Fetching Edge Processor groups from Splunk API..."
  if "${SCRIPT_DIR}/create-configmap-from-splunk.sh" --insecure "${DMX_HOST}" "${SPLUNK_TOKEN}"; then
    echo "ConfigMap created from API."
  else
    echo ""
    echo "API returned no groups. Create an Edge Processor in Splunk UI, then either:"
    echo "  export EP_GROUP_GUID=<guid-from-manage-instances>"
    echo "  ./scripts/bootstrap-splunk.sh"
    echo ""
    echo "Or: ./scripts/create-configmap-manual.sh ${EP_CONFIG_KEY} <guid>"
    exit 1
  fi
fi

echo ""
echo "Applying Kubernetes manifests..."
kubectl apply -f "${ROOT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/deployment.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/service.yaml"

echo ""
kubectl get pods,svc -n splunk-edge
echo ""
echo "Watch pods: kubectl get pods -n splunk-edge -w"
echo "Logs:       kubectl logs -n splunk-edge -l app=ep -f"
