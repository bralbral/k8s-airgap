#!/usr/bin/env bash
# https://goharbor.io/docs/main/install-config/run-installer-script/
set -Eeuo pipefail
if (( $# < 2 || $# > 3 )) || [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: $0 <host-ip-or-name> <offline-installer.tgz> [install-directory]" >&2
  exit 1
fi
harbor_host="$1"
archive="$2"
harbor_dir="${3:-/stage/harbor/installer/harbor}"
command -v python3 >/dev/null || { echo 'Install python3 first.' >&2; exit 1; }
if [[ ! -f "${harbor_dir}/install.sh" ]]; then
  [[ -f "${archive}" ]] || { echo "Offline installer not found: ${archive}" >&2; exit 1; }
  mkdir -p "${harbor_dir}"
  tar -xzf "${archive}" --strip-components=1 -C "${harbor_dir}"
fi
if [[ ! -f "${harbor_dir}/harbor.yml" ]]; then
  python3 - "${harbor_dir}" "${harbor_host}" <<'PY'
import json
import re
import sys
from pathlib import Path
folder = Path(sys.argv[1])
text = (folder / 'harbor.yml.tmpl').read_text()
def replace(pattern, value):
    global text
    text, count = re.subn(pattern, lambda _: value, text, flags=re.M)
    if count != 1:
        raise SystemExit(f'Unexpected Harbor template: {pattern}')
replace(r'^hostname:.*$', 'hostname: ' + json.dumps(sys.argv[2]))
replace(r'^http:\n(?:[ \t]+.*\n|#.*\n)*', 'http:\n  port: 8080\n')
replace(r'^https:\n(?:[ \t]+.*\n|#.*\n|\n)*', '')
replace(r'^harbor_admin_password:.*$', "harbor_admin_password: 'Airgap2026!'")
replace(r'^database:\n(?:[ \t]+#.*\n)*  password:.*$', "database:\n  password: 'Airgap2026!'")
replace(r'^data_volume:.*$', 'data_volume: /stage/harbor/data')
replace(r'^    location:.*$', '    location: /stage/harbor/log')
config = folder / 'harbor.yml'
config.write_text(text)
config.chmod(0o600)
PY
else
  echo "Using existing ${harbor_dir}/harbor.yml; existing passwords are preserved."
fi
cd "${harbor_dir}"
exec ./install.sh
