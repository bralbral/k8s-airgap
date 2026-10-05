#!/usr/bin/env bash
set -Eeuo pipefail

staging_dir="${1:?Usage: package-release.sh <staging-dir> <release-dir>}"
release_dir="${2:?Usage: package-release.sh <staging-dir> <release-dir>}"

[[ -f "${staging_dir}/manifest.yaml" ]] || {
  echo "Not a bundle staging directory: ${staging_dir}" >&2
  exit 1
}

mkdir -p "${release_dir}"
find "${release_dir}" -maxdepth 1 -type f \
  \( -name '*.tar.zst' -o -name 'SHA256SUMS' -o -name 'bundle-manifest.yaml' -o -name 'unpack-release.sh' \) \
  -delete

archive() {
  local asset_name="$1"
  shift
  tar --zstd -cf "${release_dir}/${asset_name}.tar.zst" \
    -C "${staging_dir}" "$@"
}

archive bootstrap \
  manifest.yaml manifest.env SHA256SUMS README.md INSTALL.md \
  cluster-defaults.yaml config docs deploy/scripts \
  repositories/registry/mapping.yaml \
  repositories/registry/images/images.txt \
  repositories/registry/images/kubespray-images.txt \
  repositories/registry/images/groups
archive automation deploy/nodes deploy/kubespray deploy/platform/manifests
archive apt-debian12-amd64 repositories/apt
archive kubespray-offline installers/kubespray repositories/files
archive python-ansible-debian12 repositories/python
archive tools-linux-amd64 --exclude='tools/windows-amd64' tools
archive tools-windows-amd64 tools/windows-amd64
archive harbor-offline deploy/infrastructure
archive charts-networking repositories/registry/charts

create_image_asset() {
  local group="$1"
  local group_list="repositories/registry/images/groups/${group}.txt"
  local file_list
  file_list="$(mktemp)"

  while read -r image; do
    [[ -n "${image}" ]] || continue
    printf 'repositories/registry/images/archives/%s.tar\n' \
      "$(echo "${image}" | tr '/:@' '_')" >> "${file_list}"
  done < "${staging_dir}/${group_list}"

  if [[ -s "${file_list}" ]]; then
    tar --zstd -cf "${release_dir}/images-${group}.tar.zst" \
      -C "${staging_dir}" \
      --files-from "${file_list}"
  fi
  rm "${file_list}"
}

create_image_asset kubernetes
create_image_asset networking
create_image_asset extra

cp "${staging_dir}/manifest.yaml" "${release_dir}/bundle-manifest.yaml"
cp "${staging_dir}/deploy/scripts/unpack-release.sh" "${release_dir}/unpack-release.sh"
(
  cd "${release_dir}"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)

max_asset_bytes=$((2 * 1024 * 1024 * 1024))
while IFS= read -r -d '' asset; do
  asset_size="$(stat -c '%s' "${asset}")"
  if ((asset_size >= max_asset_bytes)); then
    echo "Release asset exceeds GitHub's 2 GiB limit: ${asset}" >&2
    exit 1
  fi
done < <(find "${release_dir}" -maxdepth 1 -type f -print0)

echo "Release assets: ${release_dir}"
