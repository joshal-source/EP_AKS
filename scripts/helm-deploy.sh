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

if ! kubectl get secret registry-pull-secret -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: secret registry-pull-secret not found in namespace ${NAMESPACE}." >&2
  echo "Create it first: ./scripts/create-ghcr-secret.sh <github-user> <ghp-token>" >&2
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
kubectl get pods,svc,hpa -n "${NAMESPACE}"
