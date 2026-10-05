#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: HARBOR_PASSWORD=... $0 --registry harbor.example [--plain-http] [--project charts] <bundle-dir>" >&2
  exit 2
}

registry=''
project=charts
plain_http=false
username="${HARBOR_USERNAME:-admin}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) registry="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --plain-http) plain_http=true; shift ;;
    -*) usage ;;
    *) bundle_dir="$1"; shift ;;
  esac
done

[[ -n "${registry}" && -n "${bundle_dir:-}" ]] || usage
: "${HARBOR_PASSWORD:?Set HARBOR_PASSWORD in the environment}"
[[ "${registry}" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "Invalid registry" >&2; exit 2; }
[[ "${project}" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || { echo "Invalid Harbor project" >&2; exit 2; }

charts_dir="${bundle_dir}/repositories/registry/charts/archives"
if [[ -x "${bundle_dir}/tools/helm" ]]; then
  helm_bin="${bundle_dir}/tools/helm"
elif command -v helm >/dev/null; then
  helm_bin="$(command -v helm)"
else
  echo "helm is required" >&2
  exit 1
fi

mapfile -d '' charts < <(find "${charts_dir}" -maxdepth 1 -type f -name '*.tgz' -print0 | sort -z)
[[ "${#charts[@]}" -gt 0 ]] || {
  echo "No chart archives found in ${charts_dir}" >&2
  exit 1
}

login_args=(registry login "${registry}" --username "${username}" --password-stdin)
push_args=()
if ${plain_http}; then
  login_args+=(--plain-http)
  push_args+=(--plain-http)
fi

printf '%s' "${HARBOR_PASSWORD}" | "${helm_bin}" "${login_args[@]}"
for chart in "${charts[@]}"; do
  echo "Importing chart $(basename "${chart}") into ${registry}/${project}"
  "${helm_bin}" push "${chart}" "oci://${registry}/${project}" "${push_args[@]}"
done
