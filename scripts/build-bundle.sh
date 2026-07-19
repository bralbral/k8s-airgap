#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/config/versions.env"
out_dir="${1:-${repo_root}/dist/k8s-airgap-${KUBERNETES_VERSION}-debian12-amd64}"
tools_dir="${out_dir}/tools"
images_dir="${out_dir}/images"
apt_dir="${out_dir}/apt"

require() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
require curl
require tar
require sha256sum

mkdir -p "${tools_dir}" "${images_dir}" "${apt_dir}/kubernetes" "${out_dir}/charts" "${out_dir}/manifests"
cp "${repo_root}/config/versions.env" "${out_dir}/manifest.env"
cp "${repo_root}/config/cluster-defaults.yaml" "${out_dir}/cluster-defaults.yaml"

fetch() {
  local url="$1" destination="$2"
  curl --fail --location --retry 4 --proto '=https' --tlsv1.2 --output "${destination}" "${url}"
}

arch=amd64
fetch "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${arch}/kubeadm" "${tools_dir}/kubeadm"
fetch "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${arch}/kubectl" "${tools_dir}/kubectl"
fetch "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${arch}/kubelet" "${tools_dir}/kubelet"
chmod 0755 "${tools_dir}/kubeadm" "${tools_dir}/kubectl" "${tools_dir}/kubelet"

fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "${tools_dir}/helm.tar.gz"
tar -xzf "${tools_dir}/helm.tar.gz" -C "${tools_dir}"
mv "${tools_dir}/linux-amd64/helm" "${tools_dir}/helm"
rm -rf "${tools_dir}/linux-amd64" "${tools_dir}/helm.tar.gz"

fetch "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" "${tools_dir}/k9s.tar.gz"
tar -xzf "${tools_dir}/k9s.tar.gz" -C "${tools_dir}" k9s
rm "${tools_dir}/k9s.tar.gz"

fetch "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" "${tools_dir}/crictl.tar.gz"
tar -xzf "${tools_dir}/crictl.tar.gz" -C "${tools_dir}"
rm "${tools_dir}/crictl.tar.gz"

fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" "${tools_dir}/cni-plugins.tgz"
fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" "${tools_dir}/containerd.tar.gz"
fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" "${tools_dir}/runc"
chmod 0755 "${tools_dir}/runc"

"${tools_dir}/kubeadm" config images list --kubernetes-version "${KUBERNETES_VERSION}" > "${out_dir}/images.txt"
printf 'ghcr.io/flannel-io/flannel:%s\n' "${FLANNEL_VERSION}" >> "${out_dir}/images.txt"
grep -Ev '^#|^$' "${repo_root}/config/extra-images.txt" >> "${out_dir}/images.txt"
sort -u -o "${out_dir}/images.txt" "${out_dir}/images.txt"

if command -v crane >/dev/null; then
  while read -r image; do
    name="$(echo "${image}" | tr '/:@' '_')"
    crane export "${image}" "${images_dir}/${name}.tar"
  done < "${out_dir}/images.txt"
else
  echo "crane is not installed: binary assets built, image export skipped" >&2
  echo "Install crane ${CRANE_VERSION} and re-run to export images." >&2
fi

cp -R "${repo_root}/ansible" "${out_dir}/ansible"
cp -R "${repo_root}/manifests" "${out_dir}/manifests/source"
find "${out_dir}" -type f -print0 | sort -z | xargs -0 sha256sum > "${out_dir}/SHA256SUMS"
tar --zstd -cf "${out_dir}.tar.zst" -C "$(dirname "${out_dir}")" "$(basename "${out_dir}")"
echo "Created ${out_dir}.tar.zst"
