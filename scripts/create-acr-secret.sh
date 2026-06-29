#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_ep_env "${ROOT_DIR}"

ACR_NAME="${1:-${ACR_NAME:-}}"
NAMESPACE="${2:-splunk-edge}"
SECRET_NAME="${3:-acr-pull-secret}"

usage() {
  cat <<EOF
Usage: $0 [acr-name] [namespace] [secret-name]

Create a Kubernetes pull secret for Azure Container Registry.

Enables the ACR admin user and stores credentials in secret ${SECRET_NAME}.
This is the only supported way for AKS to pull images from your private ACR.

With no arguments, reads ACR_NAME from .env.

Example:
  $0
  $0 epaksacr splunk-edge acr-pull-secret
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${ACR_NAME}" ]]; then
  echo "ERROR: ACR name required (set ACR_NAME in .env or pass as argument)" >&2
  usage >&2
  exit 1
fi

LOGIN_SERVER="$(ep_acr_login_server)"

echo "Enabling ACR admin user on ${ACR_NAME}"
az acr update -n "${ACR_NAME}" --admin-enabled true -o none

ACR_USER="$(az acr credential show -n "${ACR_NAME}" --query username -o tsv)"
ACR_PASS="$(az acr credential show -n "${ACR_NAME}" --query 'passwords[0].value' -o tsv)"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${LOGIN_SERVER}" \
  --docker-username="${ACR_USER}" \
  --docker-password="${ACR_PASS}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Created secret ${SECRET_NAME} in namespace ${NAMESPACE} for ${LOGIN_SERVER}"
