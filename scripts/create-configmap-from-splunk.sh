#!/usr/bin/env bash
set -euo pipefail

INSECURE=false
DEBUG=false

if [[ "${DMX_INSECURE:-false}" == "true" ]]; then
  INSECURE=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --insecure)
      INSECURE=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 [--insecure] [--debug] <dmx-control-plane-host> <bearer-token> [namespace] [configmap-name]"
  echo ""
  echo "Use --insecure for self-signed TLS on the control plane."
  echo "Use --debug to print the raw API response."
  echo ""
  echo "If API returns no groups, create an Edge Processor in Splunk UI first,"
  echo "or set the GUID manually in k8s/configmap.example.yaml"
  exit 1
fi

DMX_HOST="$1"
TOKEN="$2"
NAMESPACE="${3:-splunk-edge}"
CONFIGMAP_NAME="${4:-ep-instance-guids}"

CURL_OPTS=(-sS)
if [[ "${INSECURE}" == "true" ]]; then
  CURL_OPTS+=(-k)
  echo "WARNING: TLS verification disabled (self-signed / untrusted certificate)."
fi

trim_token="$(echo -n "${TOKEN}" | tr -d '[:space:]')"
if [[ "${trim_token}" == ghp_* || "${trim_token}" == github_pat_* ]]; then
  echo "ERROR: This looks like a GitHub token (ghp_/github_pat_), not a Splunk token."
  echo "Use a Splunk Bearer token from:"
  echo "  https://${DMX_HOST}/en-US/manager/splunk_pipeline_builders/authorization/tokens"
  exit 1
fi
TOKEN="${trim_token}"

API_URL="https://${DMX_HOST}:8089/servicesNS/-/splunk_pipeline_builders/edge/v1alpha3/processors"

TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

echo "Fetching Edge Processor groups from: ${API_URL}"

HTTP_CODE="$(curl "${CURL_OPTS[@]}" -o "${TMP_FILE}" -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json" \
  "${API_URL}")"

if [[ "${HTTP_CODE}" == "401" || "${HTTP_CODE}" == "403" ]]; then
  echo "ERROR: Splunk returned HTTP ${HTTP_CODE} (authentication failed)."
  echo "Response:"
  cat "${TMP_FILE}"
  echo ""
  echo "Fix: create a NEW Splunk token on the control plane and test with:"
  echo "  ./scripts/test-splunk-token.sh --insecure ${DMX_HOST} \"<splunk-token>\""
  exit 1
fi

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: Splunk returned HTTP ${HTTP_CODE}"
  cat "${TMP_FILE}"
  exit 1
fi

if [[ "${DEBUG}" == "true" ]]; then
  echo "--- API response ---"
  cat "${TMP_FILE}"
  echo "--- end response ---"
fi

# Normalize Splunk REST / JSON shapes into name=id pairs
PAIRS_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}" "${PAIRS_FILE}"' EXIT

jq -r '
  def as_list:
    if type == "array" then .
    elif (.entries? | type) == "array" then [.entries[].content]
    elif (.processors? | type) == "array" then .processors
    elif (.data? | type) == "array" then .data
    else [] end;

  as_list
  | map(
      (.name // .title // .processorName // .displayName // empty) as $name
      | (.id // .groupId // .processorId // .uuid // empty) as $id
      | if ($name != "" and $id != "") then "\($name)=\($id)" else empty end
    )
  | .[]
' "${TMP_FILE}" > "${PAIRS_FILE}"

LITERALS=()
while IFS='=' read -r key value; do
  [[ -n "${key}" && -n "${value}" ]] || continue
  LITERALS+=(--from-literal="${key}=${value}")
done < "${PAIRS_FILE}"

if [[ ${#LITERALS[@]} -eq 0 ]]; then
  echo ""
  echo "No Edge Processor groups found in API response."
  echo ""
  if [[ "${DEBUG}" != "true" ]]; then
    echo "Raw response (first 2000 chars):"
    head -c 2000 "${TMP_FILE}"
    echo ""
  fi
  echo "Common causes:"
  echo "  1. No Edge Processor created yet in Splunk UI (Data Management → Edge Processor → create one)"
  echo "  2. Token lacks permission — create token on the control plane with admin access"
  echo "  3. Wrong hostname — use the same host as Splunk UI / Manage instances"
  echo "  4. Wrong token type — use a Splunk Bearer token, not a GitHub PAT"
  echo ""
  echo "Manual fix — copy group GUID from Splunk UI → Manage instances, then:"
  echo "  ./scripts/create-configmap-manual.sh EP_CORP_DC_1 <your-group-guid>"
  exit 1
fi

echo "Found Edge Processor groups:"
cat "${PAIRS_FILE}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap "${CONFIGMAP_NAME}" \
  --namespace "${NAMESPACE}" \
  "${LITERALS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "ConfigMap ${CONFIGMAP_NAME} updated in namespace ${NAMESPACE}"
kubectl get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}"
