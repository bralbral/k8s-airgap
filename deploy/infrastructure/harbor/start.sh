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
./install.sh
# Provision projects only after the official installer has started Harbor.
python3 - "http://${harbor_host}:8080" <<'PYPROJECTS'
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

base = sys.argv[1].rstrip('/') + '/api/v2.0'
password = os.environ.get('HARBOR_ADMIN_PASSWORD', 'Airgap2026!')
headers = {
    'Authorization': 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode(),
    'Content-Type': 'application/json',
    'X-Is-Resource-Name': 'true',
}

def request(path, method='GET', body=None):
    payload = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=10) as response:
        data = response.read()
        return json.loads(data) if data else None

# Startup can take a while, especially on the first initialization of the DB.
deadline = time.monotonic() + 180
while True:
    try:
        if request('/health').get('status') == 'healthy':
            break
    except (urllib.error.URLError, TimeoutError):
        pass
    if time.monotonic() >= deadline:
        raise SystemExit('Harbor did not become healthy within 180 seconds; projects were not initialized.')
    time.sleep(2)

for name in ('docker', 'ghcr', 'quay', 'k8s'):
    try:
        project = request('/projects/' + name)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise SystemExit(f'Cannot read Harbor project {name}: HTTP {error.code}. Check HARBOR_ADMIN_PASSWORD.') from error
        try:
            request('/projects', 'POST', {'project_name': name, 'metadata': {'public': 'true'}})
        except urllib.error.HTTPError as error:
            if error.code != 409:
                raise SystemExit(f'Cannot create Harbor project {name}: HTTP {error.code}.') from error
        project = request('/projects/' + name)
    if str(project.get('metadata', {}).get('public')).lower() != 'true':
        request('/projects/' + name, 'PUT', {'metadata': {'public': 'true'}})
    project = request('/projects/' + name)
    if str(project.get('metadata', {}).get('public')).lower() != 'true':
        raise SystemExit(f'Harbor project {name} is not public.')
    print(f'Harbor project {name}: public, ready.', flush=True)
PYPROJECTS
