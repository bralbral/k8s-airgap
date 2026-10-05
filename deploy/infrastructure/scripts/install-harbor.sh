#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: HARBOR_ADMIN_PASSWORD=... $0 <harbor-offline-installer.tgz>" >&2
  exit 2
}

installer_archive="${1:-}"
[[ -f "${installer_archive}" ]] || usage
: "${HARBOR_ADMIN_PASSWORD:?Set HARBOR_ADMIN_PASSWORD in the environment}"

harbor_hostname="${HARBOR_HOSTNAME:-harbor.internal}"
harbor_http_port="${HARBOR_HTTP_PORT:-8080}"
harbor_data_dir="${HARBOR_DATA_DIR:-/var/lib/harbor}"

[[ "${harbor_hostname}" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid HARBOR_HOSTNAME" >&2; exit 2; }
[[ "${harbor_http_port}" =~ ^[0-9]+$ ]] || { echo "Invalid HARBOR_HTTP_PORT" >&2; exit 2; }
[[ "${HARBOR_ADMIN_PASSWORD}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "For this lab installer, use letters, digits, dot, underscore and dash in HARBOR_ADMIN_PASSWORD" >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
runtime_dir="${repo_root}/deploy/infrastructure/runtime"
harbor_dir="${runtime_dir}/harbor"
mapping_file="${REGISTRY_MAPPING_FILE:-}"

if [[ -z "${mapping_file}" ]]; then
  if [[ -f "${repo_root}/config/registries.yaml" ]]; then
    mapping_file="${repo_root}/config/registries.yaml"
  else
    mapping_file="${repo_root}/repositories/registry/mapping.yaml"
  fi
fi
[[ -f "${mapping_file}" ]] || {
  echo "Registry mapping not found: ${mapping_file}" >&2
  exit 1
}

mkdir -p "${runtime_dir}"
if [[ -e "${harbor_dir}" ]]; then
  echo "${harbor_dir} already exists; preserve it for Harbor lifecycle operations." >&2
  echo "Move it aside explicitly before performing a clean installation." >&2
  exit 1
fi

tar -xzf "${installer_archive}" -C "${runtime_dir}"
[[ -f "${harbor_dir}/harbor.yml.tmpl" ]] || { echo "Unexpected Harbor archive layout" >&2; exit 1; }
cp "${harbor_dir}/harbor.yml.tmpl" "${harbor_dir}/harbor.yml"

sed -i \
  -e "s/^hostname:.*/hostname: ${harbor_hostname}/" \
  -e "/^http:/,/^[^[:space:]]/ s/^[[:space:]]*port:.*/  port: ${harbor_http_port}/" \
  -e "s/^harbor_admin_password:.*/harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}/" \
  -e "s|^data_volume:.*|data_volume: ${harbor_data_dir}|" \
  "${harbor_dir}/harbor.yml"

(
  cd "${harbor_dir}"
  ./install.sh
)

harbor_url="http://127.0.0.1:${harbor_http_port}"
for attempt in $(seq 1 60); do
  if curl --silent --fail "${harbor_url}/api/v2.0/health" >/dev/null; then
    break
  fi
  if [[ "${attempt}" == 60 ]]; then
    echo "Harbor did not become ready at ${harbor_url}" >&2
    exit 1
  fi
  sleep 2
done

mapfile -t harbor_projects < <(
  awk '
    /^  [^#[:space:]][^:]*:[[:space:]]+[^#[:space:]]+/ { print $2 }
  ' "${mapping_file}" | sort -u
)
[[ "${#harbor_projects[@]}" -gt 0 ]] || {
  echo "No Harbor projects found in ${mapping_file}" >&2
  exit 1
}

for project in "${harbor_projects[@]}"; do
  if curl --silent --fail \
    --user "admin:${HARBOR_ADMIN_PASSWORD}" \
    "${harbor_url}/api/v2.0/projects?name=${project}" | grep -q '"name"'; then
    echo "Harbor project already exists: ${project}"
    continue
  fi
  curl --fail-with-body --silent --show-error \
    --user "admin:${HARBOR_ADMIN_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"${project}\",\"public\":true}" \
    "${harbor_url}/api/v2.0/projects"
  echo "Created public Harbor project: ${project}"
done

echo "Harbor is available at http://${harbor_hostname}:${harbor_http_port}"
echo "Trivy was intentionally not installed in the memory-constrained lab profile."
