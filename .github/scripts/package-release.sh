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
  manifest.yaml manifest.env SHA256SUMS README.md \
  cluster-defaults.yaml config deploy/scripts \
  repositories/registry/mapping.yaml \
  repositories/registry/images/images.txt \
  repositories/registry/images/groups
archive automation deploy/nodes deploy/platform/manifests
archive apt-debian12-amd64 repositories/apt
archive tools-linux-amd64 --exclude='tools/windows-amd64' tools
archive tools-windows-amd64 tools/windows-amd64
archive harbor-offline deploy/infrastructure
archive charts-networking repositories/registry/charts

create_image_assets() {
  local group="$1"
  local group_list="repositories/registry/images/groups/${group}.txt"
  local file_list
  local chunk_index=1
  local chunk_bytes=0
  local chunk_limit_bytes="${IMAGE_ASSET_CHUNK_BYTES:-$((1536 * 1024 * 1024))}"
  [[ "${chunk_limit_bytes}" =~ ^[1-9][0-9]*$ ]] || {
    echo "IMAGE_ASSET_CHUNK_BYTES must be a positive integer" >&2
    exit 1
  }
  file_list="$(mktemp)"

  archive_chunk() {
    local asset_name
    asset_name="images-${group}-$(printf '%03d' "${chunk_index}").tar.zst"
    tar --zstd -cf "${release_dir}/${asset_name}" \
      -C "${staging_dir}" \
      --files-from "${file_list}"
    : > "${file_list}"
    chunk_index=$((chunk_index + 1))
    chunk_bytes=0
  }

  while read -r image; do
    local archive_path archive_size
    [[ -n "${image}" ]] || continue
    archive_path="repositories/registry/images/archives/$(echo "${image}" | tr '/:@' '_').tar"
    archive_size="$(stat -c '%s' "${staging_dir}/${archive_path}")"
    if ((chunk_bytes > 0 && chunk_bytes + archive_size > chunk_limit_bytes)); then
      archive_chunk
    fi
    printf '%s\n' "${archive_path}" >> "${file_list}"
    chunk_bytes=$((chunk_bytes + archive_size))
  done < "${staging_dir}/${group_list}"

  if [[ -s "${file_list}" ]]; then
    archive_chunk
  fi
  rm "${file_list}"
}

create_image_assets kubernetes
create_image_assets networking
create_image_assets extra

cp "${staging_dir}/manifest.yaml" "${release_dir}/bundle-manifest.yaml"
cp "${staging_dir}/deploy/scripts/unpack-release.sh" "${release_dir}/unpack-release.sh"
release_checksums="$(mktemp)"
(
  cd "${release_dir}"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' |
    sort -z |
    xargs -0 sha256sum > "${release_checksums}"
)
mv "${release_checksums}" "${release_dir}/SHA256SUMS"

max_asset_bytes=$((2 * 1024 * 1024 * 1024))
while IFS= read -r -d '' asset; do
  asset_size="$(stat -c '%s' "${asset}")"
  if ((asset_size >= max_asset_bytes)); then
    echo "Release asset exceeds GitHub's 2 GiB limit: ${asset}" >&2
    exit 1
  fi
done < <(find "${release_dir}" -maxdepth 1 -type f -print0)

echo "Release assets: ${release_dir}"
