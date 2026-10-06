#!/usr/bin/env python3
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


def load_yaml(relative_path: str):
    with (ROOT / relative_path).open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def load_versions() -> dict[str, str]:
    versions = {}
    for raw_line in (ROOT / "config/versions.env").read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        versions[key] = value
    return versions


def load_chart_lock() -> dict[str, str]:
    versions = {}
    for raw_line in (ROOT / "deploy/platform/charts/charts.lock").read_text(
        encoding="utf-8"
    ).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        versions[key] = value
    return versions


versions = load_versions()
chart_lock = load_chart_lock()
cluster_defaults = load_yaml("config/cluster-defaults.yaml")
node_defaults = load_yaml("deploy/nodes/ansible/group_vars/all.yml")
host_examples = (
    load_yaml("deploy/nodes/ansible/inventory/hosts.example.yml"),
    load_yaml("deploy/nodes/ansible/inventory/lab.example.yml"),
    load_yaml("deploy/nodes/ansible/inventory/ha.example.yml"),
)

expected = {
    "cluster-defaults Kubernetes": (
        cluster_defaults["kubernetesVersion"],
        versions["KUBERNETES_VERSION"],
    ),
    "chart lock Cilium": (
        chart_lock["cilium"],
        versions["CILIUM_CHART_VERSION"],
    ),
    "node Cilium": (
        str(node_defaults["cilium_chart_version"]),
        versions["CILIUM_CHART_VERSION"],
    ),
    "chart lock local-path-provisioner": (
        f"v{chart_lock['local-path-provisioner']}",
        versions["LOCAL_PATH_PROVISIONER_VERSION"],
    ),
    "chart lock NFS CSI": (
        chart_lock["csi-driver-nfs"],
        versions["NFS_CSI_CHART_VERSION"],
    ),
    "node NFS CSI": (
        str(node_defaults["nfs_csi_chart_version"]),
        versions["NFS_CSI_CHART_VERSION"],
    ),
    "chart lock MetalLB": (
        chart_lock["metallb"],
        versions["METALLB_VERSION"],
    ),
    "node MetalLB": (
        str(node_defaults["metallb_version"]),
        versions["METALLB_VERSION"],
    ),
    "chart lock Traefik": (
        chart_lock["traefik"],
        versions["TRAEFIK_CHART_VERSION"],
    ),
    "node Traefik": (
        str(node_defaults["traefik_chart_version"]),
        versions["TRAEFIK_CHART_VERSION"],
    ),
    "chart lock Metrics Server": (
        chart_lock["metrics-server"],
        versions["METRICS_SERVER_CHART_VERSION"],
    ),
    "node Metrics Server": (
        str(node_defaults["metrics_server_chart_version"]),
        versions["METRICS_SERVER_CHART_VERSION"],
    ),
    "chart lock cert-manager": (
        chart_lock["cert-manager"],
        versions["CERT_MANAGER_CHART_VERSION"],
    ),
    "node cert-manager": (
        str(node_defaults["cert_manager_chart_version"]),
        versions["CERT_MANAGER_CHART_VERSION"],
    ),
    "chart lock Argo CD": (
        chart_lock["argo-cd"],
        versions["ARGO_CD_CHART_VERSION"],
    ),
    "node Argo CD": (
        str(node_defaults["argocd_chart_version"]),
        versions["ARGO_CD_CHART_VERSION"],
    ),
}

for index, inventory in enumerate(host_examples, start=1):
    inventory_vars = inventory["all"]["vars"]
    expected[f"inventory {index} Kubernetes"] = (
        inventory_vars["kube_version"],
        versions["KUBERNETES_VERSION"],
    )
    expected[f"inventory {index} MetalLB"] = (
        str(inventory_vars["metallb_version"]),
        versions["METALLB_VERSION"],
    )
    expected[f"inventory {index} Traefik"] = (
        str(inventory_vars["traefik_chart_version"]),
        versions["TRAEFIK_CHART_VERSION"],
    )
    expected[f"inventory {index} Cilium"] = (
        str(inventory_vars["cilium_chart_version"]),
        versions["CILIUM_CHART_VERSION"],
    )
    expected[f"inventory {index} Metrics Server"] = (
        str(inventory_vars["metrics_server_chart_version"]),
        versions["METRICS_SERVER_CHART_VERSION"],
    )
    expected[f"inventory {index} cert-manager"] = (
        str(inventory_vars["cert_manager_chart_version"]),
        versions["CERT_MANAGER_CHART_VERSION"],
    )
    expected[f"inventory {index} Argo CD"] = (
        str(inventory_vars["argocd_chart_version"]),
        versions["ARGO_CD_CHART_VERSION"],
    )
    expected[f"inventory {index} NFS CSI"] = (
        str(inventory_vars["nfs_csi_chart_version"]),
        versions["NFS_CSI_CHART_VERSION"],
    )

errors = [
    f"{name}: {actual!r} != {wanted!r}"
    for name, (actual, wanted) in expected.items()
    if actual != wanted
]
if errors:
    raise SystemExit("Version consistency check failed:\n" + "\n".join(errors))

print("Version consistency: OK")
