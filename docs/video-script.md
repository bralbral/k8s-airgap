# Последовательность демонстрации

Все команды выполняются из корня репозитория на инфраструктурной машине.
Сохраняются исходники, `.venv`, `release/`, `data/`, исходный Debian qcow2 и кэш
Docker-образов. Сервисы, VM, сеть стенда и данные в `/stage` создаются заново.

## 1. Подготовить терминал и проверить сохранённые артефакты

```bash
source .venv/bin/activate
export PATH="$PWD/data/tools:$PATH"
bash deploy/scripts/verify-bundle.sh ./data
test -s deploy/infrastructure/vms/vm/debian-12-genericcloud-amd64.qcow2
test -s data/deploy/infrastructure/harbor/harbor-offline-installer-v2.15.4.tgz
```

## 2. Удалить предыдущий стенд

**Команда удаляет все пять VM, Kubernetes, PVC, Harbor с образами в registry,
метрики, MinIO и настройки Grafana. Пути и имена соответствуют стандартному config.json.**

```bash
(
  set -euo pipefail
  sudo -v
  for component in monitoring minio api-lb apt ntp; do
    docker compose -f "deploy/infrastructure/$component/compose.yaml" down
  done
  if sudo test -f /stage/harbor/installer/harbor/docker-compose.yml; then
    sudo docker compose -f /stage/harbor/installer/harbor/docker-compose.yml down
  fi
  if docker container inspect airgap-git-git-1 >/dev/null 2>&1; then
    docker rm -f airgap-git-git-1
  fi
  if docker network inspect airgap-git_default >/dev/null 2>&1; then
    docker network rm airgap-git_default
  fi

  domains=$(virsh -c qemu:///system list --all --name)
  running=$(virsh -c qemu:///system list --name)
  for vm in cp-01 cp-02 cp-03 worker-01 worker-02; do
    if grep -Fxq "$vm" <<< "$running"; then
      virsh -c qemu:///system destroy "$vm"
    fi
    if grep -Fxq "$vm" <<< "$domains"; then
      virsh -c qemu:///system undefine "$vm"
    fi
  done
  networks=$(virsh -c qemu:///system net-list --all --name)
  active_networks=$(virsh -c qemu:///system net-list --name)
  if grep -Fxq k8s-lab <<< "$active_networks"; then
    virsh -c qemu:///system net-destroy k8s-lab
  fi
  if grep -Fxq k8s-lab <<< "$networks"; then
    virsh -c qemu:///system net-undefine k8s-lab
  fi

  sudo rm -rf -- /stage/vms /stage/minio /stage/harbor /stage/grafana \
    /stage/thanos /stage/git /stage/apt /stage/apt-cache
  sudo find /stage -maxdepth 1 -type d -name 'minio-fs-backup-*' -exec rm -rf -- {} +
  rm -f deploy/ansible/inventory/hosts.yml "$HOME/.kube/airgap.conf"
)
```

При ошибке очистки следующие шаги не выполняются.

## 3. Проверить очистку

```bash
docker compose ls --all
virsh -c qemu:///system list --all
virsh -c qemu:///system net-list --all
```

## 4. Загрузить Docker-образы из bundle

```bash
while read -r image; do
  archive="$(printf '%s' "$image" | tr '/:@' '_').tar"
  docker load -i "data/repositories/registry/images/archives/$archive"
done < data/repositories/registry/images/groups/infrastructure.txt
```

## 5. Запустить MinIO

```bash
docker compose -f deploy/infrastructure/minio/compose.yaml up -d
docker compose -f deploy/infrastructure/minio/compose.yaml wait init
```

## 6. Зайти в браузер — MinIO

[http://192.168.1.57:9001](http://192.168.1.57:9001)

Войти: `minioadmin` / `Airgap2026!`. Проверить bucket `thanos`.

## 7. Запустить Grafana, PostgreSQL и Thanos

```bash
docker compose -f deploy/infrastructure/monitoring/compose.yaml up -d
docker compose -f deploy/infrastructure/monitoring/compose.yaml ps
```

## 8. Установить Harbor

```bash
sudo bash deploy/infrastructure/harbor/start.sh \
  192.168.1.57 \
  "$PWD/data/deploy/infrastructure/harbor/harbor-offline-installer-v2.15.4.tgz"
```

## 9. Зайти в браузер — Harbor

[http://192.168.1.57:8080](http://192.168.1.57:8080)

Войти: `admin` / `Airgap2026!`. Проверить проекты `docker`, `ghcr`, `quay`, `k8s`, `charts`.

## 10. Загрузить образы Kubernetes и приложений в Harbor

```bash
read -rsp 'Harbor password: ' harbor_password; echo
printf '%s' "$harbor_password" | ./data/tools/crane auth login \
  192.168.1.57:8080 --insecure --username admin --password-stdin
printf '%s' "$harbor_password" | ./data/tools/helm registry login \
  192.168.1.57:8080 --plain-http --username admin --password-stdin
unset harbor_password
bash deploy/scripts/import-images.sh --registry 192.168.1.57:8080 --insecure ./data
bash deploy/scripts/import-charts.sh --registry 192.168.1.57:8080 --plain-http ./data
```

## 11. Запустить HAProxy, APT и NTP

```bash
docker compose -f deploy/infrastructure/api-lb/compose.yaml up -d
docker compose -f deploy/infrastructure/apt/compose.yaml up -d
docker compose -f deploy/infrastructure/ntp/compose.yaml up -d
docker compose ls --all
```

## 12. Создать виртуальные машины

```bash
ansible-playbook -i localhost, deploy/ansible/playbooks/create-vms.yml --check
ansible-playbook -i localhost, deploy/ansible/playbooks/create-vms.yml \
  -e vm_become=true --ask-become-pass
cp /stage/vms/hosts.yml deploy/ansible/inventory/hosts.yml
virsh -c qemu:///system list --all
```

## 13. Проверить SSH и Ansible

Только после пересоздания VM — удалить старые SSH host keys:

```bash
for ip in 10.10.0.11 10.10.0.12 10.10.0.13 10.10.0.21 10.10.0.22; do
  ssh-keygen -R "$ip"
done
```

Дождаться готовности VM, сверить новые отпечатки через консоль и подтвердить подключения:

```bash
for ip in 10.10.0.11 10.10.0.12 10.10.0.13 10.10.0.21 10.10.0.22; do
  ssh "deploy@$ip" true
done
ansible -i deploy/ansible/inventory/hosts.yml all -m ping
```

## 14. Установить Kubernetes

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-cluster.yml
```

## 15. Установить Cilium

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/configure-cilium.yml
```

## 16. Получить kubeconfig и проверить ноды

```bash
mkdir -p "$HOME/.kube"
chmod 700 "$HOME/.kube"
ansible -i deploy/ansible/inventory/hosts.yml 'control_plane[0]' -b -m ansible.builtin.fetch \
  -a "src=/etc/kubernetes/admin.conf dest=$HOME/.kube/airgap.conf flat=true"
chmod 600 "$HOME/.kube/airgap.conf"
export KUBECONFIG="$HOME/.kube/airgap.conf"
kubectl get nodes -o wide
```

Дождаться `Ready` у всех пяти нод.

## 17. Установить хранилище

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-storage.yml
kubectl get storageclass
kubectl -n local-path-storage get pods
```

## 18. Установить MetalLB

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-loadbalancer.yml
kubectl -n metallb-system get pods,ipaddresspools,l2advertisements
```

## 19. Установить мониторинг

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-monitoring.yml
kubectl -n monitoring get pods,pvc
```

## 20. Зайти в браузер — Grafana

[http://192.168.1.57:3000/d/airgap](http://192.168.1.57:3000/d/airgap)

Войти: `admin` / `Airgap2026!`. Выбрать последние 15 минут.
Дождаться появления метрик, проверить Ready-ноды, CPU и RAM.

## 21. Установить Argo CD

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-argocd.yml
kubectl -n argocd get pods,svc
```

## 22. Получить пароль Argo CD вне записи

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'
```

## 23. Зайти в браузер — Argo CD

[http://10.10.0.240](http://10.10.0.240)

Войти с логином `admin` и паролем из предыдущего шага.
Для приватного репозитория: **Settings → Repositories → Connect Repo**;
подключить `https://github.com/bralbral/k8s-airgap.git` с учётными данными вне записи.

## 24. Зайти в браузер — проверить манифесты в GitHub

[https://github.com/bralbral/k8s-airgap/tree/main/deploy/argocd/apps/airgap-demo](https://github.com/bralbral/k8s-airgap/tree/main/deploy/argocd/apps/airgap-demo)

При отсутствии файлов выполнить commit/push изменений проекта перед следующим шагом.

## 25. Создать Application

```bash
kubectl apply -f deploy/argocd/airgap-demo.yaml
kubectl -n argocd get application airgap-demo -w
```

Дождаться `Synced / Healthy`, завершить наблюдение через `Ctrl+C`.

## 26. Зайти в браузер — дерево ресурсов Argo CD

[http://10.10.0.240/applications/argocd/airgap-demo](http://10.10.0.240/applications/argocd/airgap-demo)

Показать `Synced / Healthy`, Deployment, Service, ConfigMap и два pod’а.

## 27. Проверить приложение из терминала

```bash
kubectl -n demo rollout status deployment/airgap-demo --timeout=5m
kubectl -n demo get pods,svc
curl --noproxy '*' -fsS http://10.10.0.241/ | grep 'Версия демонстрации'
```

## 28. Зайти в браузер — приложение

[http://10.10.0.241](http://10.10.0.241)

Показать страницу с версией `v1`. Использовать HTTP, не HTTPS.

## 29. Зайти в браузер — метрики приложения

[http://192.168.1.57:3000/explore](http://192.168.1.57:3000/explore)

Выбрать datasource **Thanos**, выполнить запрос:

```promql
kube_deployment_status_replicas_available{namespace="demo",deployment="airgap-demo"}
```

Проверить значение `2`.

## 30. Изменить страницу и отправить изменения в Git

```bash
python3 - <<'PY'
from pathlib import Path
p = Path('deploy/argocd/apps/airgap-demo/configmap.yaml')
p.write_text(p.read_text().replace('Версия демонстрации: v1', 'Версия демонстрации: v2'))
PY
git add deploy/argocd/apps/airgap-demo/configmap.yaml
git commit -m "demo: update application page to v2"
git push origin main
```

## 31. Обновить Application

```bash
kubectl -n argocd annotate application airgap-demo \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get application airgap-demo -w
```

Дождаться `Synced / Healthy`, завершить наблюдение через `Ctrl+C`.

## 32. Зайти в браузер — проверить новую ревизию

[http://10.10.0.240/applications/argocd/airgap-demo](http://10.10.0.240/applications/argocd/airgap-demo)

Проверить commit и состояние синхронизации.

## 33. Зайти в браузер — проверить обновлённую страницу

[http://10.10.0.241](http://10.10.0.241)

Дождаться обновления ConfigMap-volume, обновить страницу и показать `v2`.
