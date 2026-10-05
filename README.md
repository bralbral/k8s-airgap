# Kubernetes air-gap bundle for Debian 12

This repository builds a versioned, transferable Kubernetes installation
bundle for `amd64` Debian 12 nodes. The target installer is Kubespray with
containerd and Flannel VXLAN. The bundle contains Kubespray and its offline
Python dependencies, a Dockerized minimal Debian repository and the official
Harbor offline installer; cluster images are imported into Harbor after
transfer into the isolated network. The older direct-kubeadm playbooks remain
available only while the Kubespray migration is completed.

The first target profile is deliberately conservative:

- Kubernetes installed with Kubespray;
- containerd with systemd cgroups;
- Flannel, pod network `10.244.0.0/16`;
- local-path-provisioner for initial local volumes;
- MetalLB in L2 mode and Traefik with the Kubernetes Gateway API;
- Helm and K9s in the administrator tools bundle;
- kube-prometheus-stack and Thanos prepared for an external MinIO endpoint;
  Grafana values prepared for an external PostgreSQL database.

For a memory-constrained local environment, Harbor and the Debian repository
run as Docker Compose services on the physical host while Kubernetes runs on
three Debian 12 VMs. See [docs/LAB-TOPOLOGY.md](docs/LAB-TOPOLOGY.md) for the
15 GiB resource budget, host networking and startup procedure.

The bundle builder downloads the core binaries, Kubernetes/Flannel/local-path
images, the Harbor offline installer, a Docker image containing the Debian
package closure, and the pinned MetalLB and Traefik charts with their image closure.
Transferable repositories are grouped under `repositories/`: Debian packages
under `apt`, images and Helm artifacts under `registry`, Python wheels under
`python`, and offline Git payloads under `git`.
`deploy/platform/charts/charts.lock` also pins the separate monitoring stage; its chart
download, rendering and complete image closure remain to be implemented because
those charts must be selected and tested together.

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

1. Run the `Build offline bundle` workflow manually and provide a release version.
2. Download all semantic assets from that GitHub Release.
3. Transfer the release directory into the isolated network and run `bash unpack-release.sh . ../k8s-airgap`.
4. Import images into Harbor.
5. Adjust `deploy/kubespray/inventory/lab/hosts.yaml` and run Kubespray.

No credentials, CA private keys, kubeconfigs, MinIO keys or Harbor passwords belong in this repository or in its releases.

## Repository layout

```text
config/                 pinned versions and repository mappings
deploy/scripts/          release assembly and verification
deploy/infrastructure/  APT repository and Harbor bootstrap
deploy/nodes/ansible/    Debian 12 node preparation
deploy/kubespray/        lab inventory and offline overrides
deploy/platform/         charts, values and Kubernetes manifests
docs/                    installation and operations documentation
.github/workflows/       GitHub Actions entry points
.github/scripts/         connected-side build and Release publication
```

The builder publishes several semantic release assets instead of one monolithic
archive. `bundle-manifest.yaml` lists them and `SHA256SUMS` covers every release
asset. After assembly, the resulting directory keeps transferable artifacts in
this hierarchy:

```text
repositories/
├── apt/
├── files/
│   ├── content/
│   └── files.list
├── registry/
│   ├── images/
│   │   ├── archives/
│   │   └── images.txt
│   ├── charts/
│   │   ├── archives/
│   │   └── charts.lock
│   └── mapping.yaml
└── python/
```
