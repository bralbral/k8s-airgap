#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 <unpacked-bundle-directory>" >&2
  exit 2
}

[[ "${EUID}" -eq 0 ]] || {
  echo "Run this script as root." >&2
  exit 1
}

bundle_dir="${1:-}"
[[ -d "${bundle_dir}" ]] || usage
bundle_dir="$(realpath "${bundle_dir}")"
repository_dir="${bundle_dir}/repositories/apt/repository"
compose_binary="${bundle_dir}/tools/docker-compose"
harbor_hostname="${HARBOR_HOSTNAME:-harbor.internal}"

[[ -f "${repository_dir}/dists/bookworm/Release" ]] || {
  echo "Offline APT repository is missing: ${repository_dir}" >&2
  exit 1
}
[[ -x "${compose_binary}" ]] || {
  echo "Docker Compose binary is missing: ${compose_binary}" >&2
  exit 1
}

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12 ]] || {
  echo "The infrastructure bootstrap supports Debian 12 only." >&2
  exit 1
}

backup_dir=/etc/apt/k8s-airgap-bootstrap-backup
install -d -m 0700 "${backup_dir}"
for source_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [[ -e "${source_file}" ]] || continue
  [[ "${source_file}" == /etc/apt/sources.list.d/k8s-airgap-bootstrap.sources ]] && continue
  target="${backup_dir}/$(basename "${source_file}")"
  [[ -e "${target}" ]] || mv "${source_file}" "${target}"
done
if [[ -f /etc/apt/sources.list ]]; then
  [[ -e "${backup_dir}/sources.list" ]] || cp /etc/apt/sources.list "${backup_dir}/sources.list"
  printf '%s\n' '# Managed by k8s-airgap bootstrap' > /etc/apt/sources.list
fi

cat > /etc/apt/sources.list.d/k8s-airgap-bootstrap.sources <<EOF
Types: deb
URIs: file:${repository_dir}
Suites: bookworm
Components: main
Architectures: amd64
Trusted: yes
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ansible-core ca-certificates docker.io

install -d -m 0755 /usr/local/lib/docker/cli-plugins
install -m 0755 "${compose_binary}" /usr/local/lib/docker/cli-plugins/docker-compose
systemctl enable --now docker
docker compose version

if ! getent hosts "${harbor_hostname}" >/dev/null; then
  printf '127.0.0.1 %s\n' "${harbor_hostname}" >> /etc/hosts
fi

echo "Infrastructure host bootstrap complete. Previous APT sources are in ${backup_dir}."
