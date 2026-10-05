#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:?Usage: unpack-release.sh <release-assets-dir> [output-dir]}"
output_dir="${2:-k8s-airgap}"

(
  cd "${release_dir}"
  sha256sum --check SHA256SUMS
)

mkdir -p "${output_dir}"
while IFS= read -r -d '' asset; do
  tar --zstd -xf "${asset}" -C "${output_dir}"
done < <(find "${release_dir}" -maxdepth 1 -type f -name '*.tar.zst' -print0 | sort -z)

"${output_dir}/deploy/scripts/verify-bundle.sh" "${output_dir}"
echo "Assembled bundle: ${output_dir}"
