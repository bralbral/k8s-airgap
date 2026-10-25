#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"
for tool in yamllint shellcheck ansible-playbook zstd; do
  command -v "${tool}" >/dev/null || { echo "Missing ${tool}" >&2; exit 1; }
done
mapfile -t scripts < <(find .github/scripts deploy -name '*.sh' -type f | sort)
for script in "${scripts[@]}"; do bash -n "${script}"; done
shellcheck -e SC1091 "${scripts[@]}"
yamllint -d '{extends: default, rules: {line-length: disable, truthy: disable}}' config deploy .github
python3 .github/scripts/validate-config.py
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  for compose in deploy/infrastructure/*/compose.yaml; do
    args=(-f "${compose}")
    example="$(dirname "${compose}")/.env.example"
    [[ ! -f "${example}" ]] || args+=(--env-file "${example}")
    docker compose "${args[@]}" config --quiet
  done
fi
for playbook in deploy/ansible/playbooks/*.yml; do
  ANSIBLE_CONFIG=deploy/ansible/ansible.cfg ansible-playbook --syntax-check \
    -i deploy/ansible/inventory/ha.example.yml "${playbook}"
done
.github/scripts/smoke-test-release.sh
