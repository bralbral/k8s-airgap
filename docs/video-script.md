# Последовательность демонстрации

Все команды выполняются из корня репозитория на инфраструктурной машине.
Инфраструктура запущена, bundle распакован, образы импортированы в Harbor.

## 1. Подготовить терминал

```bash
source .venv/bin/activate
export PATH="$PWD/data/tools:$PATH"
```

## 2. Проверить инфраструктуру и bundle

```bash
docker compose ls --all
bash deploy/scripts/verify-bundle.sh ./data
```

## 3. Создать виртуальные машины

```bash
ansible-playbook -i localhost, deploy/ansible/playbooks/create-vms.yml --check
ansible-playbook -i localhost, deploy/ansible/playbooks/create-vms.yml
```

Для пересоздания существующих VM вместо второй команды:
**удаляются VM и их диски, включая кластер и данные PVC**.

```bash
ansible-playbook -i localhost, deploy/ansible/playbooks/create-vms.yml -e vm_recreate=true
```

```bash
cp /stage/vms/hosts.yml deploy/ansible/inventory/hosts.yml
virsh -c qemu:///system list --all
```

## 4. Проверить SSH и Ansible

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

## 5. Установить Kubernetes

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-cluster.yml
```

## 6. Установить Cilium

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/configure-cilium.yml
```

## 7. Получить kubeconfig и проверить ноды

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

## 8. Установить хранилище

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-storage.yml
kubectl get storageclass
kubectl -n local-path-storage get pods
```

## 9. Установить MetalLB

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-loadbalancer.yml
kubectl -n metallb-system get pods,ipaddresspools,l2advertisements
```

## 10. Установить мониторинг

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-monitoring.yml
kubectl -n monitoring get pods,pvc
```

## 11. Зайти в браузер — Grafana

[http://192.168.1.57:3000/d/airgap](http://192.168.1.57:3000/d/airgap)

Войти: `admin` / `Airgap2026!`. Выбрать последние 15 минут.
Дождаться появления метрик, проверить Ready-ноды, CPU и RAM.

## 12. Установить Argo CD

```bash
ansible-playbook -i deploy/ansible/inventory/hosts.yml deploy/ansible/playbooks/install-argocd.yml
kubectl -n argocd get pods,svc
```

## 13. Получить пароль Argo CD вне записи

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'
```

## 14. Зайти в браузер — Argo CD

[http://10.10.0.240](http://10.10.0.240)

Войти с логином `admin` и паролем из предыдущего шага.
Для приватного репозитория: **Settings → Repositories → Connect Repo**;
подключить `https://github.com/bralbral/k8s-airgap.git` с учётными данными вне записи.

## 15. Зайти в браузер — проверить манифесты в GitHub

[https://github.com/bralbral/k8s-airgap/tree/main/deploy/argocd/apps/airgap-demo](https://github.com/bralbral/k8s-airgap/tree/main/deploy/argocd/apps/airgap-demo)

При отсутствии файлов выполнить commit/push изменений проекта перед следующим шагом.

## 16. Создать Application

```bash
kubectl apply -f deploy/argocd/airgap-demo.yaml
kubectl -n argocd get application airgap-demo -w
```

Дождаться `Synced / Healthy`, завершить наблюдение через `Ctrl+C`.

## 17. Зайти в браузер — дерево ресурсов Argo CD

[http://10.10.0.240/applications/argocd/airgap-demo](http://10.10.0.240/applications/argocd/airgap-demo)

Показать `Synced / Healthy`, Deployment, Service, ConfigMap и два pod’а.

## 18. Проверить приложение из терминала

```bash
kubectl -n demo rollout status deployment/airgap-demo --timeout=5m
kubectl -n demo get pods,svc
curl --noproxy '*' -fsS http://10.10.0.241/ | grep 'Версия демонстрации'
```

## 19. Зайти в браузер — приложение

[http://10.10.0.241](http://10.10.0.241)

Показать страницу с версией `v1`. Использовать HTTP, не HTTPS.

## 20. Зайти в браузер — метрики приложения

[http://192.168.1.57:3000/explore](http://192.168.1.57:3000/explore)

Выбрать datasource **Thanos**, выполнить запрос:

```promql
kube_deployment_status_replicas_available{namespace="demo",deployment="airgap-demo"}
```

Проверить значение `2`.

## 21. Изменить страницу и отправить изменения в Git

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

## 22. Обновить Application

```bash
kubectl -n argocd annotate application airgap-demo \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get application airgap-demo -w
```

Дождаться `Synced / Healthy`, завершить наблюдение через `Ctrl+C`.

## 23. Зайти в браузер — проверить новую ревизию

[http://10.10.0.240/applications/argocd/airgap-demo](http://10.10.0.240/applications/argocd/airgap-demo)

Проверить commit и состояние синхронизации.

## 24. Зайти в браузер — проверить обновлённую страницу

[http://10.10.0.241](http://10.10.0.241)

Дождаться обновления ConfigMap-volume, обновить страницу и показать `v2`.
