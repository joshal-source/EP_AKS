#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/edge-processor"

RELEASE_NAME="${RELEASE_NAME:-edge-processor}"
NAMESPACE="${NAMESPACE:-splunk-edge}"
WAIT="${WAIT:-true}"
TIMEOUT="${TIMEOUT:-10m}"

usage() {
  cat <<EOF
Usage: $0 [options]

Install or upgrade Edge Processor via Helm.

Options:
  -f, --values FILE    Additional values file (repeatable)
  -n, --namespace NS   Kubernetes namespace (default: splunk-edge)
  --no-wait            Do not wait for rollout
  -h, --help           Show help

Default value files (first found wins for overlapping keys, later files override):
  helm/edge-processor/values.yaml
  helm/edge-processor/values-local.yaml   (optional, your overrides)
  helm/edge-processor/values-install.yaml (optional, from install script)

Examples:
  $0
  $0 -f helm/edge-processor/values-local.yaml
  $0 -f helm/edge-processor/values-install.yaml
EOF
}

EXTRA_VALUES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--values)
      EXTRA_VALUES+=("$2")
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --no-wait)
      WAIT=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is not installed. See https://helm.sh/docs/intro/install/" >&2
  exit 1
fi

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"
  set +a
fi

PULL_SECRET_NAME="acr-pull-secret"
if [[ -f "${CHART_DIR}/values-local.yaml" ]]; then
  pull_from_local="$(grep -E '^\s*- name:' "${CHART_DIR}/values-local.yaml" | head -1 | sed -E 's/.*name:[[:space:]]*//' || true)"
  if [[ -n "${pull_from_local}" ]]; then
    PULL_SECRET_NAME="${pull_from_local}"
  fi
elif grep -qE '^\s*- name: acr-pull-secret' "${CHART_DIR}/values.yaml" 2>/dev/null; then
  PULL_SECRET_NAME="acr-pull-secret"
fi

if [[ -n "${ACR_NAME:-}" ]]; then
  ACR_NAME="${ACR_NAME}" NAMESPACE="${NAMESPACE}" "${SCRIPT_DIR}/create-acr-secret.sh" "${ACR_NAME}" "${NAMESPACE}" "${PULL_SECRET_NAME}"
elif ! kubectl get secret "${PULL_SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: ${PULL_SECRET_NAME} not found in namespace ${NAMESPACE}." >&2
  echo "Set ACR_NAME in .env and run: ./scripts/create-acr-secret.sh" >&2
  exit 1
fi

VALUES_ARGS=(-f "${CHART_DIR}/values.yaml")

if [[ -f "${CHART_DIR}/values-local.yaml" ]]; then
  VALUES_ARGS+=(-f "${CHART_DIR}/values-local.yaml")
fi

if [[ -f "${CHART_DIR}/values-install.yaml" ]]; then
  VALUES_ARGS+=(-f "${CHART_DIR}/values-install.yaml")
fi

if ((${#EXTRA_VALUES[@]} > 0)); then
  for v in "${EXTRA_VALUES[@]}"; do
    VALUES_ARGS+=(-f "${v}")
  done
fi

HELM_ARGS=(
  upgrade --install "${RELEASE_NAME}" "${CHART_DIR}"
  "${VALUES_ARGS[@]}"
  --namespace "${NAMESPACE}"
  --create-namespace
)

if [[ "${WAIT}" == "true" ]]; then
  HELM_ARGS+=(--wait --timeout "${TIMEOUT}")
fi

HELM_ARGS+=(--set "namespace=${NAMESPACE}")

echo "Running: helm ${HELM_ARGS[*]}"
helm "${HELM_ARGS[@]}"

echo ""
kubectl get pods,svc -n "${NAMESPACE}"
