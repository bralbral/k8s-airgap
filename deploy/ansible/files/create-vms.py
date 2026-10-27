#!/usr/bin/env python3
"""Create or start KVM guests; --recreate explicitly replaces configured guests and their disks."""
import argparse
from datetime import datetime
import hashlib
import contextlib
import io
import sys
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[2] / "infrastructure/vms"
CHANGED = False


def run(*args):
    global CHANGED
    if args[0] in ('qemu-img', 'cloud-localds', 'virt-install') and args[1] != 'info':
        CHANGED = True
    if args[0] == 'virsh' and args[1] in ('start', 'destroy', 'undefine', 'net-define', 'net-start'):
        CHANGED = True
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def write(path, value, private=False):
    global CHANGED
    if not path.exists() or path.read_text() != value:
        path.write_text(value)
        CHANGED = True
    path.chmod(0o600 if private else 0o644)


def resolve(value, base):
    # sudo must not turn the caller's ~/.ssh into /root/.ssh.
    if value.startswith('~/'):
        home = pwd.getpwnam(os.environ.get('SUDO_USER') or pwd.getpwuid(os.getuid()).pw_name).pw_dir
        value = str(Path(home) / value[2:])
    p = Path(value)
    return (p if p.is_absolute() else base / p).resolve()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_removal_permissions(folder):
    """Check every directory before stopping any VM; files need no write access."""
    hint = 'Retry create-vms.yml with -e vm_become=true --ask-become-pass.'
    require(os.access(folder.parent, os.W_OK | os.X_OK),
            f'Cannot remove {folder}: parent directory is not writable. {hint}')

    def walk_error(error):
        raise ValueError(f'Cannot inspect {folder}: {error}. {hint}') from error

    for directory, _, _ in os.walk(folder, followlinks=False, onerror=walk_error):
        require(os.access(directory, os.R_OK | os.W_OK | os.X_OK),
                f'Cannot remove files in {directory}: insufficient directory permissions. {hint}')


def load(path):
    c = json.loads(path.read_text())
    base = path.parent
    c['image'] = str(resolve(c['image'], base))
    c['directory'] = str(resolve(c['directory'], base))
    require(',' not in c['directory'], 'VM directory cannot contain commas.')
    ipaddress.IPv4Address(c['infra_ip'])
    net = c['network']
    subnet = ipaddress.IPv4Network(net['subnet'])
    gateway = ipaddress.IPv4Address(net['gateway'])
    require(gateway in subnet and gateway not in (subnet.network_address, subnet.broadcast_address), 'Invalid gateway.')
    require(re.fullmatch(r'[a-zA-Z0-9_-]+', net['name']), 'Invalid network name.')
    require(re.fullmatch(r'[a-zA-Z0-9_-]{1,15}', net['bridge']), 'Invalid bridge name.')
    for address in net['dns']:
        ipaddress.IPv4Address(address)
    lo, hi = map(ipaddress.IPv4Address, c['metallb_pool'].split('-'))
    require(lo in subnet and hi in subnet and lo <= hi, 'Invalid MetalLB range.')
    require(lo <= ipaddress.IPv4Address(c['argocd_ip']) <= hi, 'Argo CD must be in MetalLB range.')
    names, ips = set(), {gateway, subnet.network_address, subnet.broadcast_address}
    nodes = []
    for entry in c['nodes']:
        n = dict(c['defaults'], **entry)
        require(re.fullmatch(r'[a-z][a-z0-9-]{0,62}', n['name']), 'Invalid VM name.')
        require(n['name'] not in names, 'Duplicate VM name.')
        names.add(n['name'])
        address = ipaddress.IPv4Address(n['ip'])
        require(address in subnet and address not in ips and not lo <= address <= hi, 'Invalid/duplicate VM IP or overlap with MetalLB.')
        ips.add(address)
        require(n['role'] in ('control_plane', 'workers'), 'Role must be control_plane or workers.')
        require(re.fullmatch(r'[a-z_][a-z0-9_-]*', n['user']) and n['user'] != 'root', 'Invalid guest user.')
        for field in ('cpu', 'ram_gib', 'disk_gib'):
            require(type(n[field]) is int and n[field] > 0, f'{field} must be a positive integer.')
        require(type(n['ssh_password_auth']) is bool, 'ssh_password_auth must be boolean.')
        require(n['password'] is None or isinstance(n['password'], str) and n['password'], 'Password must be nonempty or null.')
        require(not n['ssh_password_auth'] or n['password'], 'SSH password login needs a password.')
        key_path = n.get('ssh_public_key')
        n['key'] = resolve(key_path, base).read_text().strip() if key_path else ''
        require(not n['key'] or '\n' not in n['key'] and n['key'].startswith(('ssh-ed25519 ', 'ssh-rsa ', 'ecdsa-sha2-')), 'Invalid SSH public key.')
        require(n['key'] or n['ssh_password_auth'], 'Configure an SSH key or SSH password login.')
        n['mac'] = '52:54:' + ':'.join(f'{b:02x}' for b in address.packed)
        nodes.append(n)
    require(nodes, 'Configure at least one VM.')
    c['nodes'] = nodes
    return c


def network_xml(net):
    root = ET.Element('network')
    ET.SubElement(root, 'name').text = net['name']
    ET.SubElement(root, 'forward', mode='nat')
    ET.SubElement(root, 'bridge', name=net['bridge'], stp='on', delay='0')
    ET.SubElement(root, 'ip', address=net['gateway'], netmask=str(ipaddress.ip_network(net['subnet']).netmask))
    return ET.tostring(root, encoding='unicode')


def user_data(n):
    user = {'name': n['user'], 'shell': '/bin/bash', 'groups': ['sudo'],
            'sudo': 'ALL=(ALL) NOPASSWD:ALL', 'lock_passwd': not bool(n['password']),
            'ssh_authorized_keys': [n['key']] if n['key'] else []}
    data = {'hostname': n['name'], 'manage_etc_hosts': True, 'users': [user],
            'ssh_pwauth': n['ssh_password_auth'], 'disable_root': True,
            'package_update': False, 'package_upgrade': False}
    if n['password']:
        data['chpasswd'] = {'expire': False, 'users': [
            {'name': n['user'], 'password': n['password'], 'type': 'text'}]}
    return '#cloud-config\n' + json.dumps(data, indent=2) + '\n'


def main():
    global CHANGED
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', nargs='?', type=Path, default=BASE / 'config.json')
    parser.add_argument('--json', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--check', action='store_true', help='Validate config and print VM plan without creating anything')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--recreate', action='store_true',
                       help='DELETE configured lab VMs and their disks, then create them from current config')
    modes.add_argument('--recover-incomplete', action='store_true',
                        help='Preserve unfinished VM directories as backups and retry creation; never replaces a registered VM')
    args = parser.parse_args()
    c = load(args.config.resolve())
    for n in c['nodes']:
        print(f"{n['name']}: {n['ip']}, {n['cpu']} CPU, {n['ram_gib']} GiB RAM, {n['disk_gib']} GiB disk", flush=True)
    if args.check:
        print('Configuration OK. Source image and host tools are checked during creation.')
        return
    for tool in ('virsh', 'virt-install', 'qemu-img', 'cloud-localds', 'ip'):
        require(shutil.which(tool), f'Missing tool: {tool}')
    require(Path('/dev/kvm').exists(), 'KVM unavailable.')
    os.environ['LIBVIRT_DEFAULT_URI'] = 'qemu:///system'
    image, root, net = Path(c['image']), Path(c['directory']), c['network']
    info = json.loads(run('qemu-img', 'info', '--output=json', image))
    require(info['format'] == 'qcow2' and not info.get('backing-filename'), 'Use a standalone Debian 12 amd64 qcow2 cloud image.')
    for n in c['nodes']:
        require(n['disk_gib'] * 1024**3 >= info['virtual-size'], 'VM disk is smaller than the source image.')
    domains = set(run('virsh', 'list', '--all', '--name').splitlines())
    networks = set(run('virsh', 'net-list', '--all', '--name').splitlines())
    # Record ownership and settings to allow adding nodes without changing existing disks.
    marker = root / 'network.json'
    require(not root.exists() or marker.exists(), f'{root} already exists and is not managed by this script.')
    if marker.exists():
        require(json.loads(marker.read_text()) == net, 'Existing network settings changed; restore config or use another lab.')
    if net['name'] in networks:
        require(marker.exists(), 'Network already exists and is not managed by this script.')
        actual = ET.fromstring(run('virsh', 'net-dumpxml', net['name']))
        require(actual.find('bridge').get('name') == net['bridge'] and
                actual.find('ip').get('address') == net['gateway'] and
                actual.find('ip').get('netmask') == str(ipaddress.ip_network(net['subnet']).netmask) and
                actual.find('forward').get('mode') == 'nat' and actual.find('ip/dhcp') is None,
                'Existing libvirt network differs from the configuration.')
    subnet = ipaddress.ip_network(net['subnet'])
    for route in json.loads(run('ip', '-j', '-4', 'route', 'show')):
        dest = route.get('dst', 'default')
        if dest != 'default' and route.get('dev') != net['bridge']:
            require(not ipaddress.ip_network(dest, strict=False).overlaps(subnet), f'Overlapping route: {dest}')
    incomplete = []
    recreate = []
    for n in c['nodes']:
        folder = root / n['name']
        signature = hashlib.sha256(json.dumps(n, sort_keys=True).encode()).hexdigest()
        n['signature'] = signature
        if args.recreate:
            require(not folder.is_symlink() and folder.resolve().parent == root,
                    f'Unsafe VM directory: {folder}')
            require(not image.is_relative_to(folder.resolve()), 'Source image is inside a VM directory.')
            actual = None
            if n['name'] in domains:
                require((folder / 'settings.sha256').is_file(),
                        f"{n['name']}: no ownership marker; refusing to delete this VM.")
                actual = ET.fromstring(run('virsh', 'dumpxml', n['name']))
                sources = actual.findall('devices/disk/source')
                require(any(s.get('file') == str(folder / 'system.qcow2') for s in sources),
                        'Existing VM uses another system disk.')
                require(all(s.get('file') and Path(s.get('file')).resolve().is_relative_to(folder)
                            for s in sources), 'VM has disks outside its directory; refusing recreation.')
            if folder.exists():
                require(folder.is_dir(), f'Not a directory: {folder}')
                check_removal_permissions(folder)
                # An unrelated VM must not lose a shared disk.
                for other in domains - {n['name']}:
                    other_xml = ET.fromstring(run('virsh', 'dumpxml', other))
                    require(not any(source.get('file') and
                                    Path(source.get('file')).resolve().is_relative_to(folder)
                                    for source in other_xml.findall('devices/disk/source')),
                            f'{folder}: a disk is also attached to {other}.')
            recreate.append((n['name'], folder, actual))
            continue
        if folder.exists() and n['name'] not in domains:
            require(args.recover_incomplete,
                    f"{n['name']}: interrupted creation. Run with --recover-incomplete to preserve these files and retry with current settings.")
            incomplete.append(folder)
            continue
        if folder.exists() or n['name'] in domains:
            saved = folder / 'settings.sha256'
            require(saved.exists() and saved.read_text() == signature and n['name'] in domains,
                    f"{n['name']}: existing or incomplete VM differs from config. It will not be overwritten.")
            actual = ET.fromstring(run('virsh', 'dumpxml', n['name']))
            disks = [s.get('file') for s in actual.findall('devices/disk/source')]
            require(str(folder / 'system.qcow2') in disks, 'Existing VM uses another disk.')
    # Every target is checked before stopping or deleting any guest.
    for name, folder, actual in recreate:
        print(f'Recreating {name}: deleting its VM and {folder}', flush=True)
        if actual is not None:
            if name in run('virsh', 'list', '--name').splitlines():
                run('virsh', 'destroy', name)
            flags = ['--nvram'] if actual.find('os/nvram') is not None else []
            run('virsh', 'undefine', name, *flags)
            domains.remove(name)
        if folder.exists():
            shutil.rmtree(folder)
            CHANGED = True
    for folder in incomplete:
        backup = folder.with_name(folder.name + '.incomplete-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        folder.rename(backup)
        CHANGED = True
        print(f'Preserved unfinished files: {backup}', flush=True)
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o755)
    write(marker, json.dumps(net, indent=2))
    if net['name'] not in networks:
        write(root / 'network.xml', network_xml(net))
        print(run('virsh', 'net-define', root / 'network.xml'))
    run('virsh', 'net-autostart', net['name'])
    if net['name'] not in run('virsh', 'net-list', '--name').splitlines():
        run('virsh', 'net-start', net['name'])
    for n in c['nodes']:
        folder = root / n['name']
        if n['name'] not in domains:
            folder.mkdir(mode=0o755)
            write(folder / 'user-data', user_data(n), private=True)
            write(folder / 'meta-data', json.dumps({'instance-id': n['name'], 'local-hostname': n['name']}))
            network = {'version': 1, 'config': [{'type': 'physical', 'name': 'eth0', 'mac_address': n['mac'],
                       'subnets': [{'type': 'static', 'address': f"{n['ip']}/{subnet.prefixlen}",
                                    'gateway': net['gateway'], 'dns_nameservers': net['dns']}]}]}
            write(folder / 'network-config', json.dumps(network))
            run('qemu-img', 'convert', '-f', 'qcow2', '-O', 'qcow2', image, folder / 'system.qcow2')
            run('qemu-img', 'resize', folder / 'system.qcow2', f"{n['disk_gib']}G")
            run('cloud-localds', f"--network-config={folder / 'network-config'}", folder / 'seed.iso', folder / 'user-data', folder / 'meta-data')
            (folder / 'seed.iso').chmod(0o600)
            print(run('virt-install', '--name', n['name'], '--memory', n['ram_gib'] * 1024, '--vcpus', n['cpu'],
                      '--cpu', 'host', '--virt-type', 'kvm', '--osinfo', 'debian12', '--import',
                      '--disk', f'path={folder}/system.qcow2,format=qcow2,bus=virtio',
                      '--disk', f'path={folder}/seed.iso,format=raw,bus=virtio,readonly=on',
                      '--network', f"network={net['name']},model=virtio,mac={n['mac']}",
                      '--graphics', 'none', '--console', 'pty,target_type=serial', '--noautoconsole'))
            write(folder / 'settings.sha256', n['signature'])
        elif n['name'] not in run('virsh', 'list', '--name').splitlines():
            run('virsh', 'start', n['name'])
        run('virsh', 'autostart', n['name'])
    children = {role: {'hosts': {n['name']: {'ansible_host': n['ip'], 'ansible_user': n['user']}
                for n in c['nodes'] if n['role'] == role}} for role in ('control_plane', 'workers')}
    infra = c['infra_ip']
    variables = {'ansible_become': True, 'apt_repo_url': f'http://{infra}:8081', 'control_plane_endpoint': f'{infra}:6443',
                 'harbor_registry': f'{infra}:8080', 'harbor_plain_http': True, 'harbor_skip_tls_verify': False,
                 'thanos_remote_write_url': f'http://{infra}:10908/api/v1/receive',
                 'metallb_ip_address_pool': c['metallb_pool'], 'argocd_ip': c['argocd_ip'], 'ntp_server': c['ntp_server']}
    write(root / 'hosts.yml', json.dumps({'all': {'vars': variables, 'children': children}}, indent=2) + '\n')
    backend = '\n'.join(f"    server {n['name']} {n['ip']}:6443 check" for n in c['nodes'] if n['role'] == 'control_plane')
    write(root / 'haproxy-backend.txt', backend + '\n')
    print(f'VMs started. Inventory: {root}/hosts.yml; HAProxy backend: {root}/haproxy-backend.txt')
    print(f"Before Kubernetes, ensure NTP server {c['ntp_server']} is reachable. Start deploy/infrastructure/ntp/compose.yaml before Kubernetes installation.")


if __name__ == '__main__':
    if '--json' in sys.argv:
        output = io.StringIO()
        error = None
        with contextlib.redirect_stdout(output):
            try:
                main()
            except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as exc:
                error = str(exc)
        print(json.dumps({'changed': CHANGED, 'failed': error is not None,
                          'message': error or 'VM operation completed.', 'log': output.getvalue()}))
        sys.exit(1 if error else 0)
    else:
        try:
            main()
        except KeyboardInterrupt:
            raise SystemExit('Interrupted. Files preserved; use --recover-incomplete on the next run if no VM was registered.') from None
        except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as exc:
            raise SystemExit(str(exc)) from exc
