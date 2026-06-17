#!/usr/bin/env bash
set -euo pipefail

INSECURE=false
while [[ "${1:-}" == "--insecure" ]]; do
  INSECURE=true
  shift
done

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 [--insecure] <dmx-host> <splunk-bearer-token>"
  echo ""
  echo "Tests Splunk API authentication before creating ConfigMaps."
  echo "Token must be a Splunk token from the control plane — NOT a GitHub ghp_ token."
  exit 1
fi

DMX_HOST="$1"
TOKEN="$2"
CURL_OPTS=(-sS -w "\nHTTP_STATUS:%{http_code}")
if [[ "${INSECURE}" == "true" ]]; then
  CURL_OPTS+=(-k)
  echo "TLS verification disabled."
fi

trim_token="$(echo -n "${TOKEN}" | tr -d '[:space:]')"
if [[ "${trim_token}" == ghp_* || "${trim_token}" == github_pat_* ]]; then
  echo "ERROR: This looks like a GitHub token, not a Splunk token."
  echo "Create a Splunk token at:"
  echo "  https://${DMX_HOST}/en-US/manager/splunk_pipeline_builders/authorization/tokens"
  exit 1
fi

echo "Testing Splunk token against ${DMX_HOST}:8089 ..."
echo ""

test_auth() {
  local label="$1"
  local header="$2"
  local url="$3"
  local body status
  body="$(curl "${CURL_OPTS[@]}" -H "${header}" "${url}" -o /tmp/splunk-test-body.txt)"
  status="${body##*HTTP_STATUS:}"
  echo "[$label] HTTP ${status}"
  if [[ -f /tmp/splunk-test-body.txt ]]; then
    head -c 500 /tmp/splunk-test-body.txt
    echo ""
  fi
  echo ""
  return 0
}

BASE="https://${DMX_HOST}:8089"

test_auth "Bearer token" "Authorization: Bearer ${trim_token}" \
  "${BASE}/services/authentication/current-context?output_mode=json"

test_auth "Splunk prefix" "Authorization: Splunk ${trim_token}" \
  "${BASE}/services/authentication/current-context?output_mode=json"

test_auth "Edge processors API (Bearer)" "Authorization: Bearer ${trim_token}" \
  "${BASE}/servicesNS/-/splunk_pipeline_builders/edge/v1alpha3/processors"

echo "--- If all show 401 ---"
echo "1. Create a NEW Splunk token on the CONTROL PLANE (not indexer/search head):"
echo "   https://${DMX_HOST}/en-US/manager/splunk_pipeline_builders/authorization/tokens"
echo "   Audience: ep-instance (or any). Copy token immediately — shown only once."
echo ""
echo "2. Or create via API (replace admin user/pass):"
echo "   curl -k -u admin:password \\"
echo "     'https://${DMX_HOST}:8089/services/authorization/tokens?output_mode=json' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d 'name=ep-aks-token&audience=ep-instance&expires_on=%2B90d'"
echo ""
echo "3. Ensure Splunk token authentication is enabled on this instance."
echo "4. Re-run secrets with the NEW Splunk token:"
echo "   ./scripts/create-secret.sh \"<new-token>\""
echo "   ./scripts/create-configmap-from-splunk.sh --insecure ${DMX_HOST} \"<new-token>\""

rm -f /tmp/splunk-test-body.txt
