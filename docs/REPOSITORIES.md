# Offline repositories

The bundle is the transport format. Services in the isolated network are the
runtime format. Files under `repositories/` are imported into those services.

| Bundle path | Runtime service | Consumer |
| --- | --- | --- |
| `repositories/apt` | nginx APT repository | Debian 12 nodes |
| `repositories/files` | nginx static file repository | Kubespray |
| `repositories/registry/images` | Harbor OCI registry | containerd |
| `repositories/registry/charts` | Harbor OCI registry | Helm |
| `repositories/python` | local wheels and Ansible collections | Ansible controller |

Image repository paths and tags are preserved during import:

```text
registry.k8s.io/kube-apiserver:v1.36.2
  -> harbor.internal/k8s/kube-apiserver:v1.36.2
```

Kubernetes resources keep the upstream image name. Containerd redirects pulls
to Harbor using `hosts.toml`; DNS resolves only the real Harbor hostname.

## GitHub Release assets

The connected-side workflow publishes repositories as semantic archives rather
than one monolithic file. A release contains separate APT, Harbor, Kubespray,
Python/Ansible, Linux tools, Windows tools, Kubernetes images, networking
images and networking charts assets. `SHA256SUMS` verifies the transport set;
`unpack-release.sh` assembles it into the directory layout described above.
