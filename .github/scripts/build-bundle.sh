#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Build failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/config/versions.env"
out_dir="${1:-${repo_root}/dist/k8s-airgap-${KUBERNETES_VERSION}-debian12-amd64}"
tools_dir="${out_dir}/tools"
repositories_dir="${out_dir}/repositories"
apt_repository_dir="${repositories_dir}/apt"
registry_repository_dir="${repositories_dir}/registry"
images_repository_dir="${registry_repository_dir}/images"
images_dir="${images_repository_dir}/archives"
images_list="${images_repository_dir}/images.txt"
image_groups_dir="${images_repository_dir}/groups"
kubernetes_images_list="${image_groups_dir}/kubernetes.txt"
networking_images_list="${image_groups_dir}/networking.txt"
storage_images_list="${image_groups_dir}/storage.txt"
platform_images_list="${image_groups_dir}/platform.txt"
extra_images_list="${image_groups_dir}/extra.txt"
charts_repository_dir="${registry_repository_dir}/charts"
charts_dir="${charts_repository_dir}/archives"
deploy_scripts_dir="${out_dir}/deploy/scripts"
infrastructure_dir="${out_dir}/deploy/infrastructure"
nodes_dir="${out_dir}/deploy/nodes"
platform_dir="${out_dir}/deploy/platform"

require() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
require curl
require tar
require sha256sum
require crane
require docker
require gzip
require unzip
require zstd

mkdir -p \
  "${tools_dir}" \
  "${tools_dir}/windows-amd64" \
  "${images_dir}" \
  "${image_groups_dir}" \
  "${charts_dir}" \
  "${charts_repository_dir}/values" \
  "${apt_repository_dir}" \
  "${platform_dir}/manifests/upstream" \
  "${platform_dir}/manifests/source" \
  "${deploy_scripts_dir}" \
  "${nodes_dir}/ansible/templates" \
  "${infrastructure_dir}/apt" \
  "${infrastructure_dir}/harbor" \
  "${out_dir}/config"
# Prevent obsolete Flannel artifacts from surviving when a local build reuses
# an existing output directory created by an older revision.
rm -f \
  "${platform_dir}/manifests/upstream/flannel.yaml" \
  "${nodes_dir}/ansible/templates/flannel.yaml.j2"
cp "${repo_root}/config/versions.env" "${out_dir}/manifest.env"
cp "${repo_root}/config/cluster-defaults.yaml" "${out_dir}/cluster-defaults.yaml"
cp "${repo_root}/config/registries.yaml" "${registry_repository_dir}/mapping.yaml"
cp "${repo_root}/README.md" "${out_dir}/README.md"
cp -R "${repo_root}/deploy/nodes/ansible/." "${nodes_dir}/ansible/"
cp -R "${repo_root}/deploy/platform/manifests/." "${platform_dir}/manifests/source/"
cp "${repo_root}/deploy/platform/charts/charts.lock" "${charts_repository_dir}/charts.lock"
cp -R "${repo_root}/deploy/platform/charts/values/." "${charts_repository_dir}/values/"
cp "${repo_root}/deploy/infrastructure/compose.yaml" "${infrastructure_dir}/compose.yaml"
cp "${repo_root}/deploy/infrastructure/.env.example" "${infrastructure_dir}/.env.example"
cp "${repo_root}/deploy/infrastructure/apt/Dockerfile" "${infrastructure_dir}/apt/Dockerfile"
cp "${repo_root}/deploy/infrastructure/apt/nginx.conf" "${infrastructure_dir}/apt/nginx.conf"
cp "${repo_root}/config/packages.txt" "${out_dir}/config/packages.txt"
cp -R "${repo_root}/deploy/scripts/." "${deploy_scripts_dir}/"
cp -R "${repo_root}/deploy/infrastructure/scripts/." "${infrastructure_dir}/scripts/"
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

if [[ ! -x "${tools_dir}/vault" ]]; then
  vault_archive="vault_${VAULT_VERSION}_linux_amd64.zip"
  fetch \
    "https://releases.hashicorp.com/vault/${VAULT_VERSION}/${vault_archive}" \
    "${tools_dir}/vault.zip"
  fetch \
    "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS" \
    "${tools_dir}/vault.SHA256SUMS"
  vault_expected_sha="$(awk -v archive="${vault_archive}" '$2 == archive { print $1 }' \
    "${tools_dir}/vault.SHA256SUMS")"
  vault_actual_sha="$(sha256sum "${tools_dir}/vault.zip" | awk '{ print $1 }')"
  [[ -n "${vault_expected_sha}" && "${vault_actual_sha}" == "${vault_expected_sha}" ]] || {
    echo "Vault archive checksum verification failed." >&2
    exit 1
  }
  unzip -q "${tools_dir}/vault.zip" vault -d "${tools_dir}"
  rm "${tools_dir}/vault.zip" "${tools_dir}/vault.SHA256SUMS"
  chmod 0755 "${tools_dir}/vault"
fi

if [[ ! -f "${tools_dir}/windows-amd64/kubectl.exe" ]]; then
  fetch \
    "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/windows/amd64/kubectl.exe" \
    "${tools_dir}/windows-amd64/kubectl.exe"
fi

if [[ ! -f "${tools_dir}/windows-amd64/k9s.exe" ]]; then
  fetch \
    "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Windows_amd64.zip" \
    "${tools_dir}/windows-amd64/k9s.zip"
  unzip -q "${tools_dir}/windows-amd64/k9s.zip" \
    k9s.exe -d "${tools_dir}/windows-amd64"
  rm "${tools_dir}/windows-amd64/k9s.zip"
fi

if [[ ! -x "${tools_dir}/crictl" ]]; then
  fetch "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" "${tools_dir}/crictl.tar.gz"
  tar -xzf "${tools_dir}/crictl.tar.gz" -C "${tools_dir}"
  rm "${tools_dir}/crictl.tar.gz"
fi

fetch \
  "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  "${tools_dir}/docker-compose"
chmod 0755 "${tools_dir}/docker-compose"

fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" "${tools_dir}/cni-plugins.tgz"
fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" "${tools_dir}/containerd.tar.gz"
fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" "${tools_dir}/runc"
chmod 0755 "${tools_dir}/runc"

harbor_installer="harbor-offline-installer-${HARBOR_VERSION}.tgz"
fetch \
  "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${harbor_installer}" \
  "${infrastructure_dir}/harbor/${harbor_installer}"

apt_repo_image="k8s-airgap/apt-repo:debian12-amd64"
docker build \
  --file "${repo_root}/deploy/infrastructure/apt/Dockerfile" \
  --tag "${apt_repo_image}" \
  "${repo_root}"
docker save "${apt_repo_image}" | gzip -9 > "${apt_repository_dir}/apt-repo-debian12-amd64.tar.gz"
mkdir -p "${apt_repository_dir}/repository"
docker run --rm --entrypoint tar "${apt_repo_image}" \
  -C /usr/share/nginx/html/debian -cf - . |
  tar -xf - -C "${apt_repository_dir}/repository"

pull_chart() {
  local name="$1" repository="$2" version="$3"
  if [[ -f "${charts_dir}/${name}-${version}.tgz" ]]; then
    echo "Reusing ${name} chart ${version}"
    return
  fi
  "${tools_dir}/helm" pull "${name}" --repo "${repository}" \
    --version "${version}" --destination "${charts_dir}"
}

pull_chart metallb https://metallb.github.io/metallb "${METALLB_VERSION}"
pull_chart traefik https://traefik.github.io/charts "${TRAEFIK_CHART_VERSION}"
pull_chart cilium https://helm.cilium.io "${CILIUM_CHART_VERSION}"
pull_chart csi-driver-nfs https://kubernetes-csi.github.io/csi-driver-nfs \
  "${NFS_CSI_CHART_VERSION}"
pull_chart metrics-server https://kubernetes-sigs.github.io/metrics-server \
  "${METRICS_SERVER_CHART_VERSION}"
pull_chart cert-manager https://charts.jetstack.io \
  "${CERT_MANAGER_CHART_VERSION}"
pull_chart argo-cd https://argoproj.github.io/argo-helm \
  "${ARGO_CD_CHART_VERSION}"

local_path_manifest="${platform_dir}/manifests/upstream/local-path-provisioner.yaml"
gateway_api_manifest="${platform_dir}/manifests/upstream/gateway-api-standard.yaml"
fetch "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" "${local_path_manifest}"
fetch "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" "${gateway_api_manifest}"

sed \
  -e "s|docker.io/library/busybox|docker.io/library/busybox:${BUSYBOX_VERSION}|g" \
  -e 's|/opt/local-path-provisioner|{{ local_path }}|g' \
  "${local_path_manifest}" > "${nodes_dir}/ansible/templates/local-path-provisioner.yaml.j2"

"${tools_dir}/kubeadm" config images list --kubernetes-version "${KUBERNETES_VERSION}" > "${kubernetes_images_list}"
{
  printf 'docker.io/rancher/local-path-provisioner:%s\n' "${LOCAL_PATH_PROVISIONER_VERSION}"
  printf 'docker.io/library/busybox:%s\n' "${BUSYBOX_VERSION}"
} >> "${kubernetes_images_list}"
sort -u -o "${kubernetes_images_list}" "${kubernetes_images_list}"

: > "${networking_images_list}"
"${tools_dir}/helm" template offline \
  "${charts_dir}/cilium-${CILIUM_CHART_VERSION}.tgz" \
  --namespace kube-system --include-crds \
  --kube-version "${KUBERNETES_VERSION#v}" \
  --values "${charts_repository_dir}/values/cilium.yaml" |
  awk '/^[[:space:]]*image:[[:space:]]*/ { image=$2; gsub(/["'"'"']/, "", image); print image }' \
  >> "${networking_images_list}"

for chart in \
  "${charts_dir}/metallb-${METALLB_VERSION}.tgz" \
  "${charts_dir}/traefik-${TRAEFIK_CHART_VERSION}.tgz"; do
  "${tools_dir}/helm" template offline "${chart}" --include-crds \
    --kube-version "${KUBERNETES_VERSION#v}" |
    awk '/^[[:space:]]*image:[[:space:]]*/ { image=$2; gsub(/["'"'"'"'"'"']/, "", image); print image }' \
    >> "${networking_images_list}"
done
sort -u -o "${networking_images_list}" "${networking_images_list}"
comm -23 "${networking_images_list}" "${kubernetes_images_list}" > "${networking_images_list}.unique"
mv "${networking_images_list}.unique" "${networking_images_list}"

"${tools_dir}/helm" template offline \
  "${charts_dir}/csi-driver-nfs-${NFS_CSI_CHART_VERSION}.tgz" \
  --namespace kube-system --include-crds \
  --values "${charts_repository_dir}/values/csi-driver-nfs.yaml" |
  awk '/^[[:space:]]*image:[[:space:]]*/ { image=$2; gsub(/["'"'"']/, "", image); print image }' \
  > "${storage_images_list}"
sort -u -o "${storage_images_list}" "${storage_images_list}"
cat "${kubernetes_images_list}" "${networking_images_list}" | sort -u \
  > "${image_groups_dir}/assigned.txt"
comm -23 "${storage_images_list}" "${image_groups_dir}/assigned.txt" \
  > "${storage_images_list}.unique"
mv "${storage_images_list}.unique" "${storage_images_list}"

: > "${platform_images_list}"
for chart_and_values in \
  "metrics-server-${METRICS_SERVER_CHART_VERSION}.tgz metrics-server.yaml kube-system" \
  "cert-manager-${CERT_MANAGER_CHART_VERSION}.tgz cert-manager.yaml cert-manager" \
  "argo-cd-${ARGO_CD_CHART_VERSION}.tgz argo-cd.yaml argocd"; do
  read -r chart values namespace <<< "${chart_and_values}"
  "${tools_dir}/helm" template offline "${charts_dir}/${chart}" \
    --namespace "${namespace}" --include-crds \
    --kube-version "${KUBERNETES_VERSION#v}" \
    --values "${charts_repository_dir}/values/${values}" |
    awk '/^[[:space:]]*image:[[:space:]]*/ { image=$2; gsub(/["'"'"']/, "", image); print image }' \
    >> "${platform_images_list}"
done
# cert-manager creates ACME HTTP01 solver Pods dynamically, so this image is a
# command argument in the rendered controller rather than a Pod image field.
printf 'quay.io/jetstack/cert-manager-acmesolver:%s\n' \
  "${CERT_MANAGER_CHART_VERSION}" >> "${platform_images_list}"
sort -u -o "${platform_images_list}" "${platform_images_list}"
cat "${kubernetes_images_list}" "${networking_images_list}" \
  "${storage_images_list}" | sort -u > "${image_groups_dir}/assigned.txt"
comm -23 "${platform_images_list}" "${image_groups_dir}/assigned.txt" \
  > "${platform_images_list}.unique"
mv "${platform_images_list}.unique" "${platform_images_list}"

grep -Ev '^#|^$' "${repo_root}/config/extra-images.txt" | sort -u > "${extra_images_list}" || true
cat "${kubernetes_images_list}" "${networking_images_list}" \
  "${storage_images_list}" "${platform_images_list}" |
  sort -u > "${image_groups_dir}/assigned.txt"
comm -23 "${extra_images_list}" "${image_groups_dir}/assigned.txt" > "${extra_images_list}.unique"
mv "${extra_images_list}.unique" "${extra_images_list}"
rm "${image_groups_dir}/assigned.txt"

cat "${kubernetes_images_list}" "${networking_images_list}" \
  "${storage_images_list}" "${platform_images_list}" "${extra_images_list}" |
  sort -u > "${images_list}"

if grep -Ev '^(docker\.io|ghcr\.io|quay\.io|registry\.k8s\.io)/[^[:space:]]+:[^[:space:]]+$' "${images_list}"; then
  echo "Every image must use a pinned tag and a configured source registry" >&2
  exit 1
fi

while read -r image; do
  name="$(echo "${image}" | tr '/:@' '_')"
  crane pull --platform linux/amd64 "${image}" "${images_dir}/${name}.tar"
done < "${images_list}"

{
  printf '%s\n' '---'
  printf '%s\n' 'schema_version: 1'
  printf 'bundle: k8s-airgap-%s-debian12-amd64\n' "${KUBERNETES_VERSION}"
  printf '%s\n' 'target:'
  printf '%s\n' '  distribution: debian'
  printf '%s\n' '  release: bookworm'
  printf '%s\n' '  major_version: 12'
  printf '%s\n' '  architecture: amd64'
  printf '%s\n' 'repositories:'
  printf '%s\n' '  apt: repositories/apt'
  printf '%s\n' '  images: repositories/registry/images'
  printf '%s\n' '  charts: repositories/registry/charts'
  printf '%s\n' 'release_assets:'
  printf '%s\n' '  - bootstrap.tar.zst'
  printf '%s\n' '  - automation.tar.zst'
  printf '%s\n' '  - apt-debian12-amd64.tar.zst'
  printf '%s\n' '  - tools-linux-amd64.tar.zst'
  printf '%s\n' '  - tools-windows-amd64.tar.zst'
  printf '%s\n' '  - harbor-offline.tar.zst'
  printf '%s\n' '  - charts-platform.tar.zst'
  printf '%s\n' 'release_asset_patterns:'
  printf '%s\n' '  - images-kubernetes-*.tar.zst'
  printf '%s\n' '  - images-networking-*.tar.zst'
  printf '%s\n' '  - images-storage-*.tar.zst'
  printf '%s\n' '  - images-platform-*.tar.zst'
  printf '%s\n' 'optional_release_asset_patterns:'
  printf '%s\n' '  - images-extra-*.tar.zst'
} > "${out_dir}/manifest.yaml"

bundle_checksums="$(mktemp)"
(
  cd "${out_dir}"
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum > "${bundle_checksums}"
)
mv "${bundle_checksums}" "${out_dir}/SHA256SUMS"
release_dir="${repo_root}/dist/release-${KUBERNETES_VERSION#v}-debian12-amd64"
"${repo_root}/.github/scripts/package-release.sh" "${out_dir}" "${release_dir}"
echo "Created modular release assets in ${release_dir}"
