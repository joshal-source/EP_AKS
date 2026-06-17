#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <install-script.txt>"
  echo ""
  echo "Paste the install script from Splunk UI:"
  echo "  Edge Processor → Manage instances → Install tab → copy script to a file"
  echo ""
  echo "Then run this script to print deployment env vars."
  exit 1
fi

SCRIPT_FILE="$1"
if [[ ! -f "${SCRIPT_FILE}" ]]; then
  echo "File not found: ${SCRIPT_FILE}"
  exit 1
fi

PACKAGE_URL="$(grep -oE 'https?://[^"[:space:]]+splunk-edge\.tar\.gz' "${SCRIPT_FILE}" | head -1)"
CHECKSUM="$(grep -oE '"[0-9a-f]{64}"' "${SCRIPT_FILE}" | tr -d '"' | head -1)"
if [[ -z "${CHECKSUM}" ]]; then
  CHECKSUM="$(grep -oE '"[0-9a-f]{128}"' "${SCRIPT_FILE}" | tr -d '"' | head -1)"
fi

if [[ -z "${PACKAGE_URL}" ]]; then
  echo "Could not find splunk-edge.tar.gz URL in ${SCRIPT_FILE}"
  echo "Look for a line like:"
  echo "  curl \"https://.../splunk-edge.tar.gz\" -O"
  exit 1
fi

echo "Add these to k8s/deployment.yaml under the container env section:"
echo ""
echo "            - name: SPLUNK_EDGE_PACKAGE_URL"
echo "              value: \"${PACKAGE_URL}\""
if [[ -n "${CHECKSUM}" ]]; then
  echo "            - name: SPLUNK_EDGE_PACKAGE_CHECKSUM"
  echo "              value: \"${CHECKSUM}\""
else
  echo "# (checksum not found in script — optional but recommended)"
fi
echo ""
echo "Then apply:"
echo "  kubectl apply -f k8s/deployment.yaml"
echo "  kubectl rollout restart deployment/ep-deployment -n splunk-edge"
