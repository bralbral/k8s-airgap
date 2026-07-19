# Node prerequisites

Before using Ansible, each Debian 12 node needs only:

- a static, unique hostname and an IP reachable by every other cluster node;
- DNS resolution for the API endpoint and internal Harbor;
- correct time (NTP/chrony), at least 2 CPU and 2 GiB RAM for a control-plane node;
- a working SSH account with sudo from the administrator host;
- an unpacked bundle copied to `/opt/k8s-airgap` on the node.

The playbook disables swap, configures kernel modules and sysctls, installs runtime/Kubernetes binaries from the bundle, enables containerd and kubelet, and creates the directory for local persistent volumes.

For Flannel VXLAN, permit UDP `8472` between every Kubernetes node. Also permit Kubernetes control-plane and node ports appropriate to the firewall policy. Do not use a Pod CIDR that overlaps any routed corporate network.

`local-path-provisioner` is intentionally not highly available: a PVC stays on its creating node. Do not use it as the sole storage for a database that needs node-failure tolerance.
