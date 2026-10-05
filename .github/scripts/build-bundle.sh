#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Build failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/config/versions.env"
out_dir="${1:-${repo_root}/dist/k8s-airgap-${KUBERNETES_VERSION}-debian12-amd64}"
tools_dir="${out_dir}/tools"
repositories_dir="${out_dir}/repositories"
apt_repository_dir="${repositories_dir}/apt"
files_repository_dir="${repositories_dir}/files"
registry_repository_dir="${repositories_dir}/registry"
images_repository_dir="${registry_repository_dir}/images"
images_dir="${images_repository_dir}/archives"
images_list="${images_repository_dir}/images.txt"
image_groups_dir="${images_repository_dir}/groups"
kubernetes_images_list="${image_groups_dir}/kubernetes.txt"
networking_images_list="${image_groups_dir}/networking.txt"
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
require python3
python3 -m pip --version >/dev/null || {
  echo "Missing required Python module: pip" >&2
  exit 1
}

mkdir -p \
  "${tools_dir}" \
  "${tools_dir}/windows-amd64" \
  "${images_dir}" \
  "${image_groups_dir}" \
  "${charts_dir}" \
  "${charts_repository_dir}/values" \
  "${apt_repository_dir}" \
  "${files_repository_dir}/content" \
  "${repositories_dir}/python/wheels" \
  "${platform_dir}/manifests/upstream" \
  "${platform_dir}/manifests/source" \
  "${deploy_scripts_dir}" \
  "${nodes_dir}/ansible/templates" \
  "${infrastructure_dir}/apt" \
  "${infrastructure_dir}/harbor" \
  "${out_dir}/installers/kubespray/source" \
  "${out_dir}/deploy/kubespray" \
  "${out_dir}/config"
cp "${repo_root}/config/versions.env" "${out_dir}/manifest.env"
cp "${repo_root}/config/cluster-defaults.yaml" "${out_dir}/cluster-defaults.yaml"
cp "${repo_root}/config/registries.yaml" "${registry_repository_dir}/mapping.yaml"
cp "${repo_root}/README.md" "${out_dir}/README.md"
cp "${repo_root}/INSTALL.md" "${out_dir}/INSTALL.md"
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
cp -R "${repo_root}/deploy/kubespray/." "${out_dir}/deploy/kubespray/"
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

fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" "${tools_dir}/cni-plugins.tgz"
fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" "${tools_dir}/containerd.tar.gz"
fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" "${tools_dir}/runc"
chmod 0755 "${tools_dir}/runc"

harbor_installer="harbor-offline-installer-${HARBOR_VERSION}.tgz"
fetch \
  "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/${harbor_installer}" \
  "${infrastructure_dir}/harbor/${harbor_installer}"

kubespray_archive="${out_dir}/installers/kubespray/kubespray-${KUBESPRAY_VERSION}.tar.gz"
fetch \
  "https://github.com/kubernetes-sigs/kubespray/archive/refs/tags/${KUBESPRAY_VERSION}.tar.gz" \
  "${kubespray_archive}"
tar -xzf "${kubespray_archive}" \
  --strip-components=1 \
  -C "${out_dir}/installers/kubespray/source"

python3 -m pip download \
  --disable-pip-version-check \
  --dest "${repositories_dir}/python/wheels" \
  --only-binary=:all: \
  --platform manylinux_2_28_x86_64 \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 311 \
  --abi cp311 \
  --requirement "${out_dir}/installers/kubespray/source/requirements.txt"
cp \
  "${out_dir}/installers/kubespray/source/requirements.txt" \
  "${repositories_dir}/python/requirements.txt"

builder_venv="$(mktemp -d)"
python3 -m venv "${builder_venv}/venv"
"${builder_venv}/venv/bin/pip" install \
  --disable-pip-version-check \
  --requirement "${out_dir}/installers/kubespray/source/requirements.txt"
installed_collections="${builder_venv}/installed-collections.json"
"${builder_venv}/venv/bin/ansible-galaxy" collection list --format json \
  > "${installed_collections}"
"${builder_venv}/venv/bin/python" - \
  "${out_dir}/installers/kubespray/source/galaxy.yml" \
  "${installed_collections}" \
  "${repositories_dir}/python/required-collections.txt" <<'PY'
import json
import sys

import yaml
from packaging.specifiers import SpecifierSet
from packaging.version import Version

galaxy_path, installed_path, output_path = sys.argv[1:]
with open(galaxy_path, encoding="utf-8") as stream:
    required = yaml.safe_load(stream).get("dependencies", {})
with open(installed_path, encoding="utf-8") as stream:
    collection_paths = json.load(stream)

installed = {}
for collections in collection_paths.values():
    installed.update(
        (name, metadata["version"])
        for name, metadata in collections.items()
    )

errors = []
with open(output_path, "w", encoding="utf-8") as stream:
    for name, constraint in sorted(required.items()):
        version = installed.get(name)
        if version is None:
            errors.append(f"missing Ansible collection: {name} ({constraint})")
            continue
        if Version(version) not in SpecifierSet(str(constraint)):
            errors.append(
                f"incompatible Ansible collection: {name} {version} ({constraint})"
            )
        stream.write(f"{name}\t{constraint}\t{version}\n")

if errors:
    raise SystemExit("\n".join(errors))
PY

(
  cd "${out_dir}/installers/kubespray/source"
  PATH="${builder_venv}/venv/bin:${PATH}" \
    bash contrib/offline/generate_list.sh \
      -i "${out_dir}/deploy/kubespray/inventory/lab/hosts.yaml"
)
cp \
  "${out_dir}/installers/kubespray/source/contrib/offline/temp/files.list" \
  "${files_repository_dir}/files.list"
cp \
  "${out_dir}/installers/kubespray/source/contrib/offline/temp/images.list" \
  "${images_repository_dir}/kubespray-images.txt"
rm -rf "${builder_venv}"

while read -r file_url; do
  [[ -n "${file_url}" ]] || continue
  case "${file_url}" in
    https://*) ;;
    *)
      echo "Kubespray generated a non-HTTPS download URL: ${file_url}" >&2
      exit 1
      ;;
  esac
  relative_path="${file_url#https://}"
  [[ "${relative_path}" != *..* && "${relative_path}" != *\?* ]] || {
    echo "Unsafe or unsupported download URL: ${file_url}" >&2
    exit 1
  }
  destination="${files_repository_dir}/content/${relative_path}"
  mkdir -p "$(dirname "${destination}")"
  fetch "${file_url}" "${destination}"
done < "${files_repository_dir}/files.list"

apt_repo_image="k8s-airgap/apt-repo:debian12-amd64"
docker build \
  --file "${repo_root}/deploy/infrastructure/apt/Dockerfile" \
  --tag "${apt_repo_image}" \
  "${repo_root}"
docker save "${apt_repo_image}" | gzip -9 > "${apt_repository_dir}/apt-repo-debian12-amd64.tar.gz"

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

flannel_manifest="${platform_dir}/manifests/upstream/flannel.yaml"
local_path_manifest="${platform_dir}/manifests/upstream/local-path-provisioner.yaml"
gateway_api_manifest="${platform_dir}/manifests/upstream/gateway-api-standard.yaml"
fetch "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" "${flannel_manifest}"
fetch "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" "${local_path_manifest}"
fetch "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" "${gateway_api_manifest}"

sed \
  -e 's|"10.244.0.0/16"|"{{ pod_subnet }}"|g' \
  "${flannel_manifest}" > "${nodes_dir}/ansible/templates/flannel.yaml.j2"

sed \
  -e "s|docker.io/library/busybox|docker.io/library/busybox:${BUSYBOX_VERSION}|g" \
  -e 's|/opt/local-path-provisioner|{{ local_path }}|g' \
  "${local_path_manifest}" > "${nodes_dir}/ansible/templates/local-path-provisioner.yaml.j2"

"${tools_dir}/kubeadm" config images list --kubernetes-version "${KUBERNETES_VERSION}" > "${kubernetes_images_list}"
cat "${images_repository_dir}/kubespray-images.txt" >> "${kubernetes_images_list}"
printf 'ghcr.io/flannel-io/flannel:%s\n' "${FLANNEL_VERSION}" >> "${kubernetes_images_list}"
printf 'ghcr.io/flannel-io/flannel-cni-plugin:%s\n' "${FLANNEL_CNI_PLUGIN_VERSION}" >> "${kubernetes_images_list}"
printf 'docker.io/rancher/local-path-provisioner:%s\n' "${LOCAL_PATH_PROVISIONER_VERSION}" >> "${kubernetes_images_list}"
printf 'docker.io/library/busybox:%s\n' "${BUSYBOX_VERSION}" >> "${kubernetes_images_list}"
sort -u -o "${kubernetes_images_list}" "${kubernetes_images_list}"

for chart in \
  "${charts_dir}/metallb-${METALLB_VERSION}.tgz" \
  "${charts_dir}/traefik-${TRAEFIK_CHART_VERSION}.tgz"; do
  "${tools_dir}/helm" template offline "${chart}" --include-crds |
    awk '/^[[:space:]]*image:[[:space:]]*/ { image=$2; gsub(/["'"'"'"'"'"']/, "", image); print image }' \
    >> "${networking_images_list}"
done
sort -u -o "${networking_images_list}" "${networking_images_list}"
comm -23 "${networking_images_list}" "${kubernetes_images_list}" > "${networking_images_list}.unique"
mv "${networking_images_list}.unique" "${networking_images_list}"

grep -Ev '^#|^$' "${repo_root}/config/extra-images.txt" | sort -u > "${extra_images_list}" || true
cat "${kubernetes_images_list}" "${networking_images_list}" | sort -u > "${image_groups_dir}/assigned.txt"
comm -23 "${extra_images_list}" "${image_groups_dir}/assigned.txt" > "${extra_images_list}.unique"
mv "${extra_images_list}.unique" "${extra_images_list}"
rm "${image_groups_dir}/assigned.txt"

cat "${kubernetes_images_list}" "${networking_images_list}" "${extra_images_list}" |
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
  printf '%s\n' '  files: repositories/files'
  printf '%s\n' '  images: repositories/registry/images'
  printf '%s\n' '  charts: repositories/registry/charts'
  printf '%s\n' '  python: repositories/python'
  printf '%s\n' 'release_assets:'
  printf '%s\n' '  - bootstrap.tar.zst'
  printf '%s\n' '  - automation.tar.zst'
  printf '%s\n' '  - apt-debian12-amd64.tar.zst'
  printf '%s\n' '  - kubespray-offline.tar.zst'
  printf '%s\n' '  - python-ansible-debian12.tar.zst'
  printf '%s\n' '  - tools-linux-amd64.tar.zst'
  printf '%s\n' '  - tools-windows-amd64.tar.zst'
  printf '%s\n' '  - harbor-offline.tar.zst'
  printf '%s\n' '  - images-kubernetes.tar.zst'
  printf '%s\n' '  - images-networking.tar.zst'
  printf '%s\n' '  - charts-networking.tar.zst'
  printf '%s\n' 'optional_release_assets:'
  printf '%s\n' '  - images-extra.tar.zst'
} > "${out_dir}/manifest.yaml"

(cd "${out_dir}" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
release_dir="${repo_root}/dist/release-${KUBERNETES_VERSION#v}-debian12-amd64"
"${repo_root}/.github/scripts/package-release.sh" "${out_dir}" "${release_dir}"
echo "Created modular release assets in ${release_dir}"
