#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --registry harbor.example --project k8s [--insecure] <bundle-dir>" >&2; exit 2; }
registry= project= insecure=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) registry="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --insecure) insecure=true; shift ;;
    -*) usage ;;
    *) bundle_dir="$1"; shift ;;
  esac
done
[[ -n "${registry}" && -n "${project}" && -n "${bundle_dir:-}" ]] || usage
if command -v crane >/dev/null; then
  crane_bin="$(command -v crane)"
elif [[ -x "${bundle_dir}/tools/crane" ]]; then
  crane_bin="${bundle_dir}/tools/crane"
else
  echo "crane is required" >&2
  exit 1
fi

args=()
${insecure} && args+=(--insecure)
while read -r image; do
  source_tar="${bundle_dir}/images/$(echo "${image}" | tr '/:@' '_').tar"
  target="${registry}/${project}/${image##*/}"
  "${crane_bin}" push "${args[@]}" "${source_tar}" "${target}"
done < "${bundle_dir}/images.txt"
