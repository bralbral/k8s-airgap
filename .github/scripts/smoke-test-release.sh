#!/usr/bin/env bash
# Packaging round-trip with dummy artifacts. Does not download anything.
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d /tmp/k8s-airgap-release-test.XXXXXX)"
trap 'rm -rf -- "${test_root}"' EXIT
stage="${test_root}/stage"
mkdir -p "${stage}/packages" \
  "${stage}/repositories/registry/"{images/archives,images/groups,charts/archives} "${stage}/tools"
mkdir -p "${stage}/deploy"
tar -C "${repo_root}/deploy" --exclude='./infrastructure/vms/vm' \
  --exclude='.env' --exclude='hosts.yml' --exclude='__pycache__' -cf - . | \
  tar -C "${stage}/deploy" -xf -
cp -R "${repo_root}/config" "${stage}/config"
cp "${repo_root}/README.md" "${stage}/README.md"
cp "${repo_root}/config/versions.env" "${stage}/manifest.env"
cp "${repo_root}/config/registries.yaml" "${stage}/repositories/registry/mapping.yaml"
mkdir -p "${stage}/deploy/platform/manifests"
printf 'schema_version: 2\n' > "${stage}/manifest.yaml"
for file in \
  packages/debian12-amd64.tar.gz \
  deploy/platform/manifests/local-path-provisioner.yaml \
  deploy/infrastructure/harbor/harbor-offline-installer-test.tgz \
  tools/cni-plugins.tgz tools/containerd.tar.gz; do
  printf 'placeholder\n' > "${stage}/${file}"
done
for tool in kubeadm kubelet kubectl crictl helm crane runc; do
  printf '#!/bin/sh\nexit 0\n' > "${stage}/tools/${tool}"
  chmod 0755 "${stage}/tools/${tool}"
done
for chart in cilium metallb argo-cd; do
  printf 'placeholder\n' > "${stage}/repositories/registry/charts/archives/${chart}-test.tgz"
done
: > "${stage}/repositories/registry/images/images.txt"
for group in kubernetes networking storage platform infrastructure; do
  for n in 1 2; do
    image="registry.k8s.io/test-${group}:v${n}"
    printf '%s\n' "${image}" >> "${stage}/repositories/registry/images/groups/${group}.txt"
    if [[ "${group}" != infrastructure ]]; then
      printf '%s\n' "${image}" >> "${stage}/repositories/registry/images/images.txt"
    fi
    printf 'placeholder\n' > "${stage}/repositories/registry/images/archives/$(echo "${image}" | tr '/:@' '_').tar"
  done
done
(cd "${stage}"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "${test_root}/checksums")
mv "${test_root}/checksums" "${stage}/SHA256SUMS"
IMAGE_ASSET_CHUNK_BYTES=12 "${repo_root}/.github/scripts/package-release.sh" "${stage}" "${test_root}/release"
[[ -s "${test_root}/release/images-kubernetes-002.tar.zst" ]]
[[ -s "${test_root}/release/images-infrastructure-002.tar.zst" ]]
bash "${test_root}/release/unpack-release.sh" "${test_root}/release" "${test_root}/data"
# A corrupt transfer must be rejected.
printf 'corrupt\n' >> "${test_root}/data/tools/kubeadm"
if "${repo_root}/deploy/scripts/verify-bundle.sh" "${test_root}/data" >/dev/null 2>&1; then
  echo 'Corrupted data was accepted' >&2; exit 1
fi
echo 'Release round-trip and corruption rejection: OK'
