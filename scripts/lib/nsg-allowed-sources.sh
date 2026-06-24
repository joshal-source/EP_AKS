# shellcheck shell=bash
# Read and validate NSG / LoadBalancer allow-list sources from a config file.

nsg_allowed_sources_file() {
  local root_dir="${1:?root directory required}"
  local file="${NSG_ALLOWED_SOURCES_FILE:-config/nsg-allowed-sources.conf}"
  if [[ "${file}" != /* ]]; then
    file="${root_dir}/${file}"
  fi
  printf '%s' "${file}"
}

# Populates global array NSG_ALLOWED_SOURCES. Returns 0 if non-empty, 1 if empty/missing.
nsg_load_allowed_sources() {
  local root_dir="${1:?root directory required}"
  local file
  file="$(nsg_allowed_sources_file "${root_dir}")"

  NSG_ALLOWED_SOURCES=()

  if [[ ! -f "${file}" ]]; then
    echo "ERROR: NSG allow-list file not found: ${file}" >&2
    echo "Copy config/nsg-allowed-sources.conf.example and edit, or set NSG_ALLOWED_SOURCES_FILE in .env." >&2
    return 1
  fi

  local line trimmed
  while IFS= read -r line || [[ -n "${line}" ]]; do
    trimmed="${line%%#*}"
    trimmed="$(printf '%s' "${trimmed}" | tr -d '[:space:]')"
    [[ -z "${trimmed}" ]] && continue

    if ! nsg_is_valid_source "${trimmed}"; then
      echo "ERROR: invalid IP or CIDR in ${file}: ${trimmed}" >&2
      return 1
    fi
    NSG_ALLOWED_SOURCES+=("${trimmed}")
  done < "${file}"

  if ((${#NSG_ALLOWED_SOURCES[@]} == 0)); then
    echo "ERROR: no allowed sources in ${file}" >&2
    return 1
  fi

  return 0
}

nsg_is_valid_source() {
  local value="$1"
  local host prefix

  if [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    host="${value}"
  elif [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]]; then
    host="${value%/*}"
    prefix="${value#*/}"
    if (( prefix < 0 || prefix > 32 )); then
      return 1
    fi
  else
    return 1
  fi

  local IFS=.
  local -a octets=(${host})
  for o in "${octets[@]}"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

nsg_allowed_sources_csv() {
  local IFS=,
  printf '%s' "${NSG_ALLOWED_SOURCES[*]}"
}
