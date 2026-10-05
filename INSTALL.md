# Installing the offline Kubernetes bundle

This guide installs the bundle on `amd64` Debian 12 nodes with one control-plane
node and one or more workers. Commands use the example names and addresses below;
replace them with values for the isolated environment.

| Name | Example value |
| --- | --- |
| Control-plane node | `10.10.0.11` |
| Worker node | `10.10.0.21` |
| Kubernetes API name | `k8s-api.internal` |
| Harbor registry | `harbor.internal:8080` |
| Harbor mirror projects | `docker`, `ghcr`, `quay`, `k8s` |
| MetalLB address pool | `10.10.0.240-10.10.0.250` |

## Prerequisites

For the supported local layout, Harbor and the APT repository run as Docker
services on an infrastructure host, while Kubernetes runs on three Debian 12
machines. The infrastructure host must be reachable from every node on ports
`8080` and `8081` in the supplied lab configuration.

The infrastructure host doubles as the administrator workstation in the
supported profile. It needs Debian 12, SSH access to every node, at least 4 GiB
RAM and 40 GiB free disk. The bundled bootstrap script installs Docker and
Ansible from the local file-based APT repository. Every cluster node must be an
`amd64` Debian 12 system with SSH, sudo and APT; the APT playbook bootstraps
Python when needed and installs the remaining prerequisites:

```text
ca-certificates chrony conntrack curl ethtool iproute2 ipset iptables nfs-common
nftables python3 rsync socat util-linux
```

The lab profile builds the prerequisite dependency closure into a Dockerized
APT repository on the host. For production, replace this minimal unsigned
repository with a dated and signed Debian snapshot.

The bundled Harbor installer creates public projects named `docker`, `ghcr`,
`quay`, `k8s` and `charts`. The first four mirror `docker.io`, `ghcr.io`, `quay.io` and
`registry.k8s.io`, respectively. Anonymous pull access is required because
kubeadm fetches control-plane images before Kubernetes image pull secrets are
available. Image upload still requires authentication.

By default, the supplied inventory uses Harbor over plain HTTP on port `8080`.
No Harbor certificate or CA is required in this isolated lab profile. The
`--insecure` option tells the bundled upload client to use the same mode.

All nodes must resolve `harbor.internal` and `k8s-api.internal`. The preparation
playbook manages their `/etc/hosts` entries from `airgap_host_entries` in the
inventory. For a single-control-plane installation, `k8s-api.internal` resolves
to that node. For an HA installation it must resolve to a load balancer or
virtual IP; joining additional control-plane nodes is outside the current
playbooks.

For verified TLS, set `harbor_skip_tls_verify: false` and install the private CA
on every node before running Ansible:

```bash
sudo install -m 0644 harbor-ca.crt \
  /usr/local/share/ca-certificates/harbor-ca.crt
sudo update-ca-certificates
```

## 1. Download, verify and assemble the release

Download every asset from one GitHub Release into the same directory. With the
GitHub CLI this can be done on the connected machine before transfer:

```bash
gh release download airgap-RELEASE --dir k8s-airgap-release
```

Transfer that directory into the isolated network, then assemble the semantic
assets into one working tree:

```bash
cd k8s-airgap-release
bash unpack-release.sh "$PWD" ../k8s-airgap
cd ../k8s-airgap
```

The unpacker checks `SHA256SUMS`, extracts all component archives and runs the
internal bundle verification. It must report `Bundle structure: OK`.

## 2. Bootstrap the infrastructure host

Run the bootstrap from the unpacked bundle. It replaces active APT sources with
the bundle's local `file:` repository, preserving the originals under
`/etc/apt/k8s-airgap-bootstrap-backup`, then installs Docker, Docker Compose and
Ansible without network access:

```bash
sudo ./deploy/infrastructure/scripts/bootstrap-host.sh "$PWD"
```

Load and start the packaged APT service:

```bash
cp deploy/infrastructure/.env.example deploy/infrastructure/.env
docker load < repositories/apt/apt-repo-debian12-amd64.tar.gz
docker compose \
  --env-file deploy/infrastructure/.env \
  -f deploy/infrastructure/compose.yaml \
  up -d --no-build apt-repo
curl --fail http://127.0.0.1:8081/healthz
```

Install Harbor from its offline installer. The script disables the template's
HTTPS block, starts Harbor over HTTP and creates the four public mirror
projects:

```bash
export HARBOR_HOSTNAME=harbor.internal
export HARBOR_HTTP_PORT=8080
export HARBOR_DATA_DIR=/var/lib/harbor
export HARBOR_ADMIN_PASSWORD='replace-with-a-private-password'
sudo -E ./deploy/infrastructure/scripts/install-harbor.sh \
  deploy/infrastructure/harbor/harbor-offline-installer-v2.15.2.tgz
```

The infrastructure host resolves `harbor.internal` to itself. The inventory in
step 5 maps the same name to the infrastructure host's network address on all
cluster nodes.

## 3. Import the images into Harbor

Authenticate with the bundled `crane` binary. It prompts for the password when
one is not supplied on the command line:

```bash
./tools/crane auth login harbor.internal:8080 --insecure -u admin
./deploy/infrastructure/scripts/import-images-to-harbor.sh \
  --registry harbor.internal:8080 \
  --insecure \
  "$PWD"
```

The importer preserves the repository path and tag while routing each source
registry to its Harbor project. For example:

```text
docker.io/apache/airflow:2.10.5
  -> harbor.internal:8080/docker/apache/airflow:2.10.5
registry.k8s.io/kube-apiserver:v1.36.2
  -> harbor.internal:8080/k8s/kube-apiserver:v1.36.2
```

Confirm that Harbor contains all images listed in
`repositories/registry/images/images.txt`. Workload manifests continue to use
their original source image names; containerd performs the mirror redirection
on every node.

Publish the bundled Helm archives into Harbor's `charts` OCI project:

```bash
export HARBOR_PASSWORD='the-same-private-password'
./deploy/infrastructure/scripts/import-charts-to-harbor.sh \
  --registry harbor.internal:8080 \
  --plain-http \
  "$PWD"
unset HARBOR_PASSWORD
```

The cluster playbooks install the initial networking charts directly from the
verified local `.tgz` files. The OCI copies in Harbor are available to later
offline Helm and GitOps deployments.

## 4. Copy the unpacked bundle to every node

The playbooks expect the bundle contents directly under `/opt/k8s-airgap` on
every control-plane and worker node. The following example copies it to one
node; repeat it for all nodes:

```bash
scp -r . deploy@10.10.0.11:/tmp/k8s-airgap
ssh deploy@10.10.0.11 \
  'sudo mkdir -p /opt/k8s-airgap && sudo cp -a /tmp/k8s-airgap/. /opt/k8s-airgap/'
ssh deploy@10.10.0.11 \
  'sudo /opt/k8s-airgap/deploy/scripts/verify-bundle.sh /opt/k8s-airgap'
```

Do not create an extra versioned directory below `/opt/k8s-airgap`. For
example, `/opt/k8s-airgap/tools/kubeadm` and
`/opt/k8s-airgap/repositories/registry/images/images.txt` must exist.

## 5. Configure the Ansible inventory

On the administrator workstation, enter the unpacked bundle's Ansible directory
and create the local inventory:

```bash
cd deploy/nodes/ansible
cp inventory/hosts.example.yml inventory/hosts.yml
```

Edit `inventory/hosts.yml`:

```yaml
---
all:
  vars:
    ansible_user: deploy
    ansible_become: true
    kube_version: v1.36.2
    pod_subnet: 10.244.0.0/16
    service_subnet: 10.96.0.0/12
    control_plane_endpoint: k8s-api.internal:6443
    apt_repo_url: http://10.10.0.5:8081/debian
    apt_repo_trusted: true
    harbor_registry: harbor.internal:8080
    harbor_plain_http: true
    harbor_skip_tls_verify: false
    airgap_host_entries:
      - address: 10.10.0.5
        names: [harbor.internal]
      - address: 10.10.0.11
        names: [k8s-api.internal]
    local_path: /var/local-path-provisioner
    # Reserved, unused addresses on the same L2 network as the nodes.
    # Exclude this range from DHCP before applying the playbook.
    metallb_ip_address_pool: 10.10.0.240-10.10.0.250
    metallb_version: 0.16.1
    traefik_chart_version: 40.3.0
  children:
    control_plane:
      hosts:
        cp-01:
          ansible_host: 10.10.0.11
    workers:
      hosts:
        worker-01:
          ansible_host: 10.10.0.21
```

The SSH host keys must already be trusted because host-key checking is enabled.
Verify raw SSH access before changing the nodes. This check does not require
Python to be installed remotely:

```bash
ansible -i inventory/hosts.yml all -b -m raw -a 'cat /etc/debian_version'
```

## 6. Prepare the nodes

The normal path installs the complete base cluster with one command. It
configures APT, prepares every node, runs `kubeadm init` and joins the workers:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/install-cluster.yml
```

After that command succeeds, continue at step 9. To troubleshoot or control
each phase separately, run the first two phases explicitly:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/configure-apt.yml
ansible-playbook -i inventory/hosts.yml playbooks/prepare-nodes.yml
```

The playbook installs and starts containerd and kubelet. It also renders the
four mirror files automatically:

```text
/etc/containerd/certs.d/docker.io/hosts.toml
/etc/containerd/certs.d/ghcr.io/hosts.toml
/etc/containerd/certs.d/quay.io/hosts.toml
/etc/containerd/certs.d/registry.k8s.io/hosts.toml
```

The kubelet may restart until kubeadm writes its configuration. This is expected
at this stage.

Test the mirror using an original upstream image name:

```bash
ssh deploy@10.10.0.11 \
  'sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pull registry.k8s.io/pause:3.10.2'
```

## 7. Initialise the control plane

```bash
ansible-playbook -i inventory/hosts.yml playbooks/init-control-plane.yml
```

This initialises Kubernetes and installs Flannel and the local-path provisioner.

Check the control-plane node and system pods:

```bash
ssh deploy@10.10.0.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide'
ssh deploy@10.10.0.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A'
```

Wait until the control-plane node is `Ready` and the Flannel pods are running
before joining workers.

## 8. Join the worker nodes

Generate a fresh join command on the control-plane node:

```bash
ssh deploy@10.10.0.11 \
  'sudo kubeadm token create --print-join-command'
```

Pass the entire returned command to the worker playbook. Keep it inside quotes:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/join-workers.yml \
  -e 'join_command=kubeadm join k8s-api.internal:6443 --token TOKEN --discovery-token-ca-cert-hash sha256:HASH'
```

The join token is temporary. Generate a new command if it expires.

## 9. Install the external traffic edge

Before this step, reserve `metallb_ip_address_pool` outside DHCP and ensure TCP
`80` and `443` are permitted to its addresses. Run this only after at least one
worker is `Ready`:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/install-edge.yml
```

It installs MetalLB, its L2 address pool, the Gateway API CRDs and Traefik. The
initial Traefik Gateway is HTTP-only; add a TLS listener only after placing its
certificate Secret in the `traefik` namespace.

```bash
ssh deploy@10.10.0.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get svc -n traefik'
```

## 10. Verify the cluster

```bash
ssh deploy@10.10.0.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide'
ssh deploy@10.10.0.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A -o wide'
ssh deploy@10.10.0.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get storageclass'
```

All nodes should become `Ready`, system pods should be running, and the
local-path storage class should be present. Keep `/etc/kubernetes/admin.conf`
private; it grants cluster-administrator access.
