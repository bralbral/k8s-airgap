# Демонстрационное приложение Argo CD

Приложение представляет статическую веб-страницу на BusyBox HTTP. Образ
`docker.io/library/busybox:1.37.0` уже включён в bundle и импортируется в Harbor.
Дополнительная сборка образа не требуется.

Манифесты находятся в этом же репозитории:

| Файл | Назначение |
| --- | --- |
| `deploy/argocd/apps/airgap-demo/deployment.yaml` | Две реплики HTTP-сервера, probes и limits |
| `deploy/argocd/apps/airgap-demo/configmap.yaml` | HTML-страница с обозначением версии |
| `deploy/argocd/apps/airgap-demo/service.yaml` | LoadBalancer `10.10.0.241:80`, без NodePort |
| `deploy/argocd/airgap-demo.yaml` | AppProject и Application для namespace `demo` |

## Источник Git

В модели закрытого контура предполагается доступный внутренний Git-репозиторий,
в том числе приватный. Для упрощения демонстрации его роль выполняет
`https://github.com/bralbral/k8s-airgap.git`, ветка `main`.
Argo CD получает только манифесты из `deploy/argocd/apps/airgap-demo`; Ansible, Compose
и остальные файлы checkout не разворачиваются этим Application.

Это допущение требует сетевого доступа Argo CD к GitHub. Оно не означает
проверку полной изоляции сети. Для реального контура адрес заменяется в
`AppProject.spec.sourceRepos` и `Application.spec.source.repoURL` на внутренний Git.

Для приватного репозитория подключение предварительно регистрируется в
**Argo CD → Settings → Repositories → Connect Repo**. Используется URL выше и
учётная запись/токен с правами чтения содержимого репозитория. Учётные данные
хранятся в Argo CD и не добавляются в Git, манифесты или видеозапись.
Настройка подключения не изменяет видимость самого GitHub-репозитория.

## Первое развёртывание

Все команды выполняются из корня проекта после установки Argo CD и MetalLB.
Новые файлы приложения должны быть опубликованы в ветке `main` до создания
Application. Локальные незакоммиченные файлы Argo CD не видит.

```bash
export KUBECONFIG="$HOME/.kube/airgap.conf"
export PATH="$PWD/data/tools:$PATH"
kubectl apply -f deploy/argocd/airgap-demo.yaml
kubectl -n argocd get applications airgap-demo -w
```

Ожидаемые состояния — `Synced` и `Healthy`. Наблюдение завершается `Ctrl+C`.
После синхронизации:

```bash
kubectl -n demo rollout status deployment/airgap-demo --timeout=5m
kubectl -n demo get pods,svc
curl --noproxy '*' -fsS http://10.10.0.241/ | grep 'Версия демонстрации'
```

Интерфейс приложения: **http://10.10.0.241** с Ubuntu-хоста стенда.
В Argo CD видны Deployment, ReplicaSet, два pod’а, Service и ConfigMap.
Манифесты приложения отдельно через `kubectl apply` не устанавливаются:
их применяет Argo CD. Через kubectl регистрируются только AppProject и Application.

Проверка метрик в Grafana → Explore, datasource **Thanos**:

```promql
kube_deployment_status_replicas_available{namespace="demo",deployment="airgap-demo"}
```

Ожидаемое значение — `2`. Метрика появляется после очередного scrape и remote_write.

## Демонстрация изменения через Git

Изменение версии страницы:

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

Для немедленного обновления данных Argo CD вместо ожидания периодического опроса:

```bash
kubectl -n argocd annotate application airgap-demo \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get application airgap-demo -w
```

Автоматическая синхронизация применяет ConfigMap. Обновление файла в смонтированном
томе ConfigMap происходит с задержкой; перезапуск pod’ов для статической страницы
не требуется. После обновления тома и страницы браузера отображается `v2`.
Проверка команды ниже выполняется до появления новой версии:

```bash
curl --noproxy '*' -fsS http://10.10.0.241/ | grep 'Версия демонстрации: v2'
```

Возврат к v1 выполняется обратным изменением ConfigMap и новым commit/push.
Секреты и пароли в кадре демонстрации не отображаются.
