#!/usr/bin/env bash
set -Eeuo pipefail

vault_address="${VAULT_ADDR:-http://127.0.0.1:8200}"
vault_public_address="${VAULT_PUBLIC_ADDRESS:-${VAULT_API_ADDRESS:-${vault_address}}}"
vault_init_file="${VAULT_INIT_FILE:-/root/vault-init.json}"
vault_binary="${VAULT_BINARY:-/usr/local/bin/vault}"
vault_root_ca_file="${VAULT_ROOT_CA_FILE:-/etc/vault.d/pki-root-ca.crt}"
key_shares="${VAULT_KEY_SHARES:-1}"
key_threshold="${VAULT_KEY_THRESHOLD:-1}"
allowed_domains="${VAULT_PKI_ALLOWED_DOMAINS:-internal,cluster.local}"

[[ -x "${vault_binary}" ]] || {
  echo "Vault binary is missing: ${vault_binary}" >&2
  exit 1
}
[[ -d "$(dirname "${vault_root_ca_file}")" ]] || {
  echo "Root CA output directory does not exist: $(dirname "${vault_root_ca_file}")" >&2
  exit 1
}

[[ "${key_shares}" =~ ^[1-9][0-9]*$ ]] || {
  echo "VAULT_KEY_SHARES must be a positive integer." >&2
  exit 1
}
[[ "${key_threshold}" =~ ^[1-9][0-9]*$ ]] || {
  echo "VAULT_KEY_THRESHOLD must be a positive integer." >&2
  exit 1
}
((key_threshold <= key_shares)) || {
  echo "VAULT_KEY_THRESHOLD cannot exceed VAULT_KEY_SHARES." >&2
  exit 1
}
[[ "${vault_public_address}" =~ ^http://[A-Za-z0-9._:-]+$ ]] || {
  echo "VAULT_PUBLIC_ADDRESS must be an HTTP URL without a path." >&2
  exit 1
}

export VAULT_ADDR="${vault_address}"
umask 077
status_json="$("${vault_binary}" status -format=json 2>/dev/null || true)"
[[ -n "${status_json}" ]] || {
  echo "Cannot reach Vault at ${VAULT_ADDR}." >&2
  exit 1
}
initialized="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["initialized"]).lower())' <<< "${status_json}")"

if [[ "${initialized}" == false ]]; then
  [[ ! -e "${vault_init_file}" ]] || {
    echo "Refusing to overwrite existing initialization file: ${vault_init_file}" >&2
    exit 1
  }
  "${vault_binary}" operator init \
    -key-shares="${key_shares}" \
    -key-threshold="${key_threshold}" \
    -format=json > "${vault_init_file}"
  chmod 0600 "${vault_init_file}"
  echo "Vault initialized. Keys were written to ${vault_init_file}."
fi

[[ -s "${vault_init_file}" ]] || {
  echo "Vault is initialized but ${vault_init_file} is unavailable." >&2
  echo "Set VAULT_INIT_FILE to the protected initialization JSON copy." >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ADDR="${VAULT_ADDR}" VAULT_INIT_FILE="${vault_init_file}" \
  VAULT_BINARY="${vault_binary}" \
  "${script_dir}/unseal-vault.sh"

vault_token="$(python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["root_token"])
' "${vault_init_file}")"
export VAULT_TOKEN="${vault_token}"

mounts_json="$("${vault_binary}" secrets list -format=json)"
if ! python3 -c 'import json,sys; raise SystemExit(0 if "pki_root/" in json.load(sys.stdin) else 1)' <<< "${mounts_json}"; then
  "${vault_binary}" secrets enable -path=pki_root pki
  "${vault_binary}" secrets tune -max-lease-ttl=87600h pki_root
fi
if ! "${vault_binary}" read -field=certificate pki_root/cert/ca >/dev/null 2>&1; then
  "${vault_binary}" write -field=certificate \
    pki_root/root/generate/internal \
    common_name="Kubernetes Airgap Root CA" \
    ttl=87600h >"${vault_root_ca_file}"
  chmod 0644 "${vault_root_ca_file}"
fi

"${vault_binary}" write pki_root/config/urls \
  issuing_certificates="${vault_public_address}/v1/pki_root/ca" \
  crl_distribution_points="${vault_public_address}/v1/pki_root/crl" >/dev/null

if ! python3 -c 'import json,sys; raise SystemExit(0 if "pki_int/" in json.load(sys.stdin) else 1)' <<< "${mounts_json}"; then
  "${vault_binary}" secrets enable -path=pki_int pki
  "${vault_binary}" secrets tune -max-lease-ttl=43800h pki_int
fi

if ! "${vault_binary}" read -field=certificate pki_int/cert/ca >/dev/null 2>&1; then
  work_dir="$(mktemp -d)"
  trap 'rm -rf -- "${work_dir}"' EXIT
  "${vault_binary}" write -field=csr \
    pki_int/intermediate/generate/internal \
    common_name="Kubernetes Airgap Intermediate CA" \
    ttl=43800h >"${work_dir}/intermediate.csr"
  "${vault_binary}" write -field=certificate \
    pki_root/root/sign-intermediate \
    csr=@"${work_dir}/intermediate.csr" \
    format=pem_bundle \
    ttl=43800h >"${work_dir}/intermediate.crt"
  "${vault_binary}" write pki_int/intermediate/set-signed \
    certificate=@"${work_dir}/intermediate.crt" >/dev/null
  rm -rf -- "${work_dir}"
  trap - EXIT
fi

"${vault_binary}" read -field=certificate pki_root/cert/ca \
  >"${vault_root_ca_file}"
chmod 0644 "${vault_root_ca_file}"

"${vault_binary}" write pki_int/config/urls \
  issuing_certificates="${vault_public_address}/v1/pki_int/ca" \
  crl_distribution_points="${vault_public_address}/v1/pki_int/crl" >/dev/null
"${vault_binary}" write pki_int/roles/kubernetes \
  allowed_domains="${allowed_domains}" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_ip_sans=true \
  max_ttl=2160h >/dev/null

policy_file="$(mktemp)"
cat > "${policy_file}" <<'EOF'
path "pki_int/sign/kubernetes" {
  capabilities = ["create", "update"]
}
EOF
"${vault_binary}" policy write cert-manager "${policy_file}" >/dev/null
rm -f -- "${policy_file}"

unset VAULT_TOKEN vault_token
echo "Vault PKI is ready. Root certificate: ${vault_root_ca_file}"
echo "Back up ${vault_init_file} now and keep it available until Kubernetes Auth is configured."
