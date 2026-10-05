#!/usr/bin/env bash
set -Eeuo pipefail
bundle_dir="${1:?Usage: verify-bundle.sh <unpacked-bundle-directory>}"
cd "${bundle_dir}"
sha256sum --check SHA256SUMS

required_files=(
  manifest.yaml
  manifest.env
  repositories/apt/apt-repo-debian12-amd64.tar.gz
  repositories/files/files.list
  repositories/registry/mapping.yaml
  repositories/registry/images/images.txt
  repositories/python/requirements.txt
  repositories/python/required-collections.txt
  installers/kubespray/source/cluster.yml
  installers/kubespray/source/galaxy.yml
  installers/kubespray/source/requirements.txt
  tools/kubeadm
  tools/kubectl
  tools/kubelet
  tools/windows-amd64/kubectl.exe
  tools/windows-amd64/k9s.exe
)

for required_file in "${required_files[@]}"; do
  [[ -s "${required_file}" ]] || {
    echo "Required bundle file is missing or empty: ${required_file}" >&2
    exit 1
  }
done

while read -r file_url; do
  [[ -n "${file_url}" ]] || continue
  relative_path="${file_url#https://}"
  [[ -s "repositories/files/content/${relative_path}" ]] || {
    echo "Kubespray file is missing or empty: ${relative_path}" >&2
    exit 1
  }
done < repositories/files/files.list

find repositories/python/wheels -maxdepth 1 -type f | grep -q . || {
  echo "Python wheelhouse is empty" >&2
  exit 1
}

while read -r image; do
  [[ -n "${image}" ]] || continue
  archive="repositories/registry/images/archives/$(echo "${image}" | tr '/:@' '_').tar"
  [[ -s "${archive}" ]] || {
    echo "Image archive is missing or empty: ${archive}" >&2
    exit 1
  }
done < repositories/registry/images/images.txt

echo "Bundle structure: OK"
