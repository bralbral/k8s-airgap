#!/usr/bin/env python3
"""Check offline wiring, rendered resources, image coverage and version pins."""
from pathlib import Path
import importlib.util
import json

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[2]

def read(path):
    return yaml.safe_load((ROOT / path).read_text())

versions = dict(line.split('=', 1) for line in (ROOT / 'config/versions.env').read_text().splitlines() if line and not line.startswith('#'))
values = read('deploy/ansible/inventory/group_vars/all.yml')
inventory = read('deploy/ansible/inventory/ha.example.yml')['all']
values.update(inventory['vars'])
for key, version in [('kube_version', 'KUBERNETES_VERSION'), ('cilium_chart_version', 'CILIUM_CHART_VERSION'), ('metallb_version', 'METALLB_VERSION'), ('argocd_chart_version', 'ARGO_CD_CHART_VERSION')]:
    assert str(values[key]) == versions[version], key
for key, version in [('prometheus_image', 'PROMETHEUS_VERSION'), ('node_exporter_image', 'NODE_EXPORTER_VERSION'), ('kube_state_metrics_image', 'KUBE_STATE_METRICS_VERSION')]:
    assert values[key].endswith(':' + versions[version]), key
assert len(inventory['children']['control_plane']['hosts']) == 3
assert len(inventory['children']['workers']['hosts']) == 2
packages = (ROOT / 'config/packages.txt').read_text().splitlines()
# Render real deployment templates, fail on missing variables or malformed YAML.
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
monitoring = env.from_string((ROOT / 'deploy/ansible/templates/monitoring.yaml.j2').read_text()).render(**values)
resources = list(yaml.safe_load_all(monitoring))
config = next(r for r in resources if r['kind'] == 'ConfigMap')
prometheus = yaml.safe_load(config['data']['prometheus.yml'])
assert prometheus['remote_write'][0]['url'] == values['thanos_remote_write_url']
agent = next(r for r in resources if r['kind'] == 'StatefulSet')
assert '--agent' in agent['spec']['template']['spec']['containers'][0]['args']
assert agent['spec']['volumeClaimTemplates'][0]['spec']['storageClassName'] == 'local-path'
service = yaml.safe_load(env.from_string((ROOT / 'deploy/ansible/templates/argocd-service.yaml.j2').read_text()).render(**values))
assert service['spec']['type'] == 'LoadBalancer'
assert service['spec']['allocateLoadBalancerNodePorts'] is False
assert service['spec']['loadBalancerIP'] == values['argocd_ip']
assert read('deploy/platform/charts/values/argo-cd.yaml')['server']['service']['type'] == 'ClusterIP'
for path in (ROOT / 'deploy/infrastructure').glob('*/compose.yaml'):
    compose = yaml.safe_load(path.read_text())
    for service in compose['services'].values():
        assert 'build' not in service, path
        assert ':' in service['image'] and not service['image'].endswith(':latest'), path
        for mount in service.get('volumes', []):
            source = mount.split(':', 1)[0]
            assert (source.startswith('/stage/') or source.startswith('./')), (path, mount)
        assert not service.get('volumes_from'), path
# Upstream images plus the user-selected MinIO image.
allowed = ('amazon/aws-cli:', 'nginx:', 'cr.yandex/mirror/minio/minio:', 'haproxy:', 'quay.io/thanos/', 'postgres:', 'grafana/grafana:')
for path in (ROOT / 'deploy/infrastructure').glob('*/compose.yaml'):
    for service in yaml.safe_load(path.read_text())['services'].values():
        assert service['image'].startswith(allowed), service['image']
# The registry must never fall back to an upstream server.
mirror = (ROOT / 'deploy/ansible/templates/registry-hosts.toml.j2').read_text()
assert 'server = "{{ endpoint }}"' in mirror and 'override_path = true' in mirror
spec = importlib.util.spec_from_file_location('collect_images', ROOT / '.github/scripts/collect-images.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
minio = read('deploy/infrastructure/minio/compose.yaml')['services']['minio']
assert minio['image'] == 'cr.yandex/mirror/minio/minio:RELEASE.2023-08-09T23-30-22Z'
ci_images = set(module.compose_images(ROOT / 'deploy/infrastructure'))
assert module.normalize(minio['image']) in ci_images
assert 'docker.io/amazon/aws-cli:2.31.18' in ci_images
assert 'docker.io/library/nginx:1.28.0-alpine' in ci_images
assert len(ci_images) == 7, ci_images
assert module.normalize('busybox:1.37.0') == 'docker.io/library/busybox:1.37.0'
assert module.normalize('quay.io/cilium/cilium:v1@sha256:abc') == 'quay.io/cilium/cilium:v1@sha256:abc'
for bad in ('busybox', 'nginx:latest'):
    try:
        module.normalize(bad)
    except ValueError:
        pass
    else:
        raise AssertionError('Unpinned image accepted')
assert {r['image'] for doc in resources for r in doc.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])} == {values[k] for k in ('prometheus_image', 'node_exporter_image', 'kube_state_metrics_image')}
for path in (ROOT / 'deploy/infrastructure/monitoring/dashboards').glob('*.json'):
    json.loads(path.read_text())
print('Configuration and offline wiring: OK')
