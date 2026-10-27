#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --registry harbor.example [--plain-http] <bundle-dir>" >&2; exit 2; }
registry=''
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) [[ $# -ge 2 ]] || usage; registry="$2"; shift 2 ;;
    --plain-http) args+=(--plain-http); shift ;;
    -*) usage ;;
    *) bundle_dir="$1"; shift ;;
  esac
done
[[ -n "${registry}" && -n "${bundle_dir:-}" ]] || usage
helm_bin="${bundle_dir}/tools/helm"
[[ -x "${helm_bin}" ]] || { echo "Missing bundled Helm: ${helm_bin}" >&2; exit 1; }
shopt -s nullglob
charts=("${bundle_dir}/repositories/registry/charts/archives/"*.tgz)
(( ${#charts[@]} > 0 )) || { echo 'No chart archives found in the bundle' >&2; exit 1; }
for chart in "${charts[@]}"; do
  "${helm_bin}" push "${chart}" "oci://${registry}/charts" "${args[@]}"
done
