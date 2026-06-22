#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/parse-install-script.sh
source "${SCRIPT_DIR}/lib/parse-install-script.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <install-script.txt>"
  echo ""
  echo "Paste the install script from Splunk UI:"
  echo "  Edge Processor → Manage instances → Install tab → copy script to a file"
  echo ""
  echo "For full automated setup (secret, ConfigMap, deployment, apply):"
  echo "  ./scripts/setup-from-install-script.sh install-script.txt --apply"
  exit 1
fi

parse_install_script "$1"
validate_parsed_install_script || exit 1

print_parsed_install_script

echo ""
echo "To deploy automatically:"
echo "  ./scripts/setup-from-install-script.sh $1 --apply"
