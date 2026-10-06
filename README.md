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
- Flannel VXLAN, Pod CIDR `10.244.0.0/16`;
- local-path-provisioner для локальных PersistentVolume;
- NFS CSI-драйвер для подключения существующего внешнего NFS-сервера;
- локальный APT-репозиторий;
- Harbor для образов и Helm OCI charts;
- MetalLB, Gateway API и Traefik;
- Helm, K9s и kubectl для Linux, kubectl и K9s для Windows.

Monitoring, MinIO и Argo CD пока не входят в собираемый Release. Они будут
добавляться отдельным следующим слоем после стабилизации базового кластера.

## Как это устроено

Есть две стороны:

| Сторона | Что происходит |
| --- | --- |
| Машина с Интернетом | GitHub Actions скачивает пакеты, бинарники, charts, образы и официальный offline-installer Harbor, затем публикует GitHub Release |
| Закрытая сеть | Человек распаковывает Release, запускает локальные APT и Harbor, импортирует артефакты и устанавливает Kubernetes через Ansible + kubeadm |

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
| `tools-linux-amd64.tar.zst` | kubeadm, kubelet, kubectl, containerd, runc, CNI, Helm, K9s, crane, crictl и Docker Compose |
| `tools-windows-amd64.tar.zst` | `kubectl.exe` и `k9s.exe` |
| `harbor-offline.tar.zst` | Официальный offline-installer Harbor и инфраструктурные скрипты |
| `charts-platform.tar.zst` | NFS CSI, MetalLB и Traefik charts с values |
| `images-kubernetes-NNN.tar.zst` | Kubernetes, Flannel и local-path images |
| `images-networking-NNN.tar.zst` | Images из MetalLB и Traefik charts |
| `images-storage-NNN.tar.zst` | Images из NFS CSI chart |
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
| `192.168.122.11` | `cp-01` |
| `192.168.122.21` | `worker-01` |
| `192.168.122.22` | `worker-02` |
| `192.168.122.240-250` | Пул MetalLB, который необходимо исключить из DHCP |

Infrastructure-host одновременно используется как Ansible controller. Для
поддерживаемого bootstrap-сценария он должен работать на Debian 12 `amd64`,
иметь не менее 4 GiB RAM и 40 GiB свободного места. Kubernetes-узлам необходимо
не менее 2 CPU и 2 GiB RAM; для небольшого стенда рекомендуется примерно
2560 MiB для control plane и 2304 MiB для каждого worker.

Между Kubernetes-узлами должен проходить UDP `8472` для Flannel VXLAN. Также
необходимо разрешить используемые Kubernetes-порты, включая TCP `6443` и
`10250`.

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

### 4. Установить Harbor

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

### 5. Импортировать images и charts в Harbor

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

### 6. Скопировать bundle на Kubernetes-узлы

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
/opt/k8s-airgap/deploy/nodes/ansible/templates/flannel.yaml.j2
```

### 7. Настроить Ansible inventory

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

### 8. Установить базовый Kubernetes-кластер

Одна команда последовательно настраивает APT, подготавливает ноды, устанавливает
containerd/kubelet/kubeadm, выполняет `kubeadm init`, устанавливает Flannel и
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
playbooks/install-nfs-csi.yml
```

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

### 9. Проверить базовый кластер

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A -o wide'
```

Все control-plane и worker-узлы из inventory должны перейти в `Ready`, а
Flannel, CoreDNS и local-path-provisioner — в `Running`.

Дополнительно проверить NFS CSI:

```bash
ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get csidriver nfs.csi.k8s.io'

ssh deploy@192.168.122.11 \
  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs'
```

### 10. Установить MetalLB и Traefik

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

## Как работают images без переименования manifests

Образы сохраняются в Harbor с полным upstream path:

```text
registry.k8s.io/kube-apiserver:v1.36.2
  -> harbor.internal:8080/k8s/kube-apiserver:v1.36.2

ghcr.io/flannel-io/flannel:v0.28.7
  -> harbor.internal:8080/ghcr/flannel-io/flannel:v0.28.7
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
- local-path-provisioner не обеспечивает отказоустойчивое хранилище.
- NFS CSI не разворачивает NFS-сервер: доступный с каждой ноды NFS export
  должен существовать отдельно.
- Monitoring, MinIO и Argo CD пока не собираются и не устанавливаются.
- VM image не входит в Release: Debian 12 должен быть установлен или подготовлен
  заранее.

Пароли Harbor, kubeconfig, приватные SSH-ключи и любые production-секреты не
должны храниться в этом репозитории или публиковаться в Release.
