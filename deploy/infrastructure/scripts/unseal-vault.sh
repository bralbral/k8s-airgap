#!/usr/bin/env bash
set -Eeuo pipefail

vault_init_file="${VAULT_INIT_FILE:-/root/vault-init.json}"
vault_address="${VAULT_ADDR:-http://127.0.0.1:8200}"
vault_binary="${VAULT_BINARY:-/usr/local/bin/vault}"
[[ -x "${vault_binary}" ]] || {
  echo "Vault binary is missing: ${vault_binary}" >&2
  exit 1
}
[[ -s "${vault_init_file}" ]] || {
  echo "Vault initialization file is missing: ${vault_init_file}" >&2
  exit 1
}

export VAULT_ADDR="${vault_address}"
status_json="$("${vault_binary}" status -format=json 2>/dev/null || true)"
[[ -n "${status_json}" ]] || {
  echo "Cannot reach Vault at ${VAULT_ADDR}." >&2
  exit 1
}
sealed="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["sealed"]).lower())' <<< "${status_json}")"
if [[ "${sealed}" == false ]]; then
  echo "Vault is already unsealed."
  exit 0
fi

mapfile -t unseal_keys < <(
  python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
threshold = int(data["unseal_threshold"])
for key in data["unseal_keys_b64"][:threshold]:
    print(key)
' "${vault_init_file}"
)

for key in "${unseal_keys[@]}"; do
  "${vault_binary}" operator unseal "${key}" >/dev/null
done
unset key unseal_keys

if "${vault_binary}" status -format=json | python3 -c \
  'import json,sys; raise SystemExit(1 if json.load(sys.stdin)["sealed"] else 0)'; then
  echo "Vault is unsealed."
else
  echo "Vault is still sealed." >&2
  exit 1
fi
