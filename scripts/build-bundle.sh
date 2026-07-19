#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Build failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

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
require crane

mkdir -p \
  "${tools_dir}" \
  "${images_dir}" \
  "${apt_dir}/kubernetes" \
  "${out_dir}/charts" \
  "${out_dir}/manifests/upstream" \
  "${out_dir}/manifests/source" \
  "${out_dir}/scripts" \
  "${out_dir}/ansible/templates"
cp "${repo_root}/config/versions.env" "${out_dir}/manifest.env"
cp "${repo_root}/config/cluster-defaults.yaml" "${out_dir}/cluster-defaults.yaml"
cp -R "${repo_root}/ansible/." "${out_dir}/ansible/"
cp -R "${repo_root}/manifests/." "${out_dir}/manifests/source/"
cp "${repo_root}/scripts/verify-bundle.sh" "${out_dir}/scripts/verify-bundle.sh"
cp "${repo_root}/scripts/import-images-to-harbor.sh" "${out_dir}/scripts/import-images-to-harbor.sh"
cp "$(command -v crane)" "${tools_dir}/crane"

fetch() {
  local url="$1" destination="$2"
  local partial="${destination}.part"
  if [[ -s "${destination}" ]]; then
    echo "Reusing ${destination}"
    return
  fi
  curl --fail --location \
    --retry 4 --retry-all-errors \
    --connect-timeout 20 --max-time 300 \
    --continue-at - \
    --proto '=https' --tlsv1.2 \
    --output "${partial}" "${url}"
  mv "${partial}" "${destination}"
}

arch=amd64
fetch "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${arch}/kubeadm" "${tools_dir}/kubeadm"
fetch "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${arch}/kubectl" "${tools_dir}/kubectl"
fetch "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${arch}/kubelet" "${tools_dir}/kubelet"
chmod 0755 "${tools_dir}/kubeadm" "${tools_dir}/kubectl" "${tools_dir}/kubelet"

if [[ ! -x "${tools_dir}/helm" ]]; then
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "${tools_dir}/helm.tar.gz"
  tar -xzf "${tools_dir}/helm.tar.gz" -C "${tools_dir}"
  mv "${tools_dir}/linux-amd64/helm" "${tools_dir}/helm"
  rm -rf "${tools_dir}/linux-amd64" "${tools_dir}/helm.tar.gz"
fi

if [[ ! -x "${tools_dir}/k9s" ]]; then
  fetch "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" "${tools_dir}/k9s.tar.gz"
  tar -xzf "${tools_dir}/k9s.tar.gz" -C "${tools_dir}" k9s
  rm "${tools_dir}/k9s.tar.gz"
fi

if [[ ! -x "${tools_dir}/crictl" ]]; then
  fetch "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" "${tools_dir}/crictl.tar.gz"
  tar -xzf "${tools_dir}/crictl.tar.gz" -C "${tools_dir}"
  rm "${tools_dir}/crictl.tar.gz"
fi

fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" "${tools_dir}/cni-plugins.tgz"
fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" "${tools_dir}/containerd.tar.gz"
fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" "${tools_dir}/runc"
chmod 0755 "${tools_dir}/runc"

flannel_manifest="${out_dir}/manifests/upstream/flannel.yaml"
local_path_manifest="${out_dir}/manifests/upstream/local-path-provisioner.yaml"
fetch "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" "${flannel_manifest}"
fetch "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" "${local_path_manifest}"

sed \
  -e "s|ghcr.io/flannel-io/flannel:${FLANNEL_VERSION}|{{ harbor_registry }}/{{ harbor_project }}/flannel:${FLANNEL_VERSION}|g" \
  -e "s|ghcr.io/flannel-io/flannel-cni-plugin:${FLANNEL_CNI_PLUGIN_VERSION}|{{ harbor_registry }}/{{ harbor_project }}/flannel-cni-plugin:${FLANNEL_CNI_PLUGIN_VERSION}|g" \
  -e 's|"10.244.0.0/16"|"{{ pod_subnet }}"|g' \
  "${flannel_manifest}" > "${out_dir}/ansible/templates/flannel.yaml.j2"

sed \
  -e "s|docker.io/rancher/local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}|{{ harbor_registry }}/{{ harbor_project }}/local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}|g" \
  -e "s|docker.io/library/busybox|{{ harbor_registry }}/{{ harbor_project }}/busybox:${BUSYBOX_VERSION}|g" \
  -e 's|/opt/local-path-provisioner|{{ local_path }}|g' \
  "${local_path_manifest}" > "${out_dir}/ansible/templates/local-path-provisioner.yaml.j2"

if grep -Eq '^[[:space:]]*image:[[:space:]]+(docker\.io|ghcr\.io|registry\.k8s\.io)' \
  "${out_dir}/ansible/templates/flannel.yaml.j2" \
  "${out_dir}/ansible/templates/local-path-provisioner.yaml.j2"; then
  echo "Generated manifests contain unresolved external image references" >&2
  exit 1
fi

"${tools_dir}/kubeadm" config images list --kubernetes-version "${KUBERNETES_VERSION}" > "${out_dir}/images.txt"
printf 'ghcr.io/flannel-io/flannel:%s\n' "${FLANNEL_VERSION}" >> "${out_dir}/images.txt"
printf 'ghcr.io/flannel-io/flannel-cni-plugin:%s\n' "${FLANNEL_CNI_PLUGIN_VERSION}" >> "${out_dir}/images.txt"
printf 'docker.io/rancher/local-path-provisioner:%s\n' "${LOCAL_PATH_PROVISIONER_VERSION}" >> "${out_dir}/images.txt"
printf 'docker.io/library/busybox:%s\n' "${BUSYBOX_VERSION}" >> "${out_dir}/images.txt"
grep -Ev '^#|^$' "${repo_root}/config/extra-images.txt" >> "${out_dir}/images.txt" || true
sort -u -o "${out_dir}/images.txt" "${out_dir}/images.txt"

while read -r image; do
  name="$(echo "${image}" | tr '/:@' '_')"
  crane pull --platform linux/amd64 "${image}" "${images_dir}/${name}.tar"
done < "${out_dir}/images.txt"

(cd "${out_dir}" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar --zstd -cf "${out_dir}.tar.zst" -C "$(dirname "${out_dir}")" "$(basename "${out_dir}")"
echo "Created ${out_dir}.tar.zst"
