# ArgoCD 리소스 — axis-team13

> AXIS 의 GitOps 진입점.
> 자세한 흐름은 [docs/ci-cd-plan.md](../../docs/ci-cd-plan.md) 참조.

## 배치 결정 — 자체 ArgoCD (우리 ns)

공용 `skala-argocd` 는 cluster 의 좀비 Tekton CRD (`tasks.tekton.dev` 등 19개) 의
conversion webhook 호출에서 영구 fail → 모든 Application sync 불가.
→ 우리 ns 에 자체 ArgoCD 설치 (helm release `axis-argocd`, [k8s/argocd-self/values.yaml](../argocd-self/values.yaml)).

격리:

- ClusterRole 충돌 회피 — release name `axis-argocd` 접두사로 `argocd-*` 와 분리
- ClusterRoleBinding 이 우리 ns ServiceAccount 에만 binding → 다른 팀 영향 X
- 우리 argocd-cm 의 `resource.exclusions` 에 Tekton 명시적 제외 → cluster cache 빌드 시 좀비 CRD 안 만짐
- `application.namespaces=skala3-finalproj-class3-team13` → 우리 ns 의 Application 만 reconcile

## 파일

| 파일 | 역할 | git 커밋 |
|---|---|---|
| `repo-secret.yaml` | ArgoCD → axis-infra private repo 인증 (GitHub fine-grained PAT) | ❌ gitignored |
| `axis-application.yaml` | ArgoCD Application CR (develop → skala-overlay sync) | ✅ |
| `README.md` | 이 파일 | ✅ |
| [../argocd-self/values.yaml](../argocd-self/values.yaml) | helm chart values (namespace-scoped minimal install) | ✅ |

## 최초 적용 (P4)

### 1) 자체 ArgoCD 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm install axis-argocd argo/argo-cd \
  -n skala3-finalproj-class3-team13 \
  -f k8s/argocd-self/values.yaml \
  --version 9.5.13 \
  --timeout 5m
# pods 5개 (controller / applicationset-controller / redis / repo-server / server) ready 까지 ~2분
```

### 2) repo Secret + Application 등록

```bash
# PAT 생성 — Settings → Developer settings → Fine-grained tokens
# repo: SKALA-AXis/axis-infra, contents: Read-only, expiration: 90d

# PAT 변수 (chat / 디스크에 안 남게)
read -s ARGOCD_PAT
export ARGOCD_PAT
sed "s|REPLACE_GITHUB_PAT_READ_ONLY|$ARGOCD_PAT|" k8s/argocd/repo-secret.yaml \
  | kubectl apply -f -
unset ARGOCD_PAT

kubectl apply -f k8s/argocd/axis-application.yaml
```

### 3) 검증

```bash
kubectl get applications.argoproj.io -n skala3-finalproj-class3-team13 axis-team13 \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status}{"\n"}'
# 기대: SYNC=Synced HEALTH=Healthy
```

## ArgoCD UI

```bash
# port-forward (server.service.type: ClusterIP)
kubectl port-forward -n skala3-finalproj-class3-team13 svc/axis-argocd-server 8080:443
# 브라우저: https://localhost:8080 (cert warning 무시)

# admin 비밀번호
kubectl -n skala3-finalproj-class3-team13 get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## 변경 시 주의

- `targetRevision` 을 main 으로 옮기려면 [docs/ci-cd-plan.md §4](../../docs/ci-cd-plan.md) 의 시나리오 A.
- `selfHeal` 을 true 로 전환은 P6 rollback drill 통과 후.
- HPA 가 axis-ai 까지 확장되면 ignoreDifferences 에 추가.
- `finalizers` 가 있으면 Application 삭제 시 cluster 리소스 cascade delete — 발표 직전 제거 검토.

## P7 — 이메일 알림 (활성화됨)

ArgoCD notifications controller 가 활성화되어 axis-team13 의 sync/health 이벤트에 대해 6 명에게 이메일 발송.

| 트리거 | 조건 | 발송 |
|---|---|---|
| `on-deployed` | sync.phase=Succeeded AND health=Healthy (per revision) | 1회/리비전 |
| `on-sync-failed` | sync.phase in [Error, Failed] | 1회/sync attempt |
| `on-health-degraded` | health=Degraded | 1회/condition |

수신자 6명 (team13 전원), SMTP=SendGrid (axis-secrets 의 SMTP_PASSWORD 재사용 — 발표 단계 A 옵션. 프로덕션 단계 B 는 [P8](#p8-운영-강화-발표-후) 참조).

SMTP secret 박는 법 (별도 — git tracking X):

```bash
SMTP_PWD=$(kubectl get secret axis-secrets -n skala3-finalproj-class3-team13 \
  -o jsonpath='{.data.SMTP_PASSWORD}' | base64 -d)
kubectl create secret generic argocd-notifications-secret \
  -n skala3-finalproj-class3-team13 \
  --from-literal=email-password="$SMTP_PWD" \
  --dry-run=client -o yaml | kubectl apply -f -
unset SMTP_PWD
```

## P8 — 운영 강화 (발표 후)

- **ApplicationSet pod/svc 정리** — chart v9.5 부터 disable 불가. 직접 `kubectl delete svc/deploy axis-argocd-applicationset-controller` 후 helm uninstall 시 ignore.
- **services quota 증액** — 매니저에 `services: 10 → 15` 요청.
- **SMTP 분리 (옵션 B)** — SendGrid 에 `axis-cicd@...` verified sender 등록 → 별도 키 발급 → argocd-notifications-secret 만 새 키로 교체.
- **Sealed Secrets / ESO** — secret.skala.yaml / argocd-notifications-secret / repo-secret.yaml 을 GitOps 화.
- **selfHeal: true 전환** — P6 drill 통과했으므로 가능. axis-application.yaml 의 `selfHeal: false` → `true`.
- **on-deployed trigger 끄기** — 운영 시 매 deploy 마다 이메일 = spam. on-sync-failed + on-health-degraded 만 유지.

## helm upgrade 시 주의

helm upgrade 시 `--set configs.secret.argocdServerAdminPassword=...` 옵션 **사용 금지**:

- chart 가 admin.password + admin.passwordMtime 을 SSA 로 박으려 함 → 우리가 reset 한 비번의 fieldManager (`kubectl-patch`) 와 SSA conflict
- `--set` 없이 upgrade 하면 chart 가 `argocd-secret` 의 `data` 자체 안 박음 → cluster 의 우리 reset 비번 그대로 보존

```bash
# 안전한 helm upgrade
helm upgrade axis-argocd argo/argo-cd \
  -n skala3-finalproj-class3-team13 \
  -f k8s/argocd-self/values.yaml \
  --version 9.5.13
```

비번 분실 시 reset 절차:

```bash
read -s NEW_PWD
HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$NEW_PWD', bcrypt.gensalt(rounds=10)).decode())")
unset NEW_PWD
kubectl -n skala3-finalproj-class3-team13 patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"}}"
kubectl rollout restart deploy/axis-argocd-server -n skala3-finalproj-class3-team13
```

## ResourceQuota 메모

services 한도 10 정확히 도달 (axis 서비스 6 + ArgoCD 4). 우리 매니페스트가 새 svc 추가하면 막힘. 발표 후 P8 에서:

- ApplicationSet controller pod/svc 제거 (chart v9.5 부터 disable 불가 → 직접 delete 후 helm 무시)
- 또는 매니저에 services quota 증액 1줄 요청
