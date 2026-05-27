# k8s_helm_flux — n8n on GitOps (Flux CD + Helm + CloudNativePG)

GitOps репозиторій, у якому будь-який коміт у `main` автоматично відображається
у Kubernetes-кластері без `kubectl apply`. Flux CD синхронізує два середовища
(`staging`, `production`) з різною конфігурацією одного й того самого застосунку.
Уся доставка застосунку — через **Helm + HelmRelease**, без жодного
`kustomization.yaml`. Дві тонкі Flux `Kustomization` (по одній на середовище)
тільки вказують Flux, які теки слухати — щоб `flux get kustomizations -A`
показав окремі оверлеї `apps-staging` / `apps-production`.

## Стек

| Шар              | Технологія                                                       | Пін версії          |
|------------------|------------------------------------------------------------------|---------------------|
| Застосунок       | **n8n** (workflow automation, офіційний образ)                   | n8n 1.122.4         |
| Прод. scale-out  | **Queue mode** з Valkey (Redis-compatible, subchart 8gears/n8n)  | (вбудовано)         |
| База даних       | **PostgreSQL** через **CloudNativePG Operator**                  | chart 0.28.x        |
| App chart        | upstream `oci://8gears.container-registry.com/library/n8n`       | chart 2.0.x         |
| Env-glue chart   | локальний `charts/n8n-env` (NS + Secret + CNPG Cluster)          | 0.1.0               |
| GitOps           | Flux CD v2 — `HelmRelease` + дві тонкі `Kustomization` (без `kustomization.yaml`) | v2 / v1 |
| Ingress          | ingress-nginx                                                    | chart 4.15.x        |
| TLS              | cert-manager + self-signed ClusterIssuer (опц.)                  | chart v1.20.x       |
| CI               | GitHub Actions → GHCR (опц.)                                     |                     |
| Image Automation | Flux Image Reflector + Image Update Automation (опц.)            |                     |

## Структура репозиторію

```
.
├── charts/
│   └── n8n-env/                            # Локальний чарт env-glue (NS + Secret + CNPG Cluster)
│       ├── Chart.yaml
│       ├── values.yaml                     # дефолти ≈ staging
│       └── templates/
│           ├── _helpers.tpl
│           ├── namespace.yaml
│           ├── secret.yaml                 # N8N_ENCRYPTION_KEY (демо!)
│           └── postgres-cluster.yaml       # kind: Cluster (CNPG)
│
├── clusters/my-cluster/                    # bootstrap path; flux-system Kustomization сканує цю теку
│   ├── flux-system/                        # створює `flux bootstrap` (немає у Git до bootstrap)
│   ├── sources.yaml                        # усі HelmRepository в одному файлі
│   ├── apps-staging.yaml                   # Flux Kustomization -> ./apps/staging
│   ├── apps-production.yaml                # Flux Kustomization -> ./apps/production
│   └── infrastructure/                     # оператори/контролери — кожен як HelmRelease
│       ├── cloudnative-pg.yaml
│       ├── cert-manager.yaml
│       ├── ingress-nginx.yaml
│       ├── cluster-issuer.yaml             # ClusterIssuer (selfsigned) — Flux ретраїть до готовності CRD
│       └── image-automation.yaml           # ImageRepository + ImagePolicy + ImageUpdateAutomation
│
├── apps/                                   # ПОЗА clusters/my-cluster/ — щоб bootstrap-Kustomization
│   │                                       # їх не сканував. Кожну теку підхоплює окрема thin Kustomization.
│   ├── staging/                            # синхронізується через apps-staging
│   │   ├── env.yaml                        # HelmRelease -> charts/n8n-env (staging values)
│   │   └── n8n.yaml                        # HelmRelease -> upstream 8gears/n8n (staging values)
│   └── production/                         # синхронізується через apps-production
│       ├── env.yaml                        # HelmRelease -> charts/n8n-env (production values, HA Postgres)
│       └── n8n.yaml                        # HelmRelease -> upstream 8gears/n8n (HPA 2..5, TLS, GHCR image)
│
├── .github/workflows/build.yml             # CI: build & push Docker image у GHCR
├── Dockerfile                              # тонка обгортка над n8nio/n8n
├── plan.MD                                 # ТЗ
└── README.md                               # цей файл
```

> У теках `./apps/staging` і `./apps/production` НЕМАЄ `kustomization.yaml` —
> Flux сам генерує його на льоту, скануючи всі `.yaml` у вказаному path.
> Порядок між HelmRelease встановлюється через `spec.dependsOn`.

## Залежності між HelmRelease

```
sources.yaml (HelmRepository) -> доступні всім

cloudnative-pg ──┐
cert-manager   ──┼─► (інфраструктура)
ingress-nginx  ──┘

n8n-env-staging     depends on: cloudnative-pg
n8n-env-production  depends on: cloudnative-pg

n8n-staging         depends on: n8n-env-staging, ingress-nginx
n8n-production      depends on: n8n-env-production, cert-manager, ingress-nginx
```

`ClusterIssuer` — звичайний маніфест без HelmRelease, тож Flux буде його
ретраїти, поки CRD з cert-manager не з'явиться (зазвичай < 1 хв). На прод-кластерах
переносити цей ресурс в окрему Flux Kustomization з health-check на cert-manager
HelmRelease — щоб уникнути транзитного фейлу root-Kustomization.

## Queue mode у production (чому HPA 2..5 не ламає n8n)

n8n у дефолтному (regular) режимі — single-process: у кожному поді живуть свій
scheduler і свій executor. Дві репліки спричиняють дубльовані cron-тригери і
розрив webhook-сесій на load-balancer. План вимагає HPA 2..5 — отже,
production-HelmRelease вмикає **queue mode**:

| Компонент         | Роль                                                      | Replicas              |
|-------------------|-----------------------------------------------------------|-----------------------|
| `main` Deployment | Editor UI + REST API + dispatcher (НЕ виконує workflow)   | HPA 2..5 (CPU 70%)    |
| `worker` Deployment | Виконує workflow з черги Bull/Valkey                    | 2 (фіксовано)         |
| `valkey` StatefulSet | Redis-compatible черга (subchart 8gears 2.0+)          | 1 (standalone)        |
| `webhook`         | (вимкнено — `main` обробляє webhook-и при низькому трафіку) | —                  |

Sticky-session на UI ставимо через анотацію `nginx.ingress.kubernetes.io/affinity: cookie`,
тож editor не "стрибає" між `main`-репліками.

**Валідність плану**: Valkey-як-черга — auxiliary інфраструктура, **не**
primary data store застосунку. CNPG залишається БД n8n. Заборона "plain
StatefulSet/Deployment для баз даних" не порушується.

## Як середовища відрізняються

| Параметр                        | staging                | production                       |
|---------------------------------|------------------------|----------------------------------|
| Namespace                       | `staging`              | `production`                     |
| Режим n8n                       | regular (single proc.) | **queue** (main + worker + Valkey) |
| Реплік main                     | 1 (фіксовано)          | HPA 2..5 (CPU 70%)               |
| Реплік worker                   | —                      | 2                                |
| Resources requests/limits       | мінімальні             | задані явно                      |
| Postgres (CNPG) instances       | 1 (dev preset)         | 3 (HA, 1 sync standby)           |
| Postgres storage                | 1Gi                    | 10Gi                             |
| Ingress host                    | `n8n.staging.local`    | `n8n.local`                      |
| TLS                             | вимкнено               | self-signed (cert-manager)       |
| Image                           | `n8nio/n8n:1.122.4`    | `ghcr.io/mykolap/k8s_helm_flux/n8n:1.x.x` (Image Automation) |

## Як запустити (для майбутнього живого кластера)

```bash
export GITHUB_TOKEN=<PAT_repo_scope>
flux bootstrap github \
  --owner=mykolap \
  --repository=k8s_helm_flux \
  --branch=main \
  --path=./clusters/my-cluster \
  --components-extra=image-reflector-controller,image-automation-controller \
  --personal
```

`--components-extra=...` потрібен, бо Image Automation не входить у дефолтні
компоненти Flux. Bootstrap створить `clusters/my-cluster/flux-system/` із
системними маніфестами і `GitRepository` `flux-system` — саме на нього
посилаються `chart.spec.sourceRef` локальних `HelmRelease`.

Локальна валідація чарта (без кластера):

```bash
helm lint charts/n8n-env
helm template n8n-env-staging charts/n8n-env                              # дефолти (≈ staging)
helm template n8n-env-prod charts/n8n-env \
  --set namespace=production --set postgres.instances=3 \
  --set postgres.minSyncReplicas=1 --set postgres.maxSyncReplicas=1
```

## Definition of Done (з плану)

```bash
flux get helmreleases -A
# Очікувано (Ready):
#   flux-system / cloudnative-pg
#   flux-system / cert-manager
#   flux-system / ingress-nginx
#   flux-system / n8n-env-staging
#   flux-system / n8n-env-production
#   flux-system / n8n-staging
#   flux-system / n8n-production

flux get kustomizations -A         # flux-system, apps-staging, apps-production -> Ready
flux get sources helm -A           # cloudnative-pg, jetstack, ingress-nginx, n8n
kubectl get ns staging production
kubectl get pods -A                # n8n-main, n8n-worker, n8n-valkey, cnpg-*, ingress, cert-manager
kubectl get ingress -A             # n8n.staging.local та n8n.local
kubectl get hpa -n production      # n8n-main: 2..5 з реальними метриками
kubectl get cluster -n production  # n8n-postgres (CNPG): 3 instances, primary+2 standby
```

### Self-Healing

```bash
kubectl delete deploy n8n -n production
# < 1 хв Flux відновлює деплоймент (HelmRelease interval: 1m, driftDetection: enabled)
```

### Підключення n8n до БД

CNPG автоматично створює `Secret <cluster>-app` (тут `n8n-postgres-app`) з
полями `host/port/user/password/dbname/uri/jdbc-uri`. 8gears n8n chart 2.0.x не
має fields типу `database.existingSecret` — ми мапимо secret-ключ у env-змінну
явно через `main.extraEnv` (і дублюємо в `worker.extraEnv`):

```yaml
main:
  config:
    db:
      type: postgresdb
      postgresdb: { host: n8n-postgres-rw, port: 5432, database: n8n, user: n8n }
  extraEnv:
    DB_POSTGRESDB_PASSWORD:
      valueFrom:
        secretKeyRef: { name: n8n-postgres-app, key: password }
    N8N_ENCRYPTION_KEY:
      valueFrom:
        secretKeyRef: { name: n8n-app, key: N8N_ENCRYPTION_KEY }
```

## CRD керовані Helm: trade-off

`cloudnative-pg` і `cert-manager` HelmReleases ставлять CRD через сам чарт
(`crds: Create` / `CreateReplace`). Це зручно для bootstrap, але:

- При **видаленні HelmRelease** Helm видаляє і CRD → орфанить усі CR (втрата кластера БД).
- При **upgrade** `CreateReplace` перезаписує CRD; якщо нова версія несумісна з існуючими CR — фейл валідації.

Для прод-кластерів рекомендований паттерн — окрема Flux Kustomization з CRD-YAML
+ HelmRelease з `--skip-crds`. Для навчального стенда залишаємо Helm-managed.

## SOPS: як це виглядатиме після виходу з демо

Demo-Secrets (`N8N_ENCRYPTION_KEY`) у Git — наразі в plaintext. Production-ready
варіант через SOPS + age:

```bash
# 1. Згенерувати age-ключ і додати у kube-secret:
age-keygen -o age.agekey
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey

# 2. У .sops.yaml — правило для apps/**/*.yaml.

# 3. Зашифрувати lib/n8n-env/secret.yaml:
sops --encrypt --in-place apps/production/secret.yaml

# 4. Flux Kustomization розшифровує на льоту:
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

(У цьому репо `secret.yaml` рендериться чартом `n8n-env` — для SOPS винесли б
його як окремий Encrypted Secret поза чарту, або зашифровували `spec.values`
через ExternalSecrets Operator.)

## Опційні етапи

- **CI**: `.github/workflows/build.yml` будує образ із `Dockerfile` і пушить у
  `ghcr.io/mykolap/k8s_helm_flux/n8n:<semver>` на тег `v*.*.*`.
- **Image Automation**: `clusters/my-cluster/infrastructure/image-automation.yaml`
  сканує GHCR і автоматично перезаписує тег у `apps/production/n8n.yaml`
  (єдиний marker `# {"$imagepolicy": "flux-system:n8n:tag"}` на полі `tag`).
  Маркер на `repository` свідомо НЕ ставимо — інакше Automation переписувала б
  і шлях до образу.
- **TLS**: `clusters/my-cluster/infrastructure/cluster-issuer.yaml` створює
  `selfsigned` `ClusterIssuer`; `production` Ingress отримує `tls:` блок і
  cert-manager автоматично виписує сертифікат у `Secret n8n-tls`.

## Застереження для навчального стенда

- `N8N_ENCRYPTION_KEY` лежить у `Secret` у Git **тільки для демо**. Real-life
  патерн — див. секцію "SOPS" вище.
- `Cluster` (CNPG) у `production` встановлено на 3 інстанси з default
  pod-anti-affinity. На single-node стенді (Rancher Desktop / Minikube) поди
  залишаться `Pending`. Два рішення:
  ```yaml
  # apps/production/env.yaml — або зменшити масштаб:
  postgres:
    instances: 1
  # або послабити anti-affinity (чарт n8n-env пропускає affinity у Cluster.spec):
  postgres:
    affinity:
      enablePodAntiAffinity: false
  ```
- `Valkey` у `production` стартує як **standalone** (1 нода, без auth). Для
  справжнього прод-кластера: `valkey.architecture: replication` + `valkey.auth.enabled: true`
  + Secret з паролем, плюс ENV `QUEUE_BULL_REDIS_PASSWORD` у main/worker.
- `primaryUpdateStrategy` у CNPG Cluster — `unsupervised` (автоматичний failover).
  Для критичних навантажень — `supervised` (failover вимагає ручного підтвердження).
- **PDB** для n8n не задаємо — 8gears 2.0.x не експонує `pdb.*` values. Якщо
  потрібно — додати окремий маніфест `PodDisruptionBudget` у `apps/production/`.
