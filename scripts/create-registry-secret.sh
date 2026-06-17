#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <registry-type> <username> <password-or-token> [namespace] [secret-name] [server]"
  echo ""
  echo "Examples:"
  echo "  Docker Hub:"
  echo "    $0 dockerhub myuser mytoken splunk-edge registry-pull-secret"
  echo ""
  echo "  Generic registry (GHCR, Harbor, etc.):"
  echo "    $0 generic myuser mytoken splunk-edge registry-pull-secret ghcr.io"
  echo ""
  echo "For Docker Hub, use an access token (not your login password):"
  echo "  https://hub.docker.com/settings/security"
  exit 1
fi

REGISTRY_TYPE="$1"
USERNAME="$2"
PASSWORD="$3"
NAMESPACE="${4:-splunk-edge}"
SECRET_NAME="${5:-registry-pull-secret}"
SERVER="${6:-}"

case "${REGISTRY_TYPE}" in
  dockerhub)
    SERVER="https://index.docker.io/v1/"
    ;;
  generic)
    if [[ -z "${SERVER}" ]]; then
      echo "Generic registry requires a server host (e.g. ghcr.io)"
      exit 1
    fi
    ;;
  *)
    echo "Unknown registry type: ${REGISTRY_TYPE}. Use dockerhub or generic."
    exit 1
    ;;
esac

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --docker-server="${SERVER}" \
  --docker-username="${USERNAME}" \
  --docker-password="${PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret ${SECRET_NAME} created in namespace ${NAMESPACE}"
echo "Uncomment imagePullSecrets in k8s/deployment.yaml:"
echo "  imagePullSecrets:"
echo "    - name: ${SECRET_NAME}"
