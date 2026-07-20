# Installing the offline Kubernetes bundle

This guide installs the bundle on `amd64` Debian 12 nodes with one control-plane
node and one or more workers. Commands use the example names and addresses below;
replace them with values for the isolated environment.

| Name | Example value |
| --- | --- |
| Control-plane node | `10.10.0.11` |
| Worker node | `10.10.0.21` |
| Kubernetes API name | `k8s-api.internal` |
| Harbor registry | `harbor.internal` |
| Harbor mirror projects | `docker`, `ghcr`, `quay`, `k8s` |
| MetalLB address pool | `10.10.0.240-10.10.0.250` |

## Prerequisites

The administrator workstation needs SSH access to every node and Ansible. Every
cluster node must be an `amd64` Debian 12 system with these packages already
installed:

```text
ca-certificates curl conntrack socat ipset iptables ethtool nfs-common util-linux
```

The current bundle does not contain Debian packages: its `apt/` directory is
reserved for a future package stage. Install the prerequisites from an internal
APT mirror or transfer their `.deb` dependency closure before following this
guide.

Grafana can use an external PostgreSQL database for its own state; it does not
replace the Prometheus/Thanos metrics store. See
[docs/EXTERNAL-GRAFANA-POSTGRES.md](docs/EXTERNAL-GRAFANA-POSTGRES.md) before
installing the monitoring chart.

The environment also needs an existing Harbor instance. Create public projects
named `docker`, `ghcr`, `quay` and `k8s`. They mirror `docker.io`, `ghcr.io`,
`quay.io` and `registry.k8s.io`, respectively. Anonymous pull access is required
because kubeadm fetches control-plane images before Kubernetes image pull
secrets are available. Image upload can still require authentication.

By default, the supplied inventory uses Harbor over HTTPS with certificate
verification disabled. No Harbor CA has to be copied to the nodes in this mode.
The `--insecure` import option applies the equivalent behavior to the upload
client.

All nodes must resolve `harbor.internal` and `k8s-api.internal`. For a
single-control-plane installation, `k8s-api.internal` resolves to that node. For
an HA installation it must resolve to a load balancer or virtual IP; joining
additional control-plane nodes is outside the current playbooks.

For verified TLS, set `harbor_skip_tls_verify: false` and install the private CA
on every node before running Ansible:

```bash
sudo install -m 0644 harbor-ca.crt \
  /usr/local/share/ca-certificates/harbor-ca.crt
sudo update-ca-certificates
```

## 1. Verify and unpack the release

Run these commands in the directory containing the downloaded release assets:

```bash
sha256sum -c k8s-airgap-v1.36.2-debian12-amd64.tar.zst.sha256
tar --zstd -xf k8s-airgap-v1.36.2-debian12-amd64.tar.zst
cd k8s-airgap-v1.36.2-debian12-amd64
./scripts/verify-bundle.sh "$PWD"
```

The last command must report `OK` for every bundled file.

## 2. Import the images into Harbor

Authenticate with the bundled `crane` binary. It prompts for the password when
one is not supplied on the command line:

```bash
./tools/crane auth login harbor.internal -u admin
./scripts/import-images-to-harbor.sh \
  --registry harbor.internal \
  --insecure \
  "$PWD"
```

The importer preserves the repository path and tag while routing each source
registry to its Harbor project. For example:

```text
docker.io/apache/airflow:2.10.5
  -> harbor.internal/docker/apache/airflow:2.10.5
registry.k8s.io/kube-apiserver:v1.36.2
  -> harbor.internal/k8s/kube-apiserver:v1.36.2
```

Confirm that Harbor contains all images listed in `images.txt`. Workload
manifests continue to use their original source image names; containerd performs
the mirror redirection on every node.

## 3. Copy the unpacked bundle to every node

The playbooks expect the bundle contents directly under `/opt/k8s-airgap` on
every control-plane and worker node. The following example copies it to one
node; repeat it for all nodes:

```bash
scp -r . deploy@10.10.0.11:/tmp/k8s-airgap
ssh deploy@10.10.0.11 \
  'sudo mkdir -p /opt/k8s-airgap && sudo cp -a /tmp/k8s-airgap/. /opt/k8s-airgap/'
ssh deploy@10.10.0.11 \
  'sudo /opt/k8s-airgap/scripts/verify-bundle.sh /opt/k8s-airgap'
```

Do not create an extra versioned directory below `/opt/k8s-airgap`. For
example, `/opt/k8s-airgap/tools/kubeadm` must exist.

## 4. Configure the Ansible inventory

On the administrator workstation, enter the unpacked bundle's Ansible directory
and create the local inventory:

```bash
cd ansible
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
    harbor_registry: harbor.internal
    harbor_plain_http: false
    harbor_skip_tls_verify: true
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
Verify access before changing the nodes:

```bash
ansible -i inventory/hosts.yml all -m ping
ansible -i inventory/hosts.yml all -b -m command -a 'cat /etc/debian_version'
```

## 5. Prepare the nodes

Run the preparation playbook:

```bash
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

## 6. Initialise the control plane

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

## 7. Join the worker nodes

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

## 8. Install the external traffic edge

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

## 9. Verify the cluster

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
