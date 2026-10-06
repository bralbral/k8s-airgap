# Kubernetes Air-Gap для Debian 12

Репозиторий собирает переносимый набор для установки vanilla Kubernetes в
полностью изолированной сети. Kubernetes устанавливается официальными
`kubeadm`, `kubelet` и `kubectl`; Kubespray и другие Kubernetes-дистрибутивы не
используются.

Поддерживаемая конфигурация:

- один или несколько control-plane узлов; для HA рекомендуется три;
- произвольное количество worker-узлов;
- готовый лабораторный профиль: один control plane и два worker-узла;
- Debian 12, `amd64`;
- containerd с `systemd` cgroups;
- Cilium в VXLAN tunnel-режиме, Pod CIDR `10.244.0.0/16`;
- local-path-provisioner для локальных PersistentVolume;
- NFS CSI-драйвер для подключения существующего внешнего NFS-сервера;
- локальный APT-репозиторий;
- Harbor для образов и Helm OCI charts;
- MetalLB, Gateway API и Traefik;
- Metrics Server, cert-manager и Argo CD;
- внешний Vault с Raft storage и интеграцией cert-manager через Kubernetes Auth;
- Helm, K9s и kubectl для Linux, kubectl и K9s для Windows.

Prometheus Agent, Thanos, MinIO и остальной monitoring пока не входят в
собираемый Release. Они будут добавлены отдельным следующим слоем.

## Как это устроено

Есть две стороны:

| Сторона | Что происходит |
| --- | --- |
| Машина с Интернетом | GitHub Actions скачивает пакеты, бинарники, charts, образы и официальный offline-installer Harbor, затем публикует GitHub Release |
| Закрытая сеть | Человек распаковывает Release, запускает локальные APT, Harbor и Vault, импортирует артефакты и устанавливает Kubernetes через Ansible + kubeadm |

GitHub-специфичная логика находится только в `.github/`. Всё, что запускается
в закрытом контуре вручную, находится в `deploy/`.

## Структура репозитория

```text
.
├── .github/
│   ├── workflows/
│   │   ├── validate.yml
│   │   └── build-bundle.yml
│   └── scripts/
│       ├── validate.sh
│       ├── validate-config.py
│       ├── smoke-test-release.sh
│       ├── build-bundle.sh
│       ├── package-release.sh
│       └── publish-release.sh
├── config/
│   ├── versions.env
│   ├── packages.txt
│   ├── extra-images.txt
│   ├── registries.yaml
│   └── cluster-defaults.yaml
└── deploy/
    ├── infrastructure/
    │   ├── apt/
    │   ├── scripts/
    │   └── compose.yaml
    ├── nodes/ansible/
    │   ├── inventory/
    │   ├── playbooks/
    │   └── templates/
    ├── platform/
    └── scripts/
```

Основные настраиваемые файлы:

| Файл | Назначение |
| --- | --- |
| `config/versions.env` | Версии Kubernetes, containerd, Harbor, Helm, K9s и остальных компонентов |
| `config/packages.txt` | Пакеты, которые попадут в offline APT closure |
| `config/extra-images.txt` | Дополнительные OCI-образы для скачивания |
| `config/registries.yaml` | Соответствие upstream registries проектам Harbor |
| `deploy/nodes/ansible/inventory/*.example.yml` | Адреса узлов, APT, Harbor, API endpoint, MetalLB pool и необязательный NFS export |

## Что делает GitHub Actions

После каждого push и pull request автоматически запускается workflow
`Validate`. Он проверяет:

- Bash-синтаксис и ShellCheck;
- YAML;
- согласованность закреплённых версий;
- синтаксис всех Ansible playbook;
- упаковку, контрольные суммы и обратную распаковку тестового Release.

Сам bundle собирается вручную:

1. Открыть вкладку **Actions**.
2. Выбрать **Build offline bundle**.
3. Нажать **Run workflow**.

Этот workflow сначала повторяет validation, затем скачивает все артефакты и
создаёт Release с автоматически сформированным тегом:

```text
airgap-v1.36.2-build.<номер запуска>.<номер попытки>
```

## Структура GitHub Release

Release состоит из нескольких файлов, а не из одного огромного архива:

| Asset | Содержимое |
| --- | --- |
| `bootstrap.tar.zst` | README, manifest, конфигурация, скрипты распаковки и проверки |
| `automation.tar.zst` | Ansible playbooks, templates и Kubernetes manifests |
| `apt-debian12-amd64.tar.zst` | Файловый APT-репозиторий и готовый nginx Docker image |
| `tools-linux-amd64.tar.zst` | kubeadm, kubelet, kubectl, containerd, runc, CNI, Helm, K9s, Vault, crane, crictl и Docker Compose |
| `tools-windows-amd64.tar.zst` | `kubectl.exe` и `k9s.exe` |
| `harbor-offline.tar.zst` | Официальный offline-installer Harbor и инфраструктурные скрипты |
| `charts-platform.tar.zst` | Cilium, NFS CSI, MetalLB, Traefik, Metrics Server, cert-manager и Argo CD charts с values |
| `images-kubernetes-NNN.tar.zst` | Kubernetes и local-path images |
| `images-networking-NNN.tar.zst` | Images из Cilium, MetalLB и Traefik charts |
| `images-storage-NNN.tar.zst` | Images из NFS CSI chart |
| `images-platform-NNN.tar.zst` | Images Metrics Server, cert-manager и Argo CD |
| `images-extra-NNN.tar.zst` | Необязательные images из `config/extra-images.txt` |
| `bundle-manifest.yaml` | Описание состава Release |
| `SHA256SUMS` | Контрольные суммы всех Release assets |
| `unpack-release.sh` | Проверка и сборка assets в единое дерево |

Образы автоматически разбиваются на части, чтобы каждый asset оставался меньше
ограничения GitHub в 2 GiB.

Нужно скачать **все файлы одного Release** в одну директорию. Нельзя смешивать
assets из разных запусков.

На машине с Интернетом это можно сделать через GitHub CLI:

```bash
mkdir k8s-airgap-release
gh release download RELEASE_TAG --dir k8s-airgap-release
```

После этого вся директория переносится в закрытую сеть, например на внешний
диск.

## Сетевая схема тестового стенда

Пример `lab.example.yml` использует сеть libvirt `192.168.122.0/24`:

| Адрес | Назначение |
| --- | --- |
| `192.168.122.1:8080` | Harbor на infrastructure-host |
| `192.168.122.1:8081` | APT-репозиторий на infrastructure-host |
| `192.168.122.1:8200` | Vault API на infrastructure-host |
| `192.168.122.11` | `cp-01` |
| `192.168.122.21` | `worker-01` |
| `192.168.122.22` | `worker-02` |
| `192.168.122.240-250` | Пул MetalLB, который необходимо исключить из DHCP |

Infrastructure-host одновременно используется как Ansible controller. Для
поддерживаемого bootstrap-сценария он должен работать на Debian 12 `amd64`,
иметь не менее 4 GiB RAM и 40 GiB свободного места. Kubernetes-узлам необходимо
не менее 2 CPU и 2 GiB RAM; для небольшого стенда рекомендуется примерно
2560 MiB для control plane и 2304 MiB для каждого worker.

Между Kubernetes-узлами должен проходить UDP `8472` для Cilium VXLAN. Также
необходимо разрешить используемые Kubernetes-порты, включая TCP `6443` и
`10250`. От Kubernetes-нод к infrastructure-host должен проходить TCP `8200`.

## Control plane: один или несколько

Количество control-plane узлов определяется группой `control_plane` в Ansible
inventory. Отдельной переменной `master_count` нет.

| Режим | Группа `control_plane` | `k8s-api.internal` | `control_plane_endpoint_is_load_balancer` |
| --- | --- | --- | --- |
| Single | Один узел | Адрес этого control plane | `false` |
| HA | Несколько узлов, рекомендуется три | VIP или DNS внешнего TCP load balancer | `true` |

В режиме HA первый узел инициализируется через `kubeadm init`, после чего
остальные последовательно присоединяются через `kubeadm join --control-plane`.
Группа `workers` независимо определяет количество worker-узлов.

Для отказоустойчивого кластера рекомендуется три control-plane узла, а не два.
Перед ними нужен единый стабильный API endpoint:

```text
                  k8s-api.internal:6443
                            |
                  TCP load balancer / VIP
                     /       |       \
                  cp-01    cp-02    cp-03
```

`control_plane_endpoint` должен указывать на DNS-имя или VIP балансировщика, а
не на адрес `cp-01`. Балансировщик перенаправляет TCP `6443` на все
control-plane узлы. Для стенда это может быть HAProxy на infrastructure-host;
для реальной отказоустойчивости сам балансировщик/VIP также должен быть
резервирован, например парой HAProxy + Keepalived или внешним аппаратным
балансировщиком.

При нескольких control-plane узлах необходимо явно подтвердить, что endpoint
подготовлен:

```yaml
control_plane_endpoint: k8s-api.internal:6443
control_plane_endpoint_is_load_balancer: true
```

Готовый пример inventory для HA находится в
`inventory/ha.example.yml`. В нём `k8s-api.internal` указывает на VIP
`10.10.0.10`, а не на один из control-plane узлов:

```yaml
airgap_host_entries:
  - address: 10.10.0.10
    names: [k8s-api.internal]

children:
  control_plane:
    hosts:
      cp-01:
        ansible_host: 10.10.0.11
      cp-02:
        ansible_host: 10.10.0.12
      cp-03:
        ansible_host: 10.10.0.13
```

После переноса bundle одна команда `playbooks/install-cluster.yml` выполняет
всю последовательность:

1. Подготовить все control-plane и worker-узлы одинаковым bundle.
2. Проверить, что настроенный заранее балансировщик принимает
   `k8s-api.internal:6443` и использует control-plane узлы как backends.
3. Выполнить `kubeadm init` на `cp-01` с общим `controlPlaneEndpoint`.
4. Выполнить `kubeadm init phase upload-certs --upload-certs`, получить
   временный certificate key и присоединить `cp-02`, `cp-03` и другие узлы из
   группы командой `kubeadm join --control-plane`.
5. Присоединить workers к тому же API endpoint обычной командой `kubeadm join`.

Kubeadm в такой конфигурации создаёт stacked etcd: по одному участнику etcd на
каждом control-plane узле. Для кворума и переживания отказа одного узла нужны
три участника.

Получение certificate key и присоединение дополнительных control-plane узлов
автоматизированы в `join-control-planes.yml`. Сам внешний API load balancer
репозиторий пока не разворачивает: он должен существовать до запуска kubeadm.

Существующий single-control-plane кластер также можно расширить до трёх узлов.
Для этого нужно сохранить прежнее имя `k8s-api.internal`, поднять перед текущим
`cp-01` балансировщик, перенаправить это имя на VIP, добавить `cp-02` и `cp-03`
в inventory, включить `control_plane_endpoint_is_load_balancer` и снова
запустить `install-cluster.yml`. Уже присоединённые узлы будут пропущены.
Автоматическое уменьшение количества control-plane узлов не поддерживается:
для удаления участника нужны отдельные операции kubeadm и etcd, поэтому просто
удалять его из inventory нельзя.

## Установка после скачивания Release

Все дальнейшие команды выполняются в закрытой сети.

### 1. Распаковать и проверить Release

```bash
cd /path/to/k8s-airgap-release
bash unpack-release.sh "$PWD" ../k8s-airgap
cd ../k8s-airgap
```

Скрипт сначала проверит Release `SHA256SUMS`, распакует все component archives,
а затем проверит внутреннюю структуру bundle. Успешный результат заканчивается
строкой:

```text
Bundle structure: OK
```

Итоговая структура будет выглядеть так:

```text
k8s-airgap/
├── README.md
├── manifest.yaml
├── manifest.env
├── repositories/
│   ├── apt/
│   │   ├── repository/
│   │   └── apt-repo-debian12-amd64.tar.gz
│   └── registry/
│       ├── images/
│       │   ├── archives/
│       │   ├── groups/
│       │   └── images.txt
│       ├── charts/
│       │   ├── archives/
│       │   └── values/
│       └── mapping.yaml
├── tools/
└── deploy/
```

### 2. Подготовить infrastructure-host

Скрипт использует файловый APT-репозиторий из bundle и без Интернета
устанавливает Docker Engine, Docker Compose и Ansible. Старые APT sources
сохраняются в `/etc/apt/k8s-airgap-bootstrap-backup`.

```bash
sudo ./deploy/infrastructure/scripts/bootstrap-host.sh "$PWD"
```

### 3. Запустить локальный APT

```bash
cp deploy/infrastructure/.env.example deploy/infrastructure/.env

docker load < repositories/apt/apt-repo-debian12-amd64.tar.gz

docker compose \
  --env-file deploy/infrastructure/.env \
  -f deploy/infrastructure/compose.yaml \
  up -d --no-build apt-repo

curl --fail http://127.0.0.1:8081/healthz
```

На Kubernetes-узлах этот репозиторий будет доступен как
`http://192.168.122.1:8081/debian`.

### 4. Установить и инициализировать внешний Vault

Vault устанавливается как systemd-сервис непосредственно на
infrastructure-host, то есть вне Kubernetes. Бинарник уже находится в
`tools/vault`; Интернет не требуется. В лабораторном профиле используется один
Vault-узел с integrated Raft storage в `/var/lib/vault` и HTTP listener.

Указать адрес infrastructure-host, доступный с Kubernetes-нод, и установить
сервис:

```bash
export VAULT_API_ADDRESS=http://192.168.122.1:8200

sudo -E ./deploy/infrastructure/scripts/install-vault.sh "$PWD"
```

Повторный запуск установщика обновляет бинарник и конфигурацию, перезапускает
сервис и тем самым снова переводит уже инициализированный Vault в sealed.
После него необходимо выполнить `unseal-vault.sh`.

Инициализировать Vault и автоматически создать:

- Root CA `pki_root` со сроком 10 лет;
- Intermediate CA `pki_int` со сроком 5 лет;
- роль `pki_int/roles/kubernetes` для доменов `*.internal` и
  `*.cluster.local`;
- policy `cert-manager` для выпуска сертификатов.

```bash
sudo -E env \
  VAULT_PUBLIC_ADDRESS=http://192.168.122.1:8200 \
  ./deploy/infrastructure/scripts/initialize-vault.sh
```

Для стенда по умолчанию создаётся один unseal key с threshold `1`. Результат
инициализации сохраняется с правами `0600`:

```text
/root/vault-init.json
```

Этот файл содержит unseal key и первоначальный root token. Сделайте его
проверенную зашифрованную резервную копию и не переносите в Git, Release или
на Kubernetes-ноды. Потеря файла вместе с работающим хостом означает потерю
доступа к данным Vault.

Проверка:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
sudo -E vault status
curl --fail http://127.0.0.1:8200/v1/sys/health
```

После перезагрузки Vault стартует sealed. Для лабораторного стенда его нужно
разблокировать вручную:

```bash
sudo ./deploy/infrastructure/scripts/unseal-vault.sh
```

Кроме initialization JSON необходимо сохранять данные Raft. Скрипт создаёт
новый snapshot и намеренно не перезаписывает существующий файл:

```bash
sudo install -d -m 0700 /var/backups/vault
sudo ./deploy/infrastructure/scripts/backup-vault.sh \
  /var/backups/vault/vault-raft.snap
```

Snapshot и `/root/vault-init.json` необходимо копировать в защищённое внешнее
хранилище. Один файл не заменяет другой: snapshot содержит данные Vault, а
initialization JSON — ключи для их расшифровки.

Перед production необходимо выбрать отдельную схему хранения unseal keys или
Auto Unseal. Текущий `1/1` профиль сделан только для автономного стенда.

### 5. Установить Harbor

В лабораторном профиле Harbor работает по HTTP на полностью приватной сети.
Сертификаты не требуются. Пароль должен состоять из букв, цифр, точки,
подчёркивания и дефиса.

```bash
export HARBOR_HOSTNAME=harbor.internal
export HARBOR_HTTP_PORT=8080
export HARBOR_DATA_DIR=/var/lib/harbor
export HARBOR_ADMIN_PASSWORD='ChangeMe_12345'

harbor_installer="$(find deploy/infrastructure/harbor -maxdepth 1 \
  -name 'harbor-offline-installer-*.tgz' -print -quit)"

sudo -E ./deploy/infrastructure/scripts/install-harbor.sh \
  "${harbor_installer}"
```

Проверка:

```bash
curl --fail http://harbor.internal:8080/api/v2.0/health
```

Установщик создаёт публичные проекты:

```text
docker
ghcr
quay
k8s
charts
```

Push требует авторизацию, pull из этих проектов доступен без Kubernetes image
pull secrets.

### 6. Импортировать images и charts в Harbor

Войти в Harbor через bundled crane:

```bash
./tools/crane auth login harbor.internal:8080 \
  --insecure \
  -u admin
```

Импортировать все OCI images:

```bash
./deploy/infrastructure/scripts/import-images-to-harbor.sh \
  --registry harbor.internal:8080 \
  --insecure \
  "$PWD"
```

Импортировать Helm charts в OCI project `charts`:

```bash
export HARBOR_PASSWORD="${HARBOR_ADMIN_PASSWORD}"

./deploy/infrastructure/scripts/import-charts-to-harbor.sh \
  --registry harbor.internal:8080 \
  --plain-http \
  "$PWD"

unset HARBOR_PASSWORD
```

### 7. Скопировать bundle на Kubernetes-узлы

Playbooks ожидают bundle непосредственно в `/opt/k8s-airgap` на каждой ноде.
Не создавайте внутри ещё одну директорию с версией.

Пример для одного узла; повторить для каждого control-plane и worker-узла из
inventory:

```bash
scp -r . deploy@192.168.122.11:/tmp/k8s-airgap

ssh deploy@192.168.122.11 \
  'sudo mkdir -p /opt/k8s-airgap && sudo cp -a /tmp/k8s-airgap/. /opt/k8s-airgap/'

ssh deploy@192.168.122.11 \
  'sudo /opt/k8s-airgap/deploy/scripts/verify-bundle.sh /opt/k8s-airgap'
```

После копирования на всех узлах должны существовать, например:

```text
/opt/k8s-airgap/tools/kubeadm
/opt/k8s-airgap/tools/containerd.tar.gz
/opt/k8s-airgap/repositories/registry/charts/archives/cilium-*.tgz
```

### 8. Настроить Ansible inventory

На infrastructure-host:

```bash
cd deploy/nodes/ansible
cp inventory/lab.example.yml inventory/hosts.yml
```

Для трёх control-plane узлов вместо лабораторного примера использовать:

```bash
cp inventory/ha.example.yml inventory/hosts.yml
```

Проверить и при необходимости изменить в `inventory/hosts.yml`:

- IP control plane и workers;
- `apt_repo_url`;
- адрес infrastructure-host для `harbor.internal`;
- адрес control plane для `k8s-api.internal`; в HA-схеме — VIP внешнего API
  load balancer;
- `control_plane_endpoint`;
- `control_plane_endpoint_is_load_balancer`: `false` для одного control plane,
  `true` для нескольких;
- `metallb_ip_address_pool`;
- `argocd_hostname` и необходимость создания Argo CD HTTPRoute;
- адрес и параметры внешнего Vault PKI, если нужен `ClusterIssuer`;
- параметры внешнего NFS-сервера, если нужен `nfs-csi` StorageClass;
- SSH-пользователя `ansible_user`.

Пример ключевой части inventory:

```yaml
all:
  vars:
    ansible_user: deploy
    ansible_become: true
    kube_version: v1.36.2
    pod_subnet: 10.244.0.0/16
    service_subnet: 10.96.0.0/12
    control_plane_endpoint: k8s-api.internal:6443
    control_plane_endpoint_is_load_balancer: false
    apt_repo_url: http://192.168.122.1:8081/debian
    apt_repo_trusted: true
    harbor_registry: harbor.internal:8080
    harbor_plain_http: true
    harbor_skip_tls_verify: false
    argocd_hostname: argocd.internal
    argocd_create_http_route: true
    cert_manager_vault_enabled: true
    cert_manager_vault_server: http://192.168.122.1:8200
    cert_manager_vault_allow_insecure_http: true
    nfs_csi_create_storage_class: false
    nfs_csi_server: ''
    nfs_csi_share: ''
    airgap_host_entries:
      - address: 192.168.122.1
        names: [harbor.internal]
      - address: 192.168.122.11
        names: [k8s-api.internal]
  children:
    control_plane:
      hosts:
        cp-01:
          ansible_host: 192.168.122.11
    workers:
      hosts:
        worker-01:
          ansible_host: 192.168.122.21
        worker-02:
          ansible_host: 192.168.122.22
```

SSH host keys должны быть заранее приняты, поскольку их проверка включена.
Проверить доступ без зависимости от установленного Python:

```bash
ansible -i inventory/hosts.yml all \
  -b -m raw -a 'cat /etc/debian_version'
```

### 9. Установить базовый Kubernetes-кластер

Одна команда последовательно настраивает APT, подготавливает ноды, устанавливает
containerd/kubelet/kubeadm, выполняет `kubeadm init`, устанавливает Cilium и
local-path-provisioner, последовательно присоединяет дополнительные control
plane и workers, а затем устанавливает NFS CSI:

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/install-cluster.yml
```

Отдельные playbooks сохранены для диагностики и пошагового запуска:

```text
playbooks/configure-apt.yml
playbooks/prepare-nodes.yml
playbooks/init-control-plane.yml
playbooks/join-control-planes.yml
playbooks/join-workers.yml
playbooks/configure-cilium.yml
playbooks/install-nfs-csi.yml
```

Cilium устанавливается с kube-proxy, VXLAN tunnel и Kubernetes IPAM. Hubble,
метрики Cilium, отдельный Envoy DaemonSet и L7 proxy на этом этапе выключены.
Встроенный Cilium LB IPAM также выключен: адреса Service типа LoadBalancer
выдаёт только MetalLB. Стандартные Kubernetes NetworkPolicy уже поддерживаются.

Это сценарий чистой установки. Автоматическая замена Flannel на Cilium в уже
работающем кластере не реализована: такой кластер необходимо пересоздать либо
мигрировать отдельно по согласованной процедуре.

Сам NFS CSI-драйвер устанавливается всегда, если `nfs_csi_enabled: true`.
Наличие NFS-сервера для установки драйвера не требуется. По умолчанию
`nfs_csi_create_storage_class: false`, поэтому драйвер ничего не
провизионирует и не меняет default StorageClass.

Чтобы подключить существующий NFS-сервер, перед установкой указать в inventory:

```yaml
nfs_csi_create_storage_class: true
nfs_csi_server: 192.168.122.50
nfs_csi_share: /exports/kubernetes
nfs_csi_storage_class: nfs-csi
```

Будет создан не-default StorageClass `nfs-csi` с provisioner
`nfs.csi.k8s.io`. `local-path` и `nfs-csi` не конфликтуют: приложение выбирает
нужный класс через `spec.storageClassName`. Если NFS добавили уже после
развёртывания кластера, достаточно повторно запустить:

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/install-nfs-csi.yml
```

NFS-сервер или дисковая полка в bundle не входят: CSI-драйвер подключает уже
существующий NFS export. На всех нодах пакет `nfs-common` устанавливается
автоматически из локального APT.

### 10. Проверить базовый кластер

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A -o wide'
```

Все control-plane и worker-узлы из inventory должны перейти в `Ready`, а
Cilium, CoreDNS и local-path-provisioner — в `Running`.

Дополнительно проверить NFS CSI:

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get csidriver nfs.csi.k8s.io'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs'
```

### 11. Установить MetalLB и Traefik

Сначала убедиться, что MetalLB pool исключён из DHCP и доступен в той же L2
сети, что и Kubernetes-ноды.

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/install-edge.yml
```

Проверка:

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get svc -n traefik'
```

### 12. Привязать Vault и установить платформенные компоненты

После появления kube-apiserver внешний Vault нужно один раз связать с этим
кластером. Скопировать публичный Kubernetes CA с первого control-plane на
infrastructure-host:

```bash
ssh deploy@192.168.122.11 \
  'sudo cat /etc/kubernetes/pki/ca.crt' \
  | sudo tee /root/kubernetes-ca.crt >/dev/null
sudo chmod 0600 /root/kubernetes-ca.crt
```

Настроить отдельный Kubernetes Auth mount, TokenReview и Vault role для
cert-manager:

```bash
sudo ../../infrastructure/scripts/configure-vault-kubernetes.sh \
  https://192.168.122.11:6443 \
  /root/kubernetes-ca.crt
```

В HA-конфигурации первым параметром указывается общий VIP/DNS API load
balancer, например `https://k8s-api.internal:6443`. Этот адрес должен входить в
SAN сертификата kube-apiserver и разрешаться с infrastructure-host.

Этот этап запускается после MetalLB и Traefik, поскольку playbook сразу создаёт
HTTPRoute для Argo CD через Gateway `traefik/public`:

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/install-platform.yml
```

Если публиковать Argo CD через Traefik пока не нужно, установить в inventory
`argocd_create_http_route: false`; остальные компоненты установятся как обычно.

Проверить компоненты:

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf top nodes'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n cert-manager'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n argocd'
```

Узнать адрес Traefik:

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get svc -n traefik traefik'
```

На администраторской машине сопоставить полученный `EXTERNAL-IP` имени
`argocd.internal`, после чего открыть `http://argocd.internal`. Начальный логин
— `admin`, пароль хранится в Secret:

```bash
kubectl --kubeconfig=/path/to/admin.conf \
  -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Argo CD в изолированной сети должен использовать внутренний Git-сервер или
другой репозиторий, доступный из кластера. cert-manager устанавливается вместе
с CRD и создаёт Vault `ClusterIssuer` с именем `vault-pki`. Если Vault в
конкретном окружении не нужен, перед запуском установить
`cert_manager_vault_enabled: false`.

Metrics Server использует `--kubelet-insecure-tls`, поскольку стандартный
kubeadm-профиль не выдаёт kubelet serving certificates через автоматически
одобряемый CSR flow. После настройки доверенных kubelet-сертификатов этот флаг
следует удалить из `values/metrics-server.yaml`.

### Внешний Vault как PKI для cert-manager

Vault работает вне Kubernetes и должен быть доступен одновременно:

- из Pod cert-manager — Vault API на TCP `8200`;
- с Vault-host — Kubernetes API endpoint на TCP `6443`.

Имя в `cert_manager_vault_server` должно разрешаться из Pod. Запись только в
`/etc/hosts` Kubernetes-нод для этого недостаточна: используйте внутренний DNS
либо укажите IP Vault-host непосредственно.

Интеграция использует короткоживущий ServiceAccount JWT. cert-manager создаёт
его для ServiceAccount `cert-manager/vault-issuer`, а внешний Vault проверяет
JWT через Kubernetes TokenReview API. Статический Vault token и постоянный
`token_reviewer_jwt` в Kubernetes не сохраняются.

Все эти объекты создаются скриптами из шага 4 и шага 12. Соответствующая
конфигурация inventory выглядит так:

```yaml
cert_manager_vault_enabled: true
cert_manager_vault_server: http://192.168.122.1:8200
cert_manager_vault_allow_insecure_http: true
cert_manager_vault_pki_path: pki_int/sign/kubernetes
cert_manager_vault_auth_mount: /v1/auth/kubernetes-airgap
cert_manager_vault_role: cert-manager
cert_manager_vault_cluster_issuer: vault-pki
cert_manager_vault_kubernetes_api_audience: https://kubernetes.default.svc.cluster.local
```

В текущем профиле закрытого контура Vault работает по HTTP. Небезопасный режим
фиксируется явно через `cert_manager_vault_allow_insecure_http: true`, чтобы
выбор был виден в inventory. Установщик создаёт следующий listener:

```hcl
api_addr = "http://192.168.122.1:8200"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
```

При HTTP ServiceAccount JWT, запросы на выпуск сертификатов и ответы Vault
передаются открытым текстом. Доступ к TCP `8200` необходимо ограничить
firewall подсетями Kubernetes-нод и административной сети. Если позже режим
будет изменён на HTTPS, задаётся `https://...`, insecure-флаг переключается в
`false`, а приватный CA передаётся через `cert_manager_vault_ca_bundle` в PEM.

После `install-platform.yml` проверить:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  get clusterissuer vault-pki
```

Состояние должно быть `READY=True`. Сам `ClusterIssuer` не переводит Traefik
или Argo CD на HTTPS автоматически: приложение должно создать объект
`Certificate` и подключить полученный TLS Secret к HTTPS listener/route.

## Как работают images без переименования manifests

Образы сохраняются в Harbor с полным upstream path:

```text
registry.k8s.io/kube-apiserver:v1.36.2
  -> harbor.internal:8080/k8s/kube-apiserver:v1.36.2

quay.io/cilium/cilium:v1.20.2
  -> harbor.internal:8080/quay/cilium/cilium:v1.20.2
```

Kubernetes manifests продолжают ссылаться на исходные имена. На каждой ноде
Ansible создаёт containerd mirror-конфигурацию:

```text
/etc/containerd/certs.d/docker.io/hosts.toml
/etc/containerd/certs.d/ghcr.io/hosts.toml
/etc/containerd/certs.d/quay.io/hosts.toml
/etc/containerd/certs.d/registry.k8s.io/hosts.toml
```

В `/etc/hosts` добавляются только реальные внутренние имена:

```text
192.168.122.1  harbor.internal
192.168.122.11 k8s-api.internal
```

Не нужно добавлять туда `docker.io`, `ghcr.io`, `quay.io` или
`registry.k8s.io`: перенаправление выполняет containerd.

## K9s и kubectl

В Linux bundle находятся:

```text
tools/kubectl
tools/k9s
```

В Windows bundle:

```text
tools/windows-amd64/kubectl.exe
tools/windows-amd64/k9s.exe
```

Для удалённого управления нужно безопасно скопировать
`/etc/kubernetes/admin.conf` с control plane на администраторскую машину и
указать его через `KUBECONFIG`. Этот файл предоставляет полные права
cluster-admin и не должен попадать в Git или GitHub Release.

## Ограничения текущего этапа

- Поддерживаются Debian 12 и `amd64`.
- Поддерживается один или несколько control-plane узлов. Для нескольких
  control plane требуется заранее настроенный внешний API load balancer/VIP;
  сам балансировщик репозиторий пока не разворачивает.
- Лабораторный APT unsigned и используется через `Trusted: yes`.
- Harbor работает по HTTP и предназначен только для доверенной приватной сети.
- Vault устанавливается одним standalone-узлом с Raft storage и ручным
  Shamir unseal. Это лабораторная, а не отказоустойчивая конфигурация. Vault
  API работает по HTTP, поэтому TCP `8200` должен быть доступен только из
  доверенных подсетей.
- local-path-provisioner не обеспечивает отказоустойчивое хранилище.
- NFS CSI не разворачивает NFS-сервер: доступный с каждой ноды NFS export
  должен существовать отдельно.
- Prometheus Agent, Thanos и MinIO пока не собираются и не устанавливаются.
- VM image не входит в Release: Debian 12 должен быть установлен или подготовлен
  заранее.

Пароли Harbor, kubeconfig, приватные SSH-ключи и любые production-секреты не
должны храниться в этом репозитории или публиковаться в Release.
