#!/usr/bin/env bash
set -Eeuo pipefail

target_sha="${1:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "${repo_root}/config/versions.env"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }

release_version="${KUBERNETES_VERSION}-build.${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT:-1}"

release_dir="${repo_root}/dist/release-${KUBERNETES_VERSION#v}-debian12-amd64"
[[ -f "${release_dir}/SHA256SUMS" ]] || {
  echo "Release assets not found: ${release_dir}" >&2
  exit 1
}

release_tag="airgap-${release_version}"
release_title="Kubernetes Air-Gap ${KUBERNETES_VERSION} build ${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT:-1}"

if gh release view "${release_tag}" >/dev/null 2>&1; then
  echo "Release already exists: ${release_tag}" >&2
  exit 1
fi

notes_file="$(mktemp)"
trap 'rm -f "${notes_file}"' EXIT
{
  echo "Ready-to-transfer offline Kubernetes assets for Debian 12/amd64."
  echo
  echo "## Included versions"
  echo
  echo "| Component | Version |"
  echo "| --- | --- |"
  echo "| Kubernetes | ${KUBERNETES_VERSION} |"
  echo "| containerd | ${CONTAINERD_VERSION} |"
  echo "| Flannel | ${FLANNEL_VERSION} |"
  echo "| Harbor | ${HARBOR_VERSION} |"
  echo "| Docker Compose | ${DOCKER_COMPOSE_VERSION} |"
  echo "| Helm | ${HELM_VERSION} |"
  echo "| K9s | ${K9S_VERSION} |"
  echo
  echo "## Assets"
  echo
  while read -r asset; do
    echo "- \`$(basename "${asset}")\` — $(du -h "${asset}" | cut -f1)"
  done < <(find "${release_dir}" -maxdepth 1 -type f | sort)
  echo
  echo "## Assemble and verify"
  echo
  echo '```bash'
  echo "bash unpack-release.sh . k8s-airgap"
  echo '```'
} > "${notes_file}"

create_args=(
  "${release_tag}"
  --title "${release_title}"
  --notes-file "${notes_file}"
  --draft
)
[[ -n "${target_sha}" ]] && create_args+=(--target "${target_sha}")

gh release create "${create_args[@]}"
gh release upload "${release_tag}" "${release_dir}"/*
gh release edit "${release_tag}" --draft=false --latest

echo "Published GitHub Release: ${release_tag}"
