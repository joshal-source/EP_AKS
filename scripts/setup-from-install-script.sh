#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM_VALUES_INSTALL="${ROOT_DIR}/helm/edge-processor/values-install.yaml"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_ep_env "${ROOT_DIR}"

# shellcheck source=lib/parse-install-script.sh
source "${SCRIPT_DIR}/lib/parse-install-script.sh"
# shellcheck source=lib/write-helm-values.sh
source "${SCRIPT_DIR}/lib/write-helm-values.sh"

usage() {
  cat <<EOF
Usage: $0 <install-script.txt> [options]

Parse the Splunk Edge Processor install script and deploy via Helm.

Options:
  --apply              Write Helm values and deploy (default: plan only)
  --namespace NAME     Kubernetes namespace (default: splunk-edge)
  --group-key KEY      ConfigMap key for GROUP_ID (default: EP_INSTANCE)
  --image IMAGE        Override container image (repo:tag)
  --skip-deploy        Write values-install.yaml only; do not helm upgrade
  -h, --help           Show this help

Examples:
  $0 install-script.txt
  $0 install-script.txt --apply

Prerequisites:
  - kubectl + helm configured for your AKS cluster
  - ACR_NAME in .env, image pushed (./scripts/build-local.sh --push)
  - acr-pull-secret (./scripts/create-acr-secret.sh — auto-refreshed on deploy)
  - Optional sizing: copy helm/edge-processor/values-local.yaml.example to values-local.yaml
EOF
}

NAMESPACE="splunk-edge"
GROUP_KEY="EP_INSTANCE"
IMAGE_OVERRIDE=""
APPLY=false
SKIP_DEPLOY=false
INSTALL_SCRIPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --namespace)
      NAMESPACE="${2:?--namespace requires a value}"
      shift 2
      ;;
    --group-key)
      GROUP_KEY="${2:?--group-key requires a value}"
      shift 2
      ;;
    --image)
      IMAGE_OVERRIDE="${2:?--image requires a value}"
      shift 2
      ;;
    --skip-deploy)
      SKIP_DEPLOY=true
      shift
      ;;
    --skip-k8s-apply)
      SKIP_DEPLOY=true
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

parse_install_script "${INSTALL_SCRIPT}"
validate_parsed_install_script

if [[ -z "${IMAGE_OVERRIDE:-}" && -n "${ACR_NAME:-}" ]]; then
  IMAGE_OVERRIDE="$(ep_acr_image)"
fi

echo ""
print_parsed_install_script
echo ""

write_helm_values_from_install_script "${HELM_VALUES_INSTALL}"

deploy_with_helm() {
  if [[ "${SKIP_DEPLOY}" == "true" ]]; then
    echo "Skipping helm deploy (--skip-deploy)"
    return 0
  fi
  NAMESPACE="${NAMESPACE}" "${SCRIPT_DIR}/helm-deploy.sh" -n "${NAMESPACE}"
}

if [[ "${APPLY}" == "true" ]]; then
  deploy_with_helm
  echo ""
  "${SCRIPT_DIR}/show-ep-endpoints.sh" "${NAMESPACE}" ep-service || true
  echo ""
  echo "Done. Verify instances are Healthy in Splunk UI → Manage instances."
else
  echo ""
  echo "Plan complete (dry run). Generated: ${HELM_VALUES_INSTALL}"
  echo "To deploy:"
  echo "  $0 ${INSTALL_SCRIPT} --apply"
  echo ""
  echo "Customize replicas, CPU, etc.:"
  echo "  cp helm/edge-processor/values-local.yaml.example helm/edge-processor/values-local.yaml"
fi
