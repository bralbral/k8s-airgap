#!/usr/bin/env bash
# Compatibility entry point; VM provisioning runs through Ansible.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="$script_dir/config.json"
options=()
config_set=false
for arg in "$@"; do
  case "$arg" in
    --check) options+=(--check) ;;
    --recreate) options+=(-e vm_recreate=true) ;;
    --recover-incomplete) options+=(-e vm_recover_incomplete=true) ;;
    -h|--help)
      echo "Usage: $0 [config.json] [--check] [--recreate | --recover-incomplete]"
      echo 'Runs the Ansible create-vms.yml playbook on localhost.'
      exit 0 ;;
    --*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *)
      [[ "$config_set" == false ]] || { echo 'Only one config file is allowed.' >&2; exit 1; }
      config="$(realpath "$arg")"
      config_set=true ;;
  esac
done
ansible_bin="$(command -v ansible-playbook || true)"
if [[ -z "$ansible_bin" && -x "$script_dir/../../../.venv/bin/ansible-playbook" ]]; then
  ansible_bin="$script_dir/../../../.venv/bin/ansible-playbook"
fi
[[ -n "$ansible_bin" ]] || {
  echo 'ansible-playbook is required (ansible-core, same as for Kubernetes deployment).' >&2
  exit 1
}
vars="$(python3 - "$config" <<'PY'
import json
import sys
print(json.dumps({'vm_config_file': sys.argv[1]}))
PY
)"
exec "$ansible_bin" -i localhost, \
  "$script_dir/../../ansible/playbooks/create-vms.yml" \
  -e "$vars" "${options[@]}"
