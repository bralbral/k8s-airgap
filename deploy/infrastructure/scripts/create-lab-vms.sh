#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 <debian-12-genericcloud.qcow2> <ssh-public-key-file>" >&2
  exit 2
}

base_image="${1:-}"
public_key_file="${2:-}"
[[ -f "${base_image}" && -f "${public_key_file}" ]] || usage

for command_name in virsh virt-install qemu-img cloud-localds; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

libvirt_network="${LAB_LIBVIRT_NETWORK:-default}"
vm_dir="${LAB_VM_DIR:-/var/lib/libvirt/images/k8s-airgap}"
ssh_public_key="$(<"${public_key_file}")"
[[ "${ssh_public_key}" == ssh-* ]] || { echo "The public key does not look like an SSH key" >&2; exit 2; }

virsh --connect qemu:///system net-info "${libvirt_network}" >/dev/null
if ! virsh --connect qemu:///system net-info "${libvirt_network}" | grep -q '^Active:.*yes'; then
  virsh --connect qemu:///system net-start "${libvirt_network}"
fi

install -d -m 0755 "${vm_dir}"
installed_base="${vm_dir}/debian-12-genericcloud-base.qcow2"
if [[ ! -f "${installed_base}" ]]; then
  install -m 0644 "${base_image}" "${installed_base}"
fi

names=(cp-01 worker-01 worker-02)
addresses=(192.168.122.11 192.168.122.21 192.168.122.22)
macs=(52:54:00:12:20:11 52:54:00:12:20:21 52:54:00:12:20:22)
memory=(2560 2304 2304)
disk_sizes=(24G 32G 32G)

for index in "${!names[@]}"; do
  name="${names[$index]}"
  address="${addresses[$index]}"
  mac="${macs[$index]}"
  disk="${vm_dir}/${name}.qcow2"
  seed="${vm_dir}/${name}-seed.iso"
  cloud_dir="${vm_dir}/${name}-cloud-init"

  if virsh --connect qemu:///system dominfo "${name}" >/dev/null 2>&1; then
    echo "VM already exists, leaving it unchanged: ${name}"
    continue
  fi
  [[ ! -e "${disk}" ]] || { echo "Refusing to overwrite existing disk: ${disk}" >&2; exit 1; }

  install -d -m 0700 "${cloud_dir}"
  printf '%s\n' \
    '#cloud-config' \
    "hostname: ${name}" \
    'manage_etc_hosts: true' \
    'users:' \
    '  - name: deploy' \
    '    groups: [sudo]' \
    '    shell: /bin/bash' \
    '    sudo: ALL=(ALL) NOPASSWD:ALL' \
    '    lock_passwd: true' \
    '    ssh_authorized_keys:' \
    "      - ${ssh_public_key}" \
    'ssh_pwauth: false' \
    'disable_root: true' \
    'package_update: false' \
    > "${cloud_dir}/user-data"
  printf 'instance-id: %s\nlocal-hostname: %s\n' "${name}" "${name}" > "${cloud_dir}/meta-data"
  printf '%s\n' \
    'version: 2' \
    'ethernets:' \
    '  ens3:' \
    '    match:' \
    "      macaddress: '${mac}'" \
    '    set-name: ens3' \
    '    dhcp4: true' \
    > "${cloud_dir}/network-config"

  qemu-img create -f qcow2 -F qcow2 -b "${installed_base}" "${disk}" "${disk_sizes[$index]}"
  cloud-localds --network-config="${cloud_dir}/network-config" \
    "${seed}" "${cloud_dir}/user-data" "${cloud_dir}/meta-data"

  if ! virsh --connect qemu:///system net-dumpxml "${libvirt_network}" | grep -q "name='${name}'"; then
    virsh --connect qemu:///system net-update "${libvirt_network}" add ip-dhcp-host \
      "<host mac='${mac}' name='${name}' ip='${address}'/>" --live --config
  fi

  virt-install \
    --connect qemu:///system \
    --name "${name}" \
    --memory "${memory[$index]}" \
    --vcpus 2 \
    --cpu host-passthrough \
    --os-variant debian12 \
    --disk "path=${disk},format=qcow2,bus=virtio" \
    --disk "path=${seed},device=cdrom" \
    --network "network=${libvirt_network},model=virtio,mac=${mac}" \
    --graphics none \
    --import \
    --noautoconsole
done

echo "VM creation submitted. Wait for cloud-init, then test: ssh deploy@192.168.122.11"
