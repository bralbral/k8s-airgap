#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d /tmp/k8s-airgap-release-test.XXXXXX)"
staging_dir="${test_root}/staging"
release_dir="${test_root}/release"
output_dir="${test_root}/output"

cleanup() {
  case "${test_root}" in
    /tmp/k8s-airgap-release-test.*) rm -rf -- "${test_root}" ;;
    *) echo "Refusing to remove unexpected test path: ${test_root}" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p \
  "${staging_dir}/config" \
  "${staging_dir}/deploy" \
  "${staging_dir}/repositories/apt" \
  "${staging_dir}/repositories/apt/repository/dists/bookworm" \
  "${staging_dir}/repositories/registry/charts/archives" \
  "${staging_dir}/repositories/registry/images/archives" \
  "${staging_dir}/repositories/registry/images/groups" \
  "${staging_dir}/tools/windows-amd64"

cp "${repo_root}/README.md" "${staging_dir}/README.md"
cp "${repo_root}/config/packages.txt" "${staging_dir}/config/packages.txt"
mkdir -p \
  "${staging_dir}/deploy/infrastructure/apt" \
  "${staging_dir}/deploy/infrastructure/harbor" \
  "${staging_dir}/deploy/infrastructure/scripts" \
  "${staging_dir}/deploy/nodes" \
  "${staging_dir}/deploy/platform/manifests/upstream" \
  "${staging_dir}/deploy/scripts"
cp "${repo_root}/deploy/infrastructure/compose.yaml" "${staging_dir}/deploy/infrastructure/compose.yaml"
cp "${repo_root}/deploy/infrastructure/.env.example" "${staging_dir}/deploy/infrastructure/.env.example"
cp -R "${repo_root}/deploy/infrastructure/apt/." "${staging_dir}/deploy/infrastructure/apt/"
cp -R "${repo_root}/deploy/infrastructure/scripts/." "${staging_dir}/deploy/infrastructure/scripts/"
printf '%s\n' 'placeholder' > "${staging_dir}/deploy/infrastructure/harbor/harbor-offline-installer-smoke.tgz"
cp -R "${repo_root}/deploy/nodes/." "${staging_dir}/deploy/nodes/"
cp -R "${repo_root}/deploy/platform/manifests/." "${staging_dir}/deploy/platform/manifests/"
cp -R "${repo_root}/deploy/scripts/." "${staging_dir}/deploy/scripts/"
printf '%s\n' 'placeholder' > "${staging_dir}/deploy/nodes/ansible/templates/flannel.yaml.j2"
printf '%s\n' 'placeholder' > "${staging_dir}/deploy/nodes/ansible/templates/local-path-provisioner.yaml.j2"
printf '%s\n' 'placeholder' > "${staging_dir}/deploy/platform/manifests/upstream/gateway-api-standard.yaml"

printf '%s\n' '---' 'schema_version: 1' > "${staging_dir}/manifest.yaml"
printf '%s\n' 'KUBERNETES_VERSION=v1.36.2' > "${staging_dir}/manifest.env"
printf '%s\n' '---' 'clusterName: smoke-test' > "${staging_dir}/cluster-defaults.yaml"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/apt/apt-repo-debian12-amd64.tar.gz"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/apt/repository/dists/bookworm/Release"
mkdir -p "${staging_dir}/repositories/apt/repository/dists/bookworm/main/binary-amd64"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/apt/repository/dists/bookworm/main/binary-amd64/Packages.gz"
printf '%s\n' '---' 'registries:' '  registry.k8s.io: k8s' '  quay.io: quay' \
  > "${staging_dir}/repositories/registry/mapping.yaml"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/registry/charts/archives/networking.tgz"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/registry/charts/archives/metallb-smoke.tgz"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/registry/charts/archives/traefik-smoke.tgz"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/registry/charts/archives/csi-driver-nfs-smoke.tgz"
printf '%s\n' 'placeholder' > "${staging_dir}/repositories/registry/charts/charts.lock"

kubernetes_image='registry.k8s.io/pause:3.10.2'
kubernetes_image_two='registry.k8s.io/pause:3.10.3'
networking_image='quay.io/example/network:v1'
storage_image='registry.k8s.io/sig-storage/nfsplugin:v4.13.4'
printf '%s\n' "${kubernetes_image}" "${kubernetes_image_two}" "${networking_image}" \
  "${storage_image}" \
  > "${staging_dir}/repositories/registry/images/images.txt"
printf '%s\n' "${kubernetes_image}" "${kubernetes_image_two}" \
  > "${staging_dir}/repositories/registry/images/groups/kubernetes.txt"
printf '%s\n' "${networking_image}" \
  > "${staging_dir}/repositories/registry/images/groups/networking.txt"
printf '%s\n' "${storage_image}" \
  > "${staging_dir}/repositories/registry/images/groups/storage.txt"
: > "${staging_dir}/repositories/registry/images/groups/extra.txt"
printf '%s\n' 'placeholder' \
  > "${staging_dir}/repositories/registry/images/archives/registry.k8s.io_pause_3.10.2.tar"
printf '%s\n' 'placeholder' \
  > "${staging_dir}/repositories/registry/images/archives/registry.k8s.io_pause_3.10.3.tar"
printf '%s\n' 'placeholder' \
  > "${staging_dir}/repositories/registry/images/archives/quay.io_example_network_v1.tar"
printf '%s\n' 'placeholder' \
  > "${staging_dir}/repositories/registry/images/archives/registry.k8s.io_sig-storage_nfsplugin_v4.13.4.tar"

for tool in kubeadm kubectl kubelet crictl helm crane docker-compose; do
  printf '%s\n' 'placeholder' > "${staging_dir}/tools/${tool}"
  chmod 0755 "${staging_dir}/tools/${tool}"
done
printf '%s\n' 'placeholder' > "${staging_dir}/tools/runc"
chmod 0755 "${staging_dir}/tools/runc"
printf '%s\n' 'placeholder' > "${staging_dir}/tools/cni-plugins.tgz"
printf '%s\n' 'placeholder' > "${staging_dir}/tools/containerd.tar.gz"
printf '%s\n' 'placeholder' > "${staging_dir}/tools/windows-amd64/kubectl.exe"
printf '%s\n' 'placeholder' > "${staging_dir}/tools/windows-amd64/k9s.exe"

(
  cd "${staging_dir}"
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum > "${test_root}/bundle-checksums"
)
mv "${test_root}/bundle-checksums" "${staging_dir}/SHA256SUMS"

IMAGE_ASSET_CHUNK_BYTES=12 \
  "${repo_root}/.github/scripts/package-release.sh" "${staging_dir}" "${release_dir}"

required_assets=(
  bootstrap.tar.zst
  automation.tar.zst
  apt-debian12-amd64.tar.zst
  tools-linux-amd64.tar.zst
  tools-windows-amd64.tar.zst
  harbor-offline.tar.zst
  images-kubernetes-001.tar.zst
  images-kubernetes-002.tar.zst
  images-networking-001.tar.zst
  images-storage-001.tar.zst
  charts-platform.tar.zst
  bundle-manifest.yaml
  SHA256SUMS
  unpack-release.sh
)
for asset in "${required_assets[@]}"; do
  [[ -s "${release_dir}/${asset}" ]] || {
    echo "Smoke test release asset is missing: ${asset}" >&2
    exit 1
  }
done

if tar --zstd -tf "${release_dir}/bootstrap.tar.zst" | grep -Eq '^(docs/|INSTALL\.md$)'; then
  echo "Only the canonical README must be packaged as documentation" >&2
  exit 1
fi

bash "${release_dir}/unpack-release.sh" "${release_dir}" "${output_dir}"
echo "Release smoke test: OK"
