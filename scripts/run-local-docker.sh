#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/parse-install-script.sh
source "${SCRIPT_DIR}/lib/parse-install-script.sh"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"
  set +a
fi

IMAGE="${LOCAL_IMAGE:-edgeprocessor:local}"
BUILD=true
INSTALL_SCRIPT=""

usage() {
  cat <<EOF
Usage: $0 <install-script.txt> [options]

Run a single Edge Processor container on your local Docker engine (no Kubernetes).

Options:
  --no-build    Skip docker build (use existing ${IMAGE})
  --image TAG   Container image (default: ${IMAGE})
  -h, --help    Show help

Ports published on localhost:
  8088  HEC
  9997  S2S

Example:
  ./scripts/build-local.sh
  $0 install-script.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      BUILD=false
      shift
      ;;
    --image)
      IMAGE="${2:?--image requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "${INSTALL_SCRIPT}" ]]; then
        INSTALL_SCRIPT="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "${INSTALL_SCRIPT}" ]]; then
  usage >&2
  exit 1
fi

parse_install_script "${INSTALL_SCRIPT}"
validate_parsed_install_script

if [[ "${BUILD}" == "true" ]]; then
  LOCAL_IMAGE="${IMAGE}" "${SCRIPT_DIR}/build-local.sh"
fi

echo ""
print_parsed_install_script
echo ""
echo "Starting container ${IMAGE} (Ctrl+C to stop; offboard runs on shutdown)"
echo ""

exec docker run --rm -it \
  --name splunk-edge-local \
  -p 8088:8088 \
  -p 9997:9997 \
  -e "GROUP_ID=${GROUP_ID}" \
  -e "DMX_HOST=${DMX_HOST}" \
  -e "DMX_TOKEN=${DMX_TOKEN}" \
  -e "DMX_ENV=${DMX_ENV}" \
  -e "SPLUNK_EDGE_PACKAGE_URL=${PACKAGE_URL}" \
  -e "SPLUNK_EDGE_PACKAGE_CHECKSUM=${SPLUNK_EDGE_PACKAGE_CHECKSUM}" \
  -e "DMX_INSECURE=${DMX_INSECURE}" \
  -e "MGMT_PROXY_ENABLED=${MGMT_PROXY_ENABLED}" \
  "${IMAGE}"
