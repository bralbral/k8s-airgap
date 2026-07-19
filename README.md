# Kubernetes air-gap bundle for Debian 12

This repository builds a versioned, transferable Kubernetes installation bundle for `amd64` Debian 12 nodes. It uses `kubeadm`, `containerd`, Flannel VXLAN and a local-path provisioner. Container images are mirrored into an existing Harbor after transfer into the isolated network.

The first target profile is deliberately conservative:

- Kubernetes installed with kubeadm;
- containerd with systemd cgroups;
- Flannel, pod network `10.244.0.0/16`;
- local-path-provisioner for initial local volumes;
- Helm and K9s in the administrator tools bundle;
- kube-prometheus-stack and Thanos prepared for an external MinIO endpoint.

The current scaffold downloads the core binaries and the Kubernetes, Flannel
and local-path image set. `charts/charts.lock` is the pinned declaration for the
monitoring stage; chart download, rendering and its complete image closure are
the next implementation step, because those charts must be selected and tested
together rather than fetched as unversioned defaults.

## Containerd registry mirror design

The registry layout preserves every upstream repository path and tag.
Kubernetes manifests and Helm values keep their original image references;
containerd redirects each source registry to a dedicated public Harbor project.

| Source registry | Harbor project | Example destination |
| --- | --- | --- |
| `docker.io` | `docker` | `harbor.internal/docker/apache/airflow:2.10.5` |
| `ghcr.io` | `ghcr` | `harbor.internal/ghcr/flannel-io/flannel:v0.28.7` |
| `quay.io` | `quay` | `harbor.internal/quay/prometheus/node-exporter:v1.9.1` |
| `registry.k8s.io` | `k8s` | `harbor.internal/k8s/kube-apiserver:v1.36.2` |

For example, `docker.io/apache/airflow:2.10.5` is stored as
`harbor.internal/docker/apache/airflow:2.10.5`, while the workload continues to
reference `docker.io/apache/airflow:2.10.5`. The source registry is represented
by the Harbor project, and the complete `apache/airflow` repository path is
preserved. This avoids repository-name collisions and does not require changes
to third-party manifests.

All mirror projects must exist before importing images. They should allow
anonymous pull access because kubeadm needs to fetch control-plane images before
Kubernetes image pull secrets are available. Push access can remain
authenticated.

Containerd 2.x must be told where to find its registry host configuration:

```toml
# /etc/containerd/config.toml
version = 3

[plugins."io.containerd.cri.v1.images".registry]
  config_path = "/etc/containerd/certs.d"
```

Create one `hosts.toml` namespace for every mirrored upstream registry:

```text
/etc/containerd/certs.d/
├── docker.io/hosts.toml
├── ghcr.io/hosts.toml
├── quay.io/hosts.toml
└── registry.k8s.io/hosts.toml
```

The recommended configuration for an isolated network uses HTTPS but skips
certificate verification, so no Harbor CA needs to be copied to the nodes:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
[host."https://harbor.internal/v2/docker"]
  capabilities = ["pull", "resolve"]
  override_path = true
  skip_verify = true
```

```toml
# /etc/containerd/certs.d/ghcr.io/hosts.toml
[host."https://harbor.internal/v2/ghcr"]
  capabilities = ["pull", "resolve"]
  override_path = true
  skip_verify = true
```

```toml
# /etc/containerd/certs.d/quay.io/hosts.toml
[host."https://harbor.internal/v2/quay"]
  capabilities = ["pull", "resolve"]
  override_path = true
  skip_verify = true
```

```toml
# /etc/containerd/certs.d/registry.k8s.io/hosts.toml
[host."https://harbor.internal/v2/k8s"]
  capabilities = ["pull", "resolve"]
  override_path = true
  skip_verify = true
```

If Harbor serves plain HTTP instead, replace `https://` with `http://` and omit
`skip_verify`. Plain HTTP is unencrypted; HTTPS with `skip_verify = true` is the
preferred insecure option. For verified TLS, remove `skip_verify` and install
the Harbor CA on every node.

Only the real Harbor name needs local resolution:

```text
10.10.0.5 harbor.internal
```

Do not map `docker.io`, `ghcr.io`, `quay.io` or `registry.k8s.io` in
`/etc/hosts`. Containerd performs the redirection and connects to
`harbor.internal`, so Harbor only needs a certificate for its own hostname.

After changing `/etc/containerd/config.toml`, restart containerd and test pulls
using the original image names:

```bash
sudo systemctl restart containerd
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
  pull docker.io/library/busybox:1.37.0
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
  pull registry.k8s.io/pause:3.10.2
```

When uploading to Harbor without trusted TLS, the bundle importer must also be
run with `--insecure`. This flag affects the upload client only; the containerd
settings above control image pulls on cluster nodes.

> **Compatibility note:** bundles whose importer still requires a `--project`
> argument use the earlier flat layout and are not compatible with this mirror
> configuration. Rebuild and transfer the bundle after upgrading.

## Installation flow

See [INSTALL.md](INSTALL.md) for the complete offline installation guide,
including Harbor preparation, node prerequisites, Ansible inventory, cluster
bootstrap and verification.

1. Run the `Build offline bundle` workflow manually.
2. Transfer the `.tar.zst` release asset and its `.sha256` file into the isolated network.
3. Verify the release asset, unpack it, then verify its contents with the bundled `scripts/verify-bundle.sh`.
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
