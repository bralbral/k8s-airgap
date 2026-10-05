#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --registry harbor.example [--insecure] <bundle-dir>" >&2; exit 2; }
registry=''
insecure=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) registry="$2"; shift 2 ;;
    --insecure) insecure=true; shift ;;
    -*) usage ;;
    *) bundle_dir="$1"; shift ;;
  esac
done
[[ -n "${registry}" && -n "${bundle_dir:-}" ]] || usage
images_root="${bundle_dir}/repositories/registry/images"
images_list="${images_root}/images.txt"
mapping_file="${bundle_dir}/repositories/registry/mapping.yaml"

[[ -f "${images_list}" ]] || {
  echo "Missing image inventory: ${images_list}" >&2
  exit 1
}
[[ -f "${mapping_file}" ]] || {
  echo "Missing registry mapping: ${mapping_file}" >&2
  exit 1
}

if command -v crane >/dev/null; then
  crane_bin="$(command -v crane)"
elif [[ -x "${bundle_dir}/tools/crane" ]]; then
  crane_bin="${bundle_dir}/tools/crane"
else
  echo "crane is required" >&2
  exit 1
fi

declare -A projects=()
while read -r source_registry project; do
  projects["${source_registry}"]="${project}"
done < <(
  awk '
    /^  [^#[:space:]][^:]*:[[:space:]]+[^#[:space:]]+/ {
      source=$1
      sub(/:$/, "", source)
      print source, $2
    }
  ' "${mapping_file}"
)

args=()
${insecure} && args+=(--insecure)
while read -r image; do
  source_registry="${image%%/*}"
  repository="${image#*/}"
  project="${projects[${source_registry}]:-}"
  [[ -n "${project}" ]] || {
    echo "No Harbor project mapping for source registry: ${source_registry}" >&2
    exit 1
  }
  source_tar="${images_root}/archives/$(echo "${image}" | tr '/:@' '_').tar"
  [[ -f "${source_tar}" ]] || {
    echo "Missing image archive: ${source_tar}" >&2
    exit 1
  }
  target="${registry}/${project}/${repository}"
  echo "Importing ${image} as ${target}"
  "${crane_bin}" push "${args[@]}" "${source_tar}" "${target}"
done < "${images_list}"
