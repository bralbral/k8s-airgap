#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 <https://kubernetes-api:6443> <kubernetes-ca.crt>" >&2
  exit 2
}

kubernetes_host="${1:-}"
kubernetes_ca_file="${2:-}"
[[ "${kubernetes_host}" =~ ^https://[A-Za-z0-9._:-]+$ ]] || usage
[[ -s "${kubernetes_ca_file}" ]] || usage
kubernetes_ca_file="$(realpath "${kubernetes_ca_file}")"

vault_address="${VAULT_ADDR:-http://127.0.0.1:8200}"
vault_init_file="${VAULT_INIT_FILE:-/root/vault-init.json}"
vault_binary="${VAULT_BINARY:-/usr/local/bin/vault}"
vault_auth_path="${VAULT_KUBERNETES_AUTH_PATH:-kubernetes-airgap}"
vault_auth_role="${VAULT_KUBERNETES_AUTH_ROLE:-cert-manager}"
vault_issuer_name="${VAULT_CLUSTER_ISSUER_NAME:-vault-pki}"
vault_service_account="${VAULT_SERVICE_ACCOUNT:-vault-issuer}"

[[ -x "${vault_binary}" ]] || {
  echo "Vault binary is missing: ${vault_binary}" >&2
  exit 1
}

[[ "${vault_auth_path}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid VAULT_KUBERNETES_AUTH_PATH." >&2
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

auth_json="$("${vault_binary}" auth list -format=json)"
if ! python3 -c '
import json
import sys

path = sys.argv[1] + "/"
raise SystemExit(0 if path in json.load(sys.stdin) else 1)
' "${vault_auth_path}" <<< "${auth_json}"; then
  "${vault_binary}" auth enable -path="${vault_auth_path}" kubernetes
fi

"${vault_binary}" write "auth/${vault_auth_path}/config" \
  kubernetes_host="${kubernetes_host}" \
  kubernetes_ca_cert=@"${kubernetes_ca_file}" >/dev/null

"${vault_binary}" write "auth/${vault_auth_path}/role/${vault_auth_role}" \
  bound_service_account_names="${vault_service_account}" \
  bound_service_account_namespaces=cert-manager \
  audience="vault://${vault_issuer_name}" \
  policies=cert-manager \
  ttl=1m >/dev/null

unset VAULT_TOKEN vault_token
echo "Vault Kubernetes auth is configured at auth/${vault_auth_path}."
echo "cert-manager ClusterIssuer audience: vault://${vault_issuer_name}"
