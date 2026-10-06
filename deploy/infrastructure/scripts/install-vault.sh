#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo VAULT_API_ADDRESS=http://<vault-ip>:8200 $0 <unpacked-bundle-directory>" >&2
  exit 2
}

[[ "${EUID}" -eq 0 ]] || {
  echo "Run this script as root." >&2
  exit 1
}

bundle_dir="${1:-}"
[[ -d "${bundle_dir}" ]] || usage
bundle_dir="$(realpath "${bundle_dir}")"
vault_binary="${bundle_dir}/tools/vault"
[[ -x "${vault_binary}" ]] || {
  echo "Vault binary is missing: ${vault_binary}" >&2
  exit 1
}

vault_api_address="${VAULT_API_ADDRESS:-http://127.0.0.1:8200}"
vault_bind_address="${VAULT_BIND_ADDRESS:-0.0.0.0:8200}"
vault_cluster_address="${VAULT_CLUSTER_ADDRESS:-http://127.0.0.1:8201}"
vault_cluster_bind_address="${VAULT_CLUSTER_BIND_ADDRESS:-127.0.0.1:8201}"
vault_local_health_address="${VAULT_LOCAL_HEALTH_ADDRESS:-http://127.0.0.1:8200}"
vault_node_id="${VAULT_NODE_ID:-vault-01}"

[[ "${vault_api_address}" =~ ^http://[A-Za-z0-9._:-]+$ ]] || {
  echo "VAULT_API_ADDRESS must be an HTTP URL without a path." >&2
  exit 1
}
[[ "${vault_cluster_address}" =~ ^http://[A-Za-z0-9._:-]+$ ]] || {
  echo "VAULT_CLUSTER_ADDRESS must be an HTTP URL without a path." >&2
  exit 1
}
[[ "${vault_local_health_address}" =~ ^http://[A-Za-z0-9._:-]+$ ]] || {
  echo "VAULT_LOCAL_HEALTH_ADDRESS must be an HTTP URL without a path." >&2
  exit 1
}
for address in "${vault_bind_address}" "${vault_cluster_bind_address}"; do
  [[ "${address}" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "Invalid Vault listener address: ${address}" >&2
    exit 1
  }
done
[[ "${vault_node_id}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid VAULT_NODE_ID: ${vault_node_id}" >&2
  exit 1
}

if ! getent passwd vault >/dev/null; then
  useradd --system --home-dir /var/lib/vault --shell /usr/sbin/nologin vault
fi

install -m 0755 "${vault_binary}" /usr/local/bin/vault
install -d -o root -g vault -m 0750 /etc/vault.d
install -d -o vault -g vault -m 0700 /var/lib/vault

vault_config="$(mktemp)"
vault_service="$(mktemp)"
trap 'rm -f -- "${vault_config}" "${vault_service}"' EXIT

cat > "${vault_config}" <<EOF
ui = true
disable_mlock = true
api_addr = "${vault_api_address}"
cluster_addr = "${vault_cluster_address}"

storage "raft" {
  path = "/var/lib/vault"
  node_id = "${vault_node_id}"
}

listener "tcp" {
  address = "${vault_bind_address}"
  cluster_address = "${vault_cluster_bind_address}"
  tls_disable = 1
}
EOF
install -o root -g vault -m 0640 "${vault_config}" /etc/vault.d/vault.hcl

cat > "${vault_service}" <<'EOF'
[Unit]
Description=HashiCorp Vault
Documentation=https://developer.hashicorp.com/vault/docs
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
install -o root -g root -m 0644 "${vault_service}" /etc/systemd/system/vault.service

systemctl daemon-reload
systemctl enable vault
systemctl restart vault

for _ in $(seq 1 30); do
  if curl --silent --show-error --output /dev/null \
    "${vault_local_health_address}/v1/sys/health"; then
    echo "Vault service is listening at ${vault_api_address}."
    echo "Next: run deploy/infrastructure/scripts/initialize-vault.sh as root."
    exit 0
  fi
  sleep 1
done

echo "Vault did not start listening at ${vault_local_health_address}." >&2
systemctl status --no-pager vault >&2 || true
exit 1
