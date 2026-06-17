#!/usr/bin/env bash
set -euo pipefail

: "${GROUP_ID:?GROUP_ID is required}"
: "${DMX_HOST:?DMX_HOST is required}"
: "${DMX_TOKEN:?DMX_TOKEN is required}"
: "${DMX_ENV:=production}"

WORKDIR="${WORKDIR:-/opt/splunk-edge}"
ARCH="${SPLUNK_EDGE_ARCH:-linux-amd64}"
CURL_OPTS=(-fsSL)
if [[ "${DMX_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

cleanup() {
  log "Shutdown signal received; offboarding Edge Processor instance"
  if [[ -d "${WORKDIR}/splunk-edge/bin" ]]; then
    cd "${WORKDIR}"
    if pid="$(pidof splunk-edge 2>/dev/null || true)"; then
      kill "${pid}" || true
      wait "${pid}" 2>/dev/null || true
    fi
    if [[ -x "${WORKDIR}/splunk-edge/bin/splunk-edge" ]]; then
      "${WORKDIR}/splunk-edge/bin/splunk-edge" offboard || true
    fi
  fi
  exit 0
}

trap cleanup SIGTERM SIGINT

discover_package_url() {
  if [[ -n "${SPLUNK_EDGE_PACKAGE_URL:-}" ]]; then
    echo "${SPLUNK_EDGE_PACKAGE_URL}"
    return
  fi

  local metadata_url="https://${DMX_HOST}:8089/servicesNS/-/splunk_pipeline_builders/dmx/packages/splunk-edge"
  local response
  response="$(curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer ${DMX_TOKEN}" \
    "${metadata_url}" || true)"

  if [[ -z "${response}" ]]; then
    log "ERROR: Could not discover package URL from control plane."
    log "Set SPLUNK_EDGE_PACKAGE_URL from the Manage instances install script in Splunk UI."
    exit 1
  fi

  local package_url
  package_url="$(echo "${response}" | jq -r --arg arch "${ARCH}" '
    if type == "array" then .
    elif has("entries") then .entries
    elif has("packages") then .packages
    else . end
    | map(select((.arch // .platform // "linux-amd64") == $arch or (.name // "" | test($arch))))
    | sort_by(.version // .createdAt // .name // "")
    | last
    | .url // .downloadUrl // .href // empty
  ')"

  if [[ -z "${package_url}" || "${package_url}" == "null" ]]; then
    log "ERROR: Package discovery did not return a download URL."
    log "Copy the splunk-edge.tar.gz URL from Manage instances and set SPLUNK_EDGE_PACKAGE_URL."
    exit 1
  fi

  if [[ "${package_url}" != http* ]]; then
    package_url="https://${DMX_HOST}:8089${package_url}"
  fi

  echo "${package_url}"
}

discover_package_checksum() {
  if [[ -n "${SPLUNK_EDGE_PACKAGE_CHECKSUM:-}" ]]; then
    echo "${SPLUNK_EDGE_PACKAGE_CHECKSUM}"
    return
  fi

  local metadata_url="https://${DMX_HOST}:8089/servicesNS/-/splunk_pipeline_builders/dmx/packages/splunk-edge"
  local response
  response="$(curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer ${DMX_TOKEN}" \
    "${metadata_url}" || true)"

  echo "${response}" | jq -r --arg arch "${ARCH}" '
    if type == "array" then .
    elif has("entries") then .entries
    elif has("packages") then .packages
    else . end
    | map(select((.arch // .platform // "linux-amd64") == $arch or (.name // "" | test($arch))))
    | sort_by(.version // .createdAt // .name // "")
    | last
    | .checksum // .sha512 // empty
  '
}

install_edge_processor() {
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  local package_url checksum downloaded_checksum
  package_url="$(discover_package_url)"
  checksum="$(discover_package_checksum)"

  log "Downloading Edge Processor package"
  curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer ${DMX_TOKEN}" \
    -o splunk-edge.tar.gz \
    "${package_url}"

  if [[ -n "${checksum}" && "${checksum}" != "null" ]]; then
    downloaded_checksum="$(sha512sum splunk-edge.tar.gz | awk '{print $1}')"
    if [[ "${downloaded_checksum}" != "${checksum}" ]]; then
      log "ERROR: Package checksum mismatch."
      exit 1
    fi
    log "Package checksum verified"
  else
    log "WARNING: No checksum available; skipping verification"
  fi

  tar -xzf splunk-edge.tar.gz
  rm -f splunk-edge.tar.gz

  cat > ./splunk-edge/etc/config.yaml <<EOF
url: https://${DMX_HOST}:8089/servicesNS/nobody/splunk_pipeline_builders/tenant/agent-management
groupId: ${GROUP_ID}
env: ${DMX_ENV}
EOF

  printf '%s' "${DMX_TOKEN}" > ./splunk-edge/var/token
  mkdir -p ./splunk-edge/var/log

  log "Starting splunk-edge bootstrap"
  nohup ./splunk-edge/bin/splunk-edge run \
    >> ./splunk-edge/var/log/install-splunk-edge.out 2>&1 </dev/null &
}

wait_for_edge_processor() {
  local pid
  pid="$(pidof splunk-edge || true)"
  if [[ -z "${pid}" ]]; then
    log "ERROR: splunk-edge process did not start"
    tail -n 50 "${WORKDIR}/splunk-edge/var/log/install-splunk-edge.out" || true
    exit 1
  fi

  log "splunk-edge running with pid ${pid}"
  wait "${pid}"
}

install_edge_processor
wait_for_edge_processor
