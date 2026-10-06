#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 <new-snapshot-file>" >&2
  exit 2
}

snapshot_file="${1:-}"
[[ -n "${snapshot_file}" ]] || usage
[[ ! -e "${snapshot_file}" ]] || {
  echo "Refusing to overwrite existing snapshot: ${snapshot_file}" >&2
  exit 1
}
snapshot_parent="$(dirname "${snapshot_file}")"
[[ -d "${snapshot_parent}" ]] || {
  echo "Snapshot directory does not exist: ${snapshot_parent}" >&2
  exit 1
}

vault_address="${VAULT_ADDR:-http://127.0.0.1:8200}"
vault_init_file="${VAULT_INIT_FILE:-/root/vault-init.json}"
vault_binary="${VAULT_BINARY:-/usr/local/bin/vault}"
[[ -x "${vault_binary}" ]] || {
  echo "Vault binary is missing: ${vault_binary}" >&2
  exit 1
}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ADDR="${vault_address}" VAULT_INIT_FILE="${vault_init_file}" \
  VAULT_BINARY="${vault_binary}" \
  "${script_dir}/unseal-vault.sh" >/dev/null

vault_token="$(python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["root_token"])
' "${vault_init_file}")"
export VAULT_ADDR="${vault_address}"
export VAULT_TOKEN="${vault_token}"
umask 077
"${vault_binary}" operator raft snapshot save "${snapshot_file}"
chmod 0600 "${snapshot_file}"
unset VAULT_TOKEN vault_token
echo "Vault Raft snapshot created: ${snapshot_file}"
