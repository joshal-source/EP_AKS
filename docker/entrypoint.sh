#!/usr/bin/env bash
set -euo pipefail

: "${GROUP_ID:?GROUP_ID is required}"
: "${DMX_HOST:?DMX_HOST is required}"
: "${DMX_TOKEN:?DMX_TOKEN is required}"
: "${DMX_ENV:=production}"

WORKDIR="${WORKDIR:-/opt/splunk-edge}"
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
    if [[ ! -f "${WORKDIR}/splunk-edge/var/token" ]]; then
      mkdir -p "${WORKDIR}/splunk-edge/var"
      printf '%s' "${DMX_TOKEN}" > "${WORKDIR}/splunk-edge/var/token"
    fi
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

  log "ERROR: SPLUNK_EDGE_PACKAGE_URL is not set."
  exit 1
}

discover_package_checksum() {
  if [[ -n "${SPLUNK_EDGE_PACKAGE_CHECKSUM:-}" ]]; then
    echo "${SPLUNK_EDGE_PACKAGE_CHECKSUM}"
    return
  fi
  echo ""
}

verify_package_checksum() {
  local checksum="$1"
  local downloaded len

  if [[ -z "${checksum}" || "${checksum}" == "null" ]]; then
    log "WARNING: No checksum available; skipping verification"
    return 0
  fi

  len="${#checksum}"
  if [[ "${len}" -eq 64 ]]; then
    downloaded="$(sha256sum splunk-edge.tar.gz | awk '{print $1}')"
    log "Verifying SHA-256 checksum"
  elif [[ "${len}" -eq 128 ]]; then
    downloaded="$(sha512sum splunk-edge.tar.gz | awk '{print $1}')"
    log "Verifying SHA-512 checksum"
  else
    log "WARNING: Checksum length ${len} is unexpected; skipping verification"
    return 0
  fi

  if [[ "${downloaded}" != "${checksum}" ]]; then
    log "ERROR: Package checksum mismatch."
    exit 1
  fi

  log "Package checksum verified"
}

write_config_yaml() {
  cat > ./splunk-edge/etc/config.yaml <<EOF
url: https://${DMX_HOST}:8089/servicesNS/nobody/splunk_pipeline_builders/tenant/agent-management
groupId: ${GROUP_ID}
env: ${DMX_ENV}
EOF

  if [[ "${DMX_INSECURE:-false}" == "true" ]]; then
    cat >> ./splunk-edge/etc/config.yaml <<EOF
settings:
  disableServerCertValidation: true
EOF
  fi
}

install_edge_processor() {
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  local package_url checksum
  package_url="$(discover_package_url)"
  checksum="$(discover_package_checksum)"

  if [[ "${package_url}" == http://* ]]; then
    package_url="https://${package_url#http://}"
    log "Using HTTPS for package download"
  fi

  log "Downloading Edge Processor package from ${package_url}"
  curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer ${DMX_TOKEN}" \
    -o splunk-edge.tar.gz \
    "${package_url}"

  verify_package_checksum "${checksum}"

  tar -xzf splunk-edge.tar.gz
  rm -f splunk-edge.tar.gz

  write_config_yaml

  mkdir -p ./splunk-edge/var
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
