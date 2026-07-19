# Kubernetes air-gap bundle for Debian 12

This repository builds a versioned, transferable Kubernetes installation bundle for `amd64` Debian 12 nodes. It uses `kubeadm`, `containerd`, Flannel VXLAN and a local-path provisioner. Container images are mirrored into an existing Harbor after transfer into the isolated network.

The first target profile is deliberately conservative:

- Kubernetes installed with kubeadm;
- containerd with systemd cgroups;
- Flannel, pod network `10.244.0.0/16`;
- local-path-provisioner for initial local volumes;
- Helm and K9s in the administrator tools bundle;
- kube-prometheus-stack and Thanos prepared for an external MinIO endpoint.

The current scaffold downloads the core binaries and Kubernetes/Flannel image set. `charts/charts.lock` is the pinned declaration for the monitoring stage; chart download, rendering and its complete image closure are the next implementation step, because those charts must be selected and tested together rather than fetched as unversioned defaults.

## Installation flow

1. Run the `Build offline bundle` workflow or tag a release.
2. Transfer release assets and `SHA256SUMS` into the isolated network.
3. Verify the archive with `scripts/verify-bundle.sh`.
4. Import images into Harbor.
5. Adjust `ansible/inventory/hosts.example.yml`, copy it to `hosts.yml` and run the playbooks.

No credentials, CA private keys, kubeconfigs, MinIO keys or Harbor passwords belong in this repository or in its releases.

## Repository layout

```text
config/                 pinned component versions and cluster defaults
scripts/                bundle build, verification and Harbor import helpers
ansible/                node preparation and cluster bootstrap playbooks
charts/                 Helm chart lock file and offline values
manifests/              Flannel, storage and monitoring configuration
.github/workflows/      CI, build artifact and release workflows
```
