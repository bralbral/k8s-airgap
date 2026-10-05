# Local lab: Docker infrastructure and Debian 12 virtual machines

The lab keeps bootstrap services on the physical host and Kubernetes on three
Debian 12 virtual machines. Harbor and the APT repository must not run inside
the cluster they are used to restore.

## Resource budget for a 15 GiB host

| Component | vCPU | RAM | Disk |
| --- | ---: | ---: | ---: |
| `cp-01` | 2 | 2560 MiB | 24 GiB |
| `worker-01` | 2 | 2304 MiB | 32 GiB |
| `worker-02` | 2 | 2304 MiB | 32 GiB |
| Harbor on the host | shared | up to 4 GiB expected | at least 40 GiB |
| APT nginx container | shared | limit 128 MiB | about 1 GiB for the minimal repository |

This allocation leaves roughly 3.5 GiB for the host OS and filesystem cache.
Do not enable Harbor Trivy, HA Argo CD, Thanos, or a multi-replica Prometheus in
this profile. Kubernetes workloads consume memory inside the worker allocations,
so monitoring must have small requests and a short retention period.

The VM disks may be thin-provisioned, but the host must retain enough real free
space for Harbor, container layers, Kubernetes images, metrics and snapshots.

## Network

The example uses the default libvirt network `192.168.122.0/24`:

| Address | Purpose |
| --- | --- |
| `192.168.122.1:8080` | Harbor on the host |
| `192.168.122.1:8081` | Debian repository on the host |
| `192.168.122.11` | `cp-01` |
| `192.168.122.21` | `worker-01` |
| `192.168.122.22` | `worker-02` |
| `192.168.122.240-250` | MetalLB lab pool |

Use DHCP reservations or static addresses. The host firewall must allow TCP
`8080` and `8081` from the VM bridge only. Nodes must reach each other directly;
allow TCP `6443`, `2379-2380`, `10250`, `10257`, `10259` as applicable and UDP
`8472` for Flannel VXLAN. Do not expose Harbor or the unsigned lab APT repository
to an untrusted network.

## Start the APT repository

The Docker build resolves the packages in `config/packages.txt` against Debian
12 Bookworm, downloads their dependency closure and builds a small static APT
repository. It is deliberately unsigned and is trusted only by the lab inventory.

```bash
cp deploy/infrastructure/.env.example deploy/infrastructure/.env
docker compose --env-file deploy/infrastructure/.env -f deploy/infrastructure/compose.yaml build apt-repo
docker compose --env-file deploy/infrastructure/.env -f deploy/infrastructure/compose.yaml up -d apt-repo
curl --fail http://127.0.0.1:8081/healthz
```

Rebuilding later can select newer package revisions. Preserve the built image
with the release bundle when exact reproducibility is required:

```bash
docker save k8s-airgap/apt-repo:debian12-amd64 | gzip > apt-repo-debian12-amd64.tar.gz
```

The GitHub Actions builder in `.github/scripts/build-bundle.sh` performs this
build and export automatically.
Inside the isolated network, load and start the saved image without rebuilding:

```bash
sudo ./deploy/infrastructure/scripts/bootstrap-host.sh "$PWD"
docker load < repositories/apt/apt-repo-debian12-amd64.tar.gz
docker compose --env-file deploy/infrastructure/.env -f deploy/infrastructure/compose.yaml up -d --no-build apt-repo
```

Production must use a dated, signed APT snapshot and distribute its signing key
to nodes instead of setting `apt_repo_trusted: true`.

## Start Harbor

The bundle builder downloads the pinned official Harbor offline installer on the
connected machine. Harbor's installer creates and starts its own Docker Compose
project; it is intentionally not duplicated in `deploy/infrastructure/compose.yaml`.

```bash
export HARBOR_HOSTNAME=harbor.internal
export HARBOR_HTTP_PORT=8080
export HARBOR_DATA_DIR=/var/lib/harbor
export HARBOR_ADMIN_PASSWORD='replace-with-a-lab-password'
sudo -E ./deploy/infrastructure/scripts/install-harbor.sh \
  deploy/infrastructure/harbor/harbor-offline-installer-v2.15.2.tgz
```

When working from an unpacked bundle, the installer is under
`deploy/infrastructure/harbor/`.

The script installs Harbor without Trivy and creates public pull projects named
`docker`, `ghcr`, `quay` and `k8s`. Push still requires authentication. Keep the
generated `deploy/infrastructure/runtime/harbor` directory: Harbor needs it for stop, start,
reconfiguration and upgrades.

The lab uses HTTP to fit simple host networking. Production must use an internal
CA, HTTPS and `harbor_plain_http: false`.

## Prepare the VMs

Install minimal Debian 12 with unique hostnames and machine IDs, an SSH user
named `deploy`, SSH public-key authentication and passwordless sudo. Do not clone
a running VM without regenerating `/etc/machine-id` and SSH host keys.

For a libvirt host, install `virtinst`, `qemu-utils` and
`cloud-image-utils`, download a Debian 12 genericcloud qcow2 image on the
connected side, and run:

```bash
sudo ./deploy/infrastructure/scripts/create-lab-vms.sh \
  debian-12-genericcloud-amd64.qcow2 \
  "$HOME/.ssh/id_ed25519.pub"
```

The script creates thin qcow2 overlays, cloud-init seed images, fixed DHCP
reservations on the libvirt `default` network and the exact CPU/RAM/disk layout
from the table above. It never replaces an existing VM or disk. VM base-image
distribution is an infrastructure concern and is not currently included in the
Kubernetes bundle.

Copy `deploy/nodes/ansible/inventory/lab.example.yml` to the ignored `hosts.yml`, adjust the
addresses if needed, then run:

```bash
cd deploy/nodes/ansible
ansible -i inventory/hosts.yml all -m ping
ansible-playbook -i inventory/hosts.yml playbooks/install-cluster.yml
```

The APT playbook preserves previous source files under
`/etc/apt/airgap-backup`, replaces them with the host repository and installs
the prerequisite package set. The remaining playbooks consume the transferred
offline bundle as documented in `INSTALL.md`.
