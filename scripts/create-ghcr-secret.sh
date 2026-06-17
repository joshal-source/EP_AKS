#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <github-username-or-org> <github-pat> [namespace] [secret-name]"
  echo ""
  echo "Creates a Kubernetes pull secret for GitHub Container Registry (ghcr.io)."
  echo ""
  echo "PAT scopes required: read:packages"
  echo "Create at: https://github.com/settings/tokens"
  echo ""
  echo "Example:"
  echo "  $0 myusername ghp_xxxxxxxx splunk-edge registry-pull-secret"
  exit 1
fi

GITHUB_USER="$1"
GITHUB_PAT="$2"
NAMESPACE="${3:-splunk-edge}"
SECRET_NAME="${4:-registry-pull-secret}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/create-registry-secret.sh" \
  generic "${GITHUB_USER}" "${GITHUB_PAT}" "${NAMESPACE}" "${SECRET_NAME}" "ghcr.io"

echo ""
echo "Update k8s/deployment.yaml:"
echo "  image: ghcr.io/${GITHUB_USER}/edgeprocessor:latest"
echo "  imagePullSecrets:"
echo "    - name: ${SECRET_NAME}"
