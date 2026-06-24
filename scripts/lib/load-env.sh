# shellcheck shell=bash
# Source repo .env when present. Safe to source from other scripts.

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
  local acr="${ACR_NAME:?ACR_NAME is required}"
  local name="${IMAGE_NAME:-edgeprocessor}"
  local tag="${IMAGE_TAG:-latest}"
  printf '%s.azurecr.io/%s:%s' "${acr}" "${name}" "${tag}"
}

ep_acr_repository() {
  local acr="${ACR_NAME:?ACR_NAME is required}"
  local name="${IMAGE_NAME:-edgeprocessor}"
  printf '%s.azurecr.io/%s' "${acr}" "${name}"
}
