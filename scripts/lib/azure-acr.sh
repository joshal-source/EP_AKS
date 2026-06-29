# shellcheck shell=bash
# Resolve ACR login server for the active Azure cloud (public, US Gov, China, etc.).

# Optional override in .env: ACR_LOGIN_SERVER=myacr.azurecr.us

ep_acr_login_server() {
  local acr="${ACR_NAME:?ACR_NAME is required}"

  if [[ -n "${ACR_LOGIN_SERVER:-}" ]]; then
    printf '%s' "${ACR_LOGIN_SERVER}"
    return 0
  fi

  if command -v az >/dev/null 2>&1; then
    local login_server=""

    if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
      login_server="$(az acr show \
        --name "${acr}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --query loginServer \
        -o tsv 2>/dev/null || true)"
    fi

    if [[ -z "${login_server}" ]]; then
      login_server="$(az acr show \
        --name "${acr}" \
        --query loginServer \
        -o tsv 2>/dev/null || true)"
    fi

    if [[ -n "${login_server}" ]]; then
      printf '%s' "${login_server}"
      return 0
    fi

    local suffix
    suffix="$(az cloud show --query suffixes.acrLoginServerSuffix -o tsv 2>/dev/null || true)"
    if [[ -n "${suffix}" ]]; then
      printf '%s%s' "${acr}" "${suffix}"
      return 0
    fi
  fi

  printf '%s.azurecr.io' "${acr}"
}

ep_azure_cloud_name() {
  if command -v az >/dev/null 2>&1; then
    az cloud show --query name -o tsv 2>/dev/null || true
  fi
}
