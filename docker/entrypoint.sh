#!/usr/bin/env bash
set -euo pipefail

: "${GROUP_ID:?GROUP_ID is required}"
: "${DMX_HOST:?DMX_HOST is required}"
: "${DMX_TOKEN:?DMX_TOKEN is required}"
: "${DMX_ENV:=production}"

WORKDIR="${WORKDIR:-/opt/splunk-edge}"
MGMT_PORT="${MGMT_PORT:-8089}"
MGMT_PROXY_ENABLED="${MGMT_PROXY_ENABLED:-false}"
PROXY_CERT_DIR="${PROXY_CERT_DIR:-/tmp/splunk-mgmt-proxy}"
CURL_OPTS=(-fsSL)
if [[ "${DMX_INSECURE:-false}" == "true" ]]; then
  CURL_OPTS+=(-k)
fi

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

cleanup() {
  log "Shutdown signal received; offboarding Edge Processor instance"
  if [[ -n "${MGMT_PROXY_PID:-}" ]]; then
    kill "${MGMT_PROXY_PID}" 2>/dev/null || true
  fi
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

resolve_upstream_ip() {
  UPSTREAM_IP="$(getent ahostsv4 "${DMX_HOST}" | awk 'NR==1 {print $1}')"
  if [[ -z "${UPSTREAM_IP}" ]]; then
    log "ERROR: Could not resolve ${DMX_HOST}"
    exit 1
  fi
  export UPSTREAM_IP
}

start_https_rewrite_proxy() {
  mkdir -p "${PROXY_CERT_DIR}"
  if [[ ! -f "${PROXY_CERT_DIR}/proxy.crt" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "${PROXY_CERT_DIR}/proxy.key" \
      -out "${PROXY_CERT_DIR}/proxy.crt" \
      -subj "/CN=${DMX_HOST}" \
      -addext "subjectAltName=DNS:${DMX_HOST}" 2>/dev/null
  fi

  if ! grep -q "[[:space:]]${DMX_HOST}$" /etc/hosts; then
    printf '127.0.0.1 %s\n' "${DMX_HOST}" >> /etc/hosts
  fi

  export PROXY_CERT="${PROXY_CERT_DIR}/proxy.crt"
  export PROXY_KEY="${PROXY_CERT_DIR}/proxy.key"
  export MGMT_PROXY_PORT="${MGMT_PORT}"

  log "Starting TLS rewrite proxy on 127.0.0.1:${MGMT_PORT} -> ${UPSTREAM_IP}:${MGMT_PORT}"
  python3 /mgmt-proxy.py &
  MGMT_PROXY_PID=$!
  sleep 1
  if ! kill -0 "${MGMT_PROXY_PID}" 2>/dev/null; then
    log "ERROR: mgmt proxy failed to start"
    exit 1
  fi
}

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
    return 0
  fi

  if [[ "${downloaded}" != "${checksum}" ]]; then
    log "ERROR: Package checksum mismatch."
    exit 1
  fi
  log "Package checksum verified"
}

mgmt_base_url() {
  printf 'https://%s:%s/servicesNS/nobody/splunk_pipeline_builders/tenant/agent-management' \
    "${DMX_HOST}" "${MGMT_PORT}"
}

write_config_yaml() {
  cat > ./splunk-edge/etc/config.yaml <<EOF
url: $(mgmt_base_url)
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

download_edge_package() {
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  local package_url checksum
  package_url="$(discover_package_url)"
  checksum="$(discover_package_checksum)"

  if [[ "${package_url}" == http://* ]]; then
    package_url="https://${package_url#http://}"
  fi

  log "Downloading Edge Processor package from ${package_url}"
  curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer ${DMX_TOKEN}" \
    -H "Host: ${DMX_HOST}" \
    --resolve "${DMX_HOST}:${MGMT_PORT}:${UPSTREAM_IP}" \
    -o splunk-edge.tar.gz \
    "${package_url}"

  verify_package_checksum "${checksum}"
  tar -xzf splunk-edge.tar.gz
  rm -f splunk-edge.tar.gz
}

start_splunk_edge() {
  cd "${WORKDIR}"
  write_config_yaml
  mkdir -p ./splunk-edge/var
  printf '%s' "${DMX_TOKEN}" > ./splunk-edge/var/token
  mkdir -p ./splunk-edge/var/log
  log "Starting splunk-edge bootstrap (proxy=${MGMT_PROXY_ENABLED})"
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

resolve_upstream_ip
download_edge_package
if [[ "${MGMT_PROXY_ENABLED}" == "true" ]]; then
  start_https_rewrite_proxy
else
  log "Direct HTTPS to ${DMX_HOST}:${MGMT_PORT} (Splunk proxyHostPort test)"
fi
start_splunk_edge
wait_for_edge_processor
