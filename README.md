# Kubernetes air-gap bundle for Debian 12

This repository builds a versioned, transferable Kubernetes installation
bundle for `amd64` Debian 12 nodes. It installs vanilla Kubernetes with
containerd and Flannel VXLAN. Kubernetes is bootstrapped with the upstream
`kubeadm`, `kubelet` and `kubectl` binaries. The bundle also contains a
Dockerized minimal Debian repository and the official Harbor offline installer;
cluster images are imported into Harbor after transfer into the isolated
network.

The first target profile is deliberately conservative:

- vanilla Kubernetes installed with kubeadm and the repository's Ansible playbooks;
- containerd with systemd cgroups;
- Flannel, pod network `10.244.0.0/16`;
- local-path-provisioner for initial local volumes;
- MetalLB in L2 mode and Traefik with the Kubernetes Gateway API;
- Helm and K9s in the administrator tools bundle.

For a memory-constrained local environment, Harbor and the Debian repository
run as Docker services on the physical host while Kubernetes runs on three
Debian 12 VMs. The source repository keeps the detailed lab topology under
`docs/`; the transferable release contains the self-contained `INSTALL.md`.

The bundle builder downloads the core binaries, Kubernetes/Flannel/local-path
images, the Harbor offline installer, Docker Compose, a file-based Debian
package closure plus its ready-to-run nginx image, and the pinned MetalLB and
Traefik charts with their image closure.
Transferable repositories are grouped under `repositories/`: Debian packages
under `apt`, with images and Helm artifacts under `registry`.
`deploy/platform/charts/charts.lock` also records planning versions for the
separate monitoring stage. Monitoring, MinIO and Argo CD are not part of the
current downloadable bundle yet.

## Containerd registry mirror design

The registry layout preserves every upstream repository path and tag.
Kubernetes manifests and Helm values keep their original image references;
containerd redirects each source registry to a dedicated public Harbor project.

| Source registry | Harbor project | Example destination |
| --- | --- | --- |
| `docker.io` | `docker` | `harbor.internal:8080/docker/apache/airflow:2.10.5` |
| `ghcr.io` | `ghcr` | `harbor.internal:8080/ghcr/flannel-io/flannel:v0.28.7` |
| `quay.io` | `quay` | `harbor.internal:8080/quay/prometheus/node-exporter:v1.9.1` |
| `registry.k8s.io` | `k8s` | `harbor.internal:8080/k8s/kube-apiserver:v1.36.2` |

For example, `docker.io/apache/airflow:2.10.5` is stored as
`harbor.internal:8080/docker/apache/airflow:2.10.5`, while the workload continues to
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

The lab configuration uses plain HTTP, so no Harbor certificate or CA needs to
be copied to the nodes:

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
[host."http://harbor.internal:8080/v2/docker"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

```toml
# /etc/containerd/certs.d/ghcr.io/hosts.toml
[host."http://harbor.internal:8080/v2/ghcr"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

```toml
# /etc/containerd/certs.d/quay.io/hosts.toml
[host."http://harbor.internal:8080/v2/quay"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

```toml
# /etc/containerd/certs.d/registry.k8s.io/hosts.toml
[host."http://harbor.internal:8080/v2/k8s"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

Plain HTTP is unencrypted and is intended only for the isolated private
network. To switch to HTTPS, change the inventory variables, configure Harbor
TLS and install the Harbor CA on every node. `skip_verify` can be used for a
lab-only self-signed endpoint.

Only the real Harbor and Kubernetes API names need local resolution. The
Ansible inventory supplies these entries to the node preparation playbook:

```text
10.10.0.5 harbor.internal
10.10.0.11 k8s-api.internal
```

Do not map `docker.io`, `ghcr.io`, `quay.io` or `registry.k8s.io` in
`/etc/hosts`. Containerd performs the redirection and connects to
`harbor.internal`.

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

1. Push the changes and wait for the automatic `Validate` workflow to pass.
2. Run the `Build offline bundle` workflow manually. It validates the repository
   again before downloading anything and generates the Release name automatically.
3. Download all semantic assets from that GitHub Release. Its tag has the form
   `airgap-v1.36.2-build.RUN.ATTEMPT`.
4. Transfer the release directory into the isolated network and run `bash unpack-release.sh . ../k8s-airgap`.
5. Run `deploy/infrastructure/scripts/bootstrap-host.sh` on the Debian 12
   infrastructure host, then start the bundled APT service and Harbor.
6. Import images and Helm OCI charts into Harbor.
7. Adjust `deploy/nodes/ansible/inventory/hosts.yml` and run the playbooks from
   [INSTALL.md](INSTALL.md).

No credentials, CA private keys, kubeconfigs, MinIO keys or Harbor passwords belong in this repository or in its releases.

## Repository layout

```text
config/                 pinned versions and repository mappings
deploy/scripts/          release assembly and verification
deploy/infrastructure/  APT repository and Harbor bootstrap
deploy/nodes/ansible/    Debian 12 node preparation
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
└── registry/
│   ├── images/
│   │   ├── archives/
│   │   └── images.txt
│   ├── charts/
│   │   ├── archives/
│   │   └── charts.lock
│   └── mapping.yaml
```
