#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

command -v yamllint >/dev/null || {
  echo "Missing required command: yamllint" >&2
  exit 1
}
command -v shellcheck >/dev/null || {
  echo "Missing required command: shellcheck" >&2
  exit 1
}
command -v ansible-playbook >/dev/null || {
  echo "Missing required command: ansible-playbook" >&2
  exit 1
}

echo "Validating shell syntax"
bash -n .github/scripts/*.sh
bash -n deploy/scripts/*.sh
bash -n deploy/infrastructure/scripts/*.sh
shellcheck -e SC1091 \
  .github/scripts/*.sh \
  deploy/scripts/*.sh \
  deploy/infrastructure/scripts/*.sh

echo "Validating YAML"
yamllint \
  -d '{extends: default, rules: {line-length: disable}}' \
  config deploy .github

echo "Validating pinned version consistency"
python3 .github/scripts/validate-config.py

echo "Validating Ansible playbook syntax"
ansible_local_temp="$(mktemp -d)"
for inventory in \
  deploy/nodes/ansible/inventory/lab.example.yml \
  deploy/nodes/ansible/inventory/ha.example.yml; do
  for playbook in deploy/nodes/ansible/playbooks/*.yml; do
    ANSIBLE_LOCAL_TEMP="${ansible_local_temp}" \
    ANSIBLE_CONFIG=deploy/nodes/ansible/ansible.cfg \
      ansible-playbook --syntax-check \
        -i "${inventory}" \
        "${playbook}"
  done
done
rmdir "${ansible_local_temp}"

echo "Testing release packaging and unpacking"
.github/scripts/smoke-test-release.sh

echo "Validation passed"
