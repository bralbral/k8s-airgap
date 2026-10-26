#!/usr/bin/env bash
set -Eeuo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${repo_root}/config/versions.env"
out_dir="${1:-${repo_root}/dist/k8s-airgap-${KUBERNETES_VERSION}-debian12-amd64}"
[[ ! -e "${out_dir}" ]] || { echo "Use a new output directory: ${out_dir}" >&2; exit 1; }
for tool in curl tar sha256sum crane docker gzip zstd python3; do
  command -v "${tool}" >/dev/null || { echo "Missing ${tool}" >&2; exit 1; }
done
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
tools_dir="${out_dir}/tools"
registry="${out_dir}/repositories/registry"
images_dir="${registry}/images/archives"
groups="${registry}/images/groups"
charts="${registry}/charts/archives"
manifests="${out_dir}/deploy/platform/manifests"
mkdir -p "${tools_dir}" "${images_dir}" "${groups}" "${charts}" "${manifests}" "${out_dir}/packages"
mkdir -p "${out_dir}/deploy"
# Local VM source images are supplied separately, not copied into the bundle.
tar -C "${repo_root}/deploy" --exclude='./infrastructure/vms/vm' -cf - . | \
  tar -C "${out_dir}/deploy" -xf -
# Only versioned configuration is shipped; never package local credentials/inventory.
find "${out_dir}/deploy" -type f \( -name '.env' -o -name 'hosts.yml' \) -delete
cp -R "${repo_root}/config" "${out_dir}/config"
cp "${repo_root}/config/versions.env" "${out_dir}/manifest.env"
cp "${repo_root}/config/registries.yaml" "${registry}/mapping.yaml"
cp "${repo_root}/README.md" "${out_dir}/README.md"
cp -R "${repo_root}/docs" "${out_dir}/docs"
cp -R "${repo_root}/deploy/platform/charts/values" "${registry}/charts/values"
cp "$(command -v crane)" "${tools_dir}/crane"
# Collect infrastructure images, including MinIO.
python3 "${repo_root}/.github/scripts/collect-images.py" \
  --compose-dir "${repo_root}/deploy/infrastructure" > "${groups}/infrastructure.txt"
# Check availability before downloading large release assets.
while read -r image; do
  crane manifest "${image}" >/dev/null || {
    echo "Infrastructure image unavailable: ${image}. Select an accessible, approved image source before building." >&2
    exit 1
  }
done < "${groups}/infrastructure.txt"
fetch() {
  curl --fail --location --retry 4 --retry-all-errors --connect-timeout 20 \
    --max-time 1800 --proto '=https' --tlsv1.2 --output "$2.part" "$1"
  mv "$2.part" "$2"
}
fetch_checked() {
  fetch "$1" "$2"
  fetch "$3" "$2.sha256"
  local expected
  expected="$(awk 'NR == 1 {print $1}' "$2.sha256")"
  [[ "${expected}" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Invalid upstream SHA256: $3" >&2; exit 1; }
  printf '%s  %s\n' "${expected}" "$2" | sha256sum -c -
  rm "$2.sha256"
}
for binary in kubeadm kubelet kubectl; do
  url="https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/amd64/${binary}"
  fetch_checked "${url}" "${tools_dir}/${binary}" "${url}.sha256"
done
fetch_checked "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "${tools_dir}/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -xzf "${tools_dir}/helm.tgz" -C "${tools_dir}" linux-amd64/helm
mv "${tools_dir}/linux-amd64/helm" "${tools_dir}/helm"
rm -r "${tools_dir}/linux-amd64" "${tools_dir}/helm.tgz"
fetch "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" "${tools_dir}/crictl.tgz"
tar -xzf "${tools_dir}/crictl.tgz" -C "${tools_dir}" crictl
rm "${tools_dir}/crictl.tgz"
fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" "${tools_dir}/cni-plugins.tgz"
fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" "${tools_dir}/containerd.tar.gz"
fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" "${tools_dir}/runc"
chmod 0755 "${tools_dir}/"{kubeadm,kubelet,kubectl,crictl,runc,helm}
fetch "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz" \
  "${out_dir}/deploy/infrastructure/harbor/harbor-offline-installer-${HARBOR_VERSION}.tgz"
# Download .deb packages using an upstream Debian container; no image build.
docker run --rm --platform linux/amd64 \
  -v "${repo_root}/config:/config:ro" \
  -v "${repo_root}/.github/scripts/download-debs.sh:/download-debs.sh:ro" \
  -v "${out_dir}/packages:/output" \
  debian:12-slim bash /download-debs.sh
pull_chart() {
  "${tools_dir}/helm" pull "$1" --repo "$2" --version "$3" --destination "${charts}"
}
pull_chart cilium https://helm.cilium.io "${CILIUM_CHART_VERSION}"
pull_chart metallb https://metallb.github.io/metallb "${METALLB_VERSION}"
pull_chart argo-cd https://argoproj.github.io/argo-helm "${ARGO_CD_CHART_VERSION}"
fetch "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" "${manifests}/local-path-provisioner.yaml"
# The helper Pod image lives inside ConfigMap JSON and is missed by Pod scans.
python3 - "${manifests}/local-path-provisioner.yaml" "${BUSYBOX_VERSION}" <<'PY'
import json, sys, yaml
path, version = sys.argv[1:]
docs = list(yaml.safe_load_all(open(path)))
for doc in docs:
    if doc.get('kind') == 'ConfigMap' and 'helperPod.yaml' in doc.get('data', {}):
        helper = yaml.safe_load(doc['data']['helperPod.yaml'])
        for container in helper['spec']['containers']:
            container['image'] = 'docker.io/library/busybox:' + version
        doc['data']['helperPod.yaml'] = yaml.safe_dump(helper)
    if doc.get('kind') == 'Deployment':
        doc['spec']['template']['spec']['nodeSelector'] = {'node-role.kubernetes.io/worker': ''}
with open(path, 'w') as stream:
    yaml.safe_dump_all(docs, stream, sort_keys=False)
PY
"${tools_dir}/kubeadm" config images list --kubernetes-version "${KUBERNETES_VERSION}" > "${groups}/kubernetes.txt"
# Keep the sandbox image in containerd consistent with kubeadm's release.
expected_pause="$(sed -n 's/^pause_image: //p' "${repo_root}/deploy/ansible/inventory/group_vars/all.yml")"
grep -Fx "${expected_pause}" "${groups}/kubernetes.txt" >/dev/null || {
  echo "Update pause_image to match kubeadm ${KUBERNETES_VERSION}." >&2; exit 1;
}
for group in networking storage platform; do : > "${groups}/${group}.txt"; done
for chart_and_group in "cilium ${CILIUM_CHART_VERSION} networking" "metallb ${METALLB_VERSION} networking" "argo-cd ${ARGO_CD_CHART_VERSION} platform"; do
  read -r chart version group <<< "${chart_and_group}"
  args=()
  [[ ! -f "${registry}/charts/values/${chart}.yaml" ]] || args+=(--values "${registry}/charts/values/${chart}.yaml")
  "${tools_dir}/helm" template offline "${charts}/${chart}-${version}.tgz" \
    --kube-version "${KUBERNETES_VERSION#v}" --include-crds "${args[@]}" |
    python3 "${repo_root}/.github/scripts/collect-images.py" >> "${groups}/${group}.txt"
done
python3 "${repo_root}/.github/scripts/collect-images.py" < "${manifests}/local-path-provisioner.yaml" > "${groups}/storage.txt"
printf 'docker.io/library/busybox:%s\n' "${BUSYBOX_VERSION}" >> "${groups}/storage.txt"
printf 'quay.io/prometheus/prometheus:%s\nquay.io/prometheus/node-exporter:%s\nregistry.k8s.io/kube-state-metrics/kube-state-metrics:%s\n' \
  "${PROMETHEUS_VERSION}" "${NODE_EXPORTER_VERSION}" "${KUBE_STATE_METRICS_VERSION}" >> "${groups}/platform.txt"
for group in kubernetes networking storage platform infrastructure; do sort -u -o "${groups}/${group}.txt" "${groups}/${group}.txt"; done
cat "${groups}/"{kubernetes,networking,storage,platform}.txt | sort -u > "${registry}/images/images.txt"
cat "${registry}/images/images.txt" "${groups}/infrastructure.txt" | sort -u | while read -r image; do
  crane pull --platform linux/amd64 "${image}" "${images_dir}/$(echo "${image}" | tr '/:@' '_').tar"
done
printf '%s\n' '---' 'schema_version: 2' 'target: debian12-amd64' > "${out_dir}/manifest.yaml"
checksums="$(mktemp)"
(cd "${out_dir}"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > "${checksums}")
mv "${checksums}" "${out_dir}/SHA256SUMS"
"${repo_root}/deploy/scripts/verify-bundle.sh" "${out_dir}"
"${repo_root}/.github/scripts/package-release.sh" "${out_dir}" "${repo_root}/dist/release-${KUBERNETES_VERSION#v}-debian12-amd64"
