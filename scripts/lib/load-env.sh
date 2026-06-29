# shellcheck shell=bash
# Source repo .env when present. Safe to source from other scripts.

SCRIPT_DIR_LOAD_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=azure-acr.sh
source "${SCRIPT_DIR_LOAD_ENV}/azure-acr.sh"

load_ep_env() {
  local root_dir="${1:?root directory required}"
  if [[ -f "${root_dir}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${root_dir}/.env"
    set +a
  fi
}

ep_acr_image() {
  local acr_host name tag
  acr_host="$(ep_acr_login_server)"
  name="${IMAGE_NAME:-edgeprocessor}"
  tag="${IMAGE_TAG:-latest}"
  printf '%s/%s:%s' "${acr_host}" "${name}" "${tag}"
}

ep_acr_repository() {
  local acr_host name
  acr_host="$(ep_acr_login_server)"
  name="${IMAGE_NAME:-edgeprocessor}"
  printf '%s/%s' "${acr_host}" "${name}"
}
