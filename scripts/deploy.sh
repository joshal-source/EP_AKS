#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${ROOT_DIR}/helm/edge-processor/values-install.yaml" ]]; then
  echo "ERROR: helm/edge-processor/values-install.yaml not found." >&2
  echo "Run: ./scripts/setup-from-install-script.sh install-script.txt" >&2
  exit 1
fi

"${SCRIPT_DIR}/helm-deploy.sh" "$@"
"${SCRIPT_DIR}/show-ep-endpoints.sh" "${NAMESPACE:-splunk-edge}" ep-service || true
