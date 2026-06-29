#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/edge-processor"
VALUES_LOCAL="${CHART_DIR}/values-local.yaml"
VALUES_EXAMPLE="${CHART_DIR}/values-local.yaml.example"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_ep_env "${ROOT_DIR}"

INSTALL_SCRIPT=""
SKIP_BUILD=false

usage() {
  cat <<EOF
Usage: $0 <install-script.txt> [options]

Repeatable deploy: build image locally, push to ACR, refresh pull secret, Helm upgrade.

Safe to run after deleting the local or ACR image, or to roll out config changes.
Does not recreate AKS — run ./scripts/setup-aks.sh once per environment first.

Options:
  --skip-build    Skip docker build/push (image already in ACR)
  -h, --help      Show help

Examples:
  $0 install-script.txt
  $0 install-script.txt --skip-build

Requires .env with ACR_NAME, AZURE_RESOURCE_GROUP, AKS_CLUSTER_NAME, etc.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "${INSTALL_SCRIPT}" ]]; then
        INSTALL_SCRIPT="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "${INSTALL_SCRIPT}" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
  echo "ERROR: install script not found: ${INSTALL_SCRIPT}" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: $1 is not installed." >&2
    exit 1
  fi
}

require_cmd az
require_cmd kubectl
require_cmd helm
require_cmd docker

if [[ -z "${ACR_NAME:-}" ]]; then
  echo "ERROR: set ACR_NAME in .env" >&2
  exit 1
fi

if [[ -z "${AZURE_RESOURCE_GROUP:-}" || -z "${AKS_CLUSTER_NAME:-}" ]]; then
  echo "ERROR: set AZURE_RESOURCE_GROUP and AKS_CLUSTER_NAME in .env" >&2
  exit 1
fi

if ! az aks show -g "${AZURE_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "ERROR: AKS cluster ${AKS_CLUSTER_NAME} not found in ${AZURE_RESOURCE_GROUP}." >&2
  echo "Run first: ./scripts/setup-aks.sh" >&2
  exit 1
fi

echo "Syncing kubectl credentials for ${AKS_CLUSTER_NAME}"
az aks get-credentials \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --name "${AKS_CLUSTER_NAME}" \
  --overwrite-existing

ensure_values_local() {
  local repo tag
  repo="$(ep_acr_repository)"
  tag="${IMAGE_TAG:-latest}"

  if [[ ! -f "${VALUES_LOCAL}" ]]; then
    echo "Creating ${VALUES_LOCAL} from .env"
    if [[ -f "${VALUES_EXAMPLE}" ]]; then
      cp "${VALUES_EXAMPLE}" "${VALUES_LOCAL}"
    else
      cat > "${VALUES_LOCAL}" <<EOF
replicaCount: 2
image:
  repository: ${repo}
  tag: ${tag}
  pullPolicy: IfNotPresent
strategy:
  rollingUpdate:
    maxSurge: 0
    maxUnavailable: 1
EOF
      return 0
    fi
  fi

  if ! grep -q "${repo}" "${VALUES_LOCAL}"; then
    echo "Updating image.repository in ${VALUES_LOCAL} to match .env (${repo})"
    if grep -q '^\s*repository:' "${VALUES_LOCAL}"; then
      sed -i.bak -E "s|^([[:space:]]*repository:).*|\1 ${repo}|" "${VALUES_LOCAL}"
      rm -f "${VALUES_LOCAL}.bak"
    fi
  fi

  if grep -q '^\s*tag:' "${VALUES_LOCAL}"; then
    sed -i.bak -E "s|^([[:space:]]*tag:).*|\1 ${tag}|" "${VALUES_LOCAL}"
    rm -f "${VALUES_LOCAL}.bak"
  fi

  if [[ -n "${EP_STORAGE_SIZE:-}" ]]; then
    if grep -q '^persistence:' "${VALUES_LOCAL}" && grep -q '^\s*size:' "${VALUES_LOCAL}"; then
      sed -i.bak -E '/^persistence:/,/^[a-zA-Z]/ s|^([[:space:]]*size:).*|\1 '"${EP_STORAGE_SIZE}"'|' "${VALUES_LOCAL}"
      rm -f "${VALUES_LOCAL}.bak"
    else
      echo "Adding persistence.size ${EP_STORAGE_SIZE} to ${VALUES_LOCAL}"
      cat >> "${VALUES_LOCAL}" <<EOF

persistence:
  enabled: true
  size: ${EP_STORAGE_SIZE}
EOF
    fi
  fi
}

ensure_values_local

if [[ "${SKIP_BUILD}" == "true" ]]; then
  echo "Skipping docker build/push (--skip-build)"
  REMOTE="$(ep_acr_image)"
  if ! az acr repository show -n "${ACR_NAME}" --image "${IMAGE_NAME:-edgeprocessor}:${IMAGE_TAG:-latest}" >/dev/null 2>&1; then
    echo "ERROR: image not found in ACR: ${REMOTE}" >&2
    echo "Run without --skip-build to build and push." >&2
    exit 1
  fi
  echo "Verified image exists in ACR: ${REMOTE}"
else
  echo "Building and pushing image to ACR"
  "${SCRIPT_DIR}/build-local.sh" --push
fi

echo "Refreshing ACR pull secret"
"${SCRIPT_DIR}/create-acr-secret.sh"

sources_file="${NSG_ALLOWED_SOURCES_FILE:-config/nsg-allowed-sources.conf}"
if [[ "${sources_file}" != /* ]]; then
  sources_file="${ROOT_DIR}/${sources_file}"
fi
if [[ -f "${sources_file}" ]]; then
  echo "Refreshing NSG allow rules and LoadBalancer allow-list"
  "${SCRIPT_DIR}/apply-nsg-rules.sh"
fi

echo "Deploying Edge Processor via Helm"
"${SCRIPT_DIR}/setup-from-install-script.sh" "${INSTALL_SCRIPT}" --apply

echo ""
echo "Deploy complete."
