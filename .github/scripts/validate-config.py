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
)

expected = {
    "cluster-defaults Kubernetes": (
        cluster_defaults["kubernetesVersion"],
        versions["KUBERNETES_VERSION"],
    ),
    "chart lock Flannel": (
        f"v{chart_lock['flannel']}",
        versions["FLANNEL_VERSION"],
    ),
    "chart lock local-path-provisioner": (
        f"v{chart_lock['local-path-provisioner']}",
        versions["LOCAL_PATH_PROVISIONER_VERSION"],
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

errors = [
    f"{name}: {actual!r} != {wanted!r}"
    for name, (actual, wanted) in expected.items()
    if actual != wanted
]
if errors:
    raise SystemExit("Version consistency check failed:\n" + "\n".join(errors))

print("Version consistency: OK")
