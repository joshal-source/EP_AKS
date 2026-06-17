#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <dmx-token> [namespace] [secret-name]"
  echo "Example: $0 eyJraWQi... splunk-edge edge-processor-secrets"
  exit 1
fi

TOKEN="$1"
NAMESPACE="${2:-splunk-edge}"
SECRET_NAME="${3:-edge-processor-secrets}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=token="${TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret ${SECRET_NAME} updated in namespace ${NAMESPACE}"
