#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-splunk-edge}"
SERVICE="${2:-ep-service}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"

usage() {
  cat <<EOF
Usage: $0 [namespace] [service-name]

Print public HEC and S2S endpoints for the Edge Processor LoadBalancer.

Environment:
  WAIT_SECONDS   Max seconds to wait for EXTERNAL-IP (default: 300)

Example:
  $0
  $0 splunk-edge ep-service
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! kubectl get svc "${SERVICE}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Service ${SERVICE} not found in namespace ${NAMESPACE}" >&2
  echo "Deploy first: ./scripts/setup-from-install-script.sh install-script.txt --apply" >&2
  exit 1
fi

get_external_ip() {
  kubectl get svc "${SERVICE}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}'
}

echo "Waiting for LoadBalancer external IP on ${SERVICE} (up to ${WAIT_SECONDS}s)..."
deadline=$((SECONDS + WAIT_SECONDS))
external_ip=""

while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  external_ip="$(get_external_ip || true)"
  if [[ -n "${external_ip}" && "${external_ip}" != "<pending>" ]]; then
    break
  fi
  external_ip=""
  sleep 5
done

if [[ -z "${external_ip}" ]]; then
  echo ""
  echo "EXTERNAL-IP is still pending. Check status with:"
  echo "  kubectl get svc ${SERVICE} -n ${NAMESPACE} -w"
  echo "  kubectl describe svc ${SERVICE} -n ${NAMESPACE}"
  exit 1
fi

hec_port="$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="hec")].port}')"
s2s_port="$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[?(@.name=="s2s")].port}')"
hec_port="${hec_port:-8088}"
s2s_port="${s2s_port:-9997}"

cat <<EOF

Edge Processor public endpoints (${NAMESPACE}/${SERVICE}):
  HEC:  http://${external_ip}:${hec_port}/services/collector/event
  S2S:  ${external_ip}:${s2s_port}

Send a test HEC event (use your HEC token from Splunk UI — not the install-script JWT):

  curl "http://${external_ip}:${hec_port}/services/collector/event" \\
    -H "Authorization: Splunk <your-hec-token>" \\
    -H "Content-Type: application/json" \\
    -d '{"event":"ep deploy test","sourcetype":"ep_aks_test"}'

Re-run anytime after redeploy:
  ./scripts/show-ep-endpoints.sh ${NAMESPACE} ${SERVICE}

EOF
