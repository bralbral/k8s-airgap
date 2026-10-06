#!/usr/bin/env bash
set -Eeuo pipefail
bundle_dir="${1:?Usage: verify-bundle.sh <unpacked-bundle-directory>}"
cd "${bundle_dir}"
sha256sum --check SHA256SUMS

required_files=(
  manifest.yaml
  manifest.env
  repositories/apt/apt-repo-debian12-amd64.tar.gz
  repositories/apt/repository/dists/bookworm/Release
  repositories/apt/repository/dists/bookworm/main/binary-amd64/Packages.gz
  repositories/registry/mapping.yaml
  repositories/registry/images/images.txt
  repositories/registry/images/groups/storage.txt
  repositories/registry/images/groups/platform.txt
  repositories/registry/charts/charts.lock
  repositories/registry/charts/values/cilium.yaml
  repositories/registry/charts/values/metrics-server.yaml
  repositories/registry/charts/values/cert-manager.yaml
  repositories/registry/charts/values/argo-cd.yaml
  deploy/nodes/ansible/templates/local-path-provisioner.yaml.j2
  deploy/nodes/ansible/templates/cert-manager-vault-clusterissuer.yaml.j2
  deploy/nodes/ansible/playbooks/configure-cilium.yml
  deploy/nodes/ansible/playbooks/install-platform.yml
  deploy/nodes/ansible/playbooks/join-control-planes.yml
  deploy/infrastructure/scripts/install-vault.sh
  deploy/infrastructure/scripts/initialize-vault.sh
  deploy/infrastructure/scripts/unseal-vault.sh
  deploy/infrastructure/scripts/backup-vault.sh
  deploy/infrastructure/scripts/configure-vault-kubernetes.sh
  deploy/platform/manifests/upstream/gateway-api-standard.yaml
  tools/cni-plugins.tgz
  tools/containerd.tar.gz
  tools/windows-amd64/kubectl.exe
  tools/windows-amd64/k9s.exe
)

for required_file in "${required_files[@]}"; do
  [[ -s "${required_file}" ]] || {
    echo "Required bundle file is missing or empty: ${required_file}" >&2
    exit 1
  }
done

for required_pattern in \
  'deploy/infrastructure/harbor/harbor-offline-installer-*.tgz' \
  'repositories/registry/charts/archives/metallb-*.tgz' \
  'repositories/registry/charts/archives/traefik-*.tgz' \
  'repositories/registry/charts/archives/cilium-*.tgz' \
  'repositories/registry/charts/archives/csi-driver-nfs-*.tgz' \
  'repositories/registry/charts/archives/metrics-server-*.tgz' \
  'repositories/registry/charts/archives/cert-manager-*.tgz' \
  'repositories/registry/charts/archives/argo-cd-*.tgz'; do
  compgen -G "${required_pattern}" >/dev/null || {
    echo "Required bundle artifact is missing: ${required_pattern}" >&2
    exit 1
  }
done

required_executables=(
  tools/crane
  tools/crictl
  tools/docker-compose
  tools/helm
  tools/kubeadm
  tools/kubectl
  tools/kubelet
  tools/runc
  tools/vault
)

for required_executable in "${required_executables[@]}"; do
  [[ -x "${required_executable}" ]] || {
    echo "Required bundle executable is missing or not executable: ${required_executable}" >&2
    exit 1
  }
done

while read -r image; do
  [[ -n "${image}" ]] || continue
  archive="repositories/registry/images/archives/$(echo "${image}" | tr '/:@' '_').tar"
  [[ -s "${archive}" ]] || {
    echo "Image archive is missing or empty: ${archive}" >&2
    exit 1
  }
done < repositories/registry/images/images.txt

echo "Bundle structure: OK"
