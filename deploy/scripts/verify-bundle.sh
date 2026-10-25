#!/usr/bin/env bash
set -Eeuo pipefail
cd "${1:?Usage: verify-bundle.sh <unpacked-data-directory>}"
sha256sum --check --quiet SHA256SUMS
for path in manifest.env manifest.yaml \
  packages/debian12-amd64.tar.gz \
  repositories/registry/mapping.yaml repositories/registry/images/images.txt \
  repositories/registry/images/groups/infrastructure.txt \
  deploy/platform/manifests/local-path-provisioner.yaml \
  tools/cni-plugins.tgz tools/containerd.tar.gz; do
  [[ -s "${path}" ]] || { echo "Missing artifact: ${path}" >&2; exit 1; }
done
for tool in kubeadm kubelet kubectl crictl helm crane runc; do
  [[ -x "tools/${tool}" ]] || { echo "Missing executable: ${tool}" >&2; exit 1; }
done
for pattern in \
  'repositories/registry/charts/archives/cilium-*.tgz' \
  'repositories/registry/charts/archives/metallb-*.tgz' \
  'repositories/registry/charts/archives/argo-cd-*.tgz' \
  'deploy/infrastructure/harbor/harbor-offline-installer-*.tgz'; do
  compgen -G "${pattern}" >/dev/null || { echo "Missing artifact: ${pattern}" >&2; exit 1; }
done
while read -r image; do
  archive="repositories/registry/images/archives/$(echo "${image}" | tr '/:@' '_').tar"
  [[ -s "${archive}" ]] || { echo "Missing image: ${image}" >&2; exit 1; }
done < <(cat repositories/registry/images/images.txt repositories/registry/images/groups/infrastructure.txt)
echo 'Offline bundle: OK'
