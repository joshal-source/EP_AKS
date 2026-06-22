# Shared parser for Splunk Edge Processor install scripts from the Splunk UI.
# Source this file or run via setup-from-install-script.sh

parse_install_script() {
  local script_file="${1:?install script path required}"

  if [[ ! -f "${script_file}" ]]; then
    echo "Install script not found: ${script_file}" >&2
    return 1
  fi

  PACKAGE_URL=""
  SPLUNK_EDGE_PACKAGE_CHECKSUM=""
  GROUP_ID=""
  DMX_ENV=""
  DMX_HOST=""
  DMX_TOKEN=""
  DMX_INSECURE="false"
  MGMT_PROXY_ENABLED="true"

  PACKAGE_URL="$(grep -oE 'https?://[^"[:space:]]+splunk-edge\.tar\.gz' "${script_file}" | head -1 || true)"

  SPLUNK_EDGE_PACKAGE_CHECKSUM="$(grep -oE '!= "[0-9a-f]{64}"' "${script_file}" | grep -oE '[0-9a-f]{64}' | head -1 || true)"
  if [[ -z "${SPLUNK_EDGE_PACKAGE_CHECKSUM}" ]]; then
    SPLUNK_EDGE_PACKAGE_CHECKSUM="$(grep -oE '"[0-9a-f]{64}"' "${script_file}" | tr -d '"' | head -1 || true)"
  fi
  if [[ -z "${SPLUNK_EDGE_PACKAGE_CHECKSUM}" ]]; then
    SPLUNK_EDGE_PACKAGE_CHECKSUM="$(grep -oE '"[0-9a-f]{128}"' "${script_file}" | tr -d '"' | head -1 || true)"
  fi

  GROUP_ID="$(grep -oE 'groupId: [a-f0-9-]{36}' "${script_file}" | head -1 | awk '{print $2}' || true)"

  DMX_ENV="$(grep -oE 'env: [a-zA-Z0-9_-]+' "${script_file}" | head -1 | awk '{print $2}' || true)"
  if [[ -z "${DMX_ENV}" ]]; then
    DMX_ENV="production"
  fi

  if grep -qE 'disableServerCertValidation:[[:space:]]*true' "${script_file}"; then
    DMX_INSECURE="true"
    MGMT_PROXY_ENABLED="true"
  fi

  DMX_TOKEN="$(grep 'splunk-edge/var/token' "${script_file}" | sed -E 's/.*echo[[:space:]]+([^[:space:]]+)[[:space:]]*>.*var\/token.*/\1/' | tr -d '"' | head -1 || true)"
  if [[ -z "${DMX_TOKEN}" || "${DMX_TOKEN}" == "echo" ]]; then
    DMX_TOKEN="$(grep -oE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "${script_file}" | head -1 || true)"
  fi

  if [[ -n "${PACKAGE_URL}" ]]; then
    DMX_HOST="$(echo "${PACKAGE_URL}" | sed -E 's|^https?://([^/:]+).*|\1|')"
  fi
  if [[ -z "${DMX_HOST}" ]]; then
    local url_line
    url_line="$(grep -oE 'url: https?://[^[:space:]]+' "${script_file}" | head -1 || true)"
    if [[ -n "${url_line}" ]]; then
      DMX_HOST="$(echo "${url_line}" | sed -E 's|^url: https?://([^/:]+).*|\1|')"
    fi
  fi

  # Container entrypoint upgrades http→https for downloads; prefer https in manifests.
  if [[ "${PACKAGE_URL}" == http://* ]]; then
    PACKAGE_URL="https://${PACKAGE_URL#http://}"
  fi

  return 0
}

validate_parsed_install_script() {
  local missing=()

  [[ -n "${PACKAGE_URL}" ]] || missing+=("package URL (splunk-edge.tar.gz curl line)")
  [[ -n "${SPLUNK_EDGE_PACKAGE_CHECKSUM}" ]] || missing+=("package checksum (SHA-256 in if [[ ... != \"...\" ]] line)")
  [[ -n "${GROUP_ID}" ]] || missing+=("groupId in config.yaml echo lines")
  [[ -n "${DMX_HOST}" ]] || missing+=("control plane host (from package URL or url: line)")
  [[ -n "${DMX_TOKEN}" ]] || missing+=("provisioning JWT (echo ... > splunk-edge/var/token)")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Could not parse required fields from install script:" >&2
    for item in "${missing[@]}"; do
      echo "  - ${item}" >&2
    done
    return 1
  fi

  if [[ ! "${DMX_TOKEN}" =~ ^eyJ ]]; then
    echo "Warning: token does not look like a JWT (expected eyJ... provisioning token)" >&2
  fi

  return 0
}

print_parsed_install_script() {
  cat <<EOF
Parsed from install script:
  DMX_HOST=${DMX_HOST}
  DMX_ENV=${DMX_ENV}
  GROUP_ID=${GROUP_ID}
  DMX_INSECURE=${DMX_INSECURE}
  MGMT_PROXY_ENABLED=${MGMT_PROXY_ENABLED}
  SPLUNK_EDGE_PACKAGE_URL=${PACKAGE_URL}
  SPLUNK_EDGE_PACKAGE_CHECKSUM=${SPLUNK_EDGE_PACKAGE_CHECKSUM}
  DMX_TOKEN=${DMX_TOKEN:0:20}... (${#DMX_TOKEN} chars)
EOF
}
