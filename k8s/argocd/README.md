# ArgoCD 리소스 — axis-team13

> AXIS 의 GitOps 진입점.
> 자세한 흐름은 [docs/ci-cd-plan.md](../../docs/ci-cd-plan.md) 참조.

## 배치 결정 — 공용 SKALA ArgoCD 사용

`skala-argocd` namespace 의 **공용 ArgoCD** (HA controller × 3, 399일째 운영). 매니저가 운영하므로 우리는 Application + repo Secret 만 등록.

- **URL**: https://argocd.skala25a.project.skala-ai.com (외부 ingress)
- **release**: `skala-argocd` helm release
- **application.namespaces 미설정** → controller 가 자기 ns (`skala-argocd`) 의 Application 만 reconcile
- **Tekton CRD cleanup 완료** (이전 좀비 19개 → 0) — ArgoCD cluster cache 정상 빌드

## 파일

| 파일 | 역할 | git 커밋 |
|---|---|---|
| `repo-secret.yaml` | ArgoCD → axis-infra private repo 인증 (GitHub fine-grained PAT) | ❌ gitignored |
| `axis-application.yaml` | ArgoCD Application CR (develop → skala-overlay sync) | ✅ |
| `README.md` | 이 파일 | ✅ |
| [../argocd-self/](../argocd-self/) | 자체 ArgoCD 시도 시 사용한 helm values — notifications 설정 참조 자료 (P8) | ✅ |

## 최초 적용

```bash
# 1) GitHub fine-grained PAT (Contents: Read-only, axis-infra repo only) 발급
#    Settings → Developer settings → Fine-grained tokens

# 2) PAT 박기 (chat / 디스크에 안 남게)
read -s ARGOCD_PAT
export ARGOCD_PAT
sed "s|REPLACE_GITHUB_PAT_READ_ONLY|$ARGOCD_PAT|" k8s/argocd/repo-secret.yaml \
  | kubectl apply -f -
unset ARGOCD_PAT

# 3) Application 등록
kubectl apply -f k8s/argocd/axis-application.yaml

# 4) 즉시 refresh
kubectl annotate application axis-team13 -n skala-argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

## 검증

```bash
kubectl get application axis-team13 -n skala-argocd \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status} REV={.status.sync.revision}{"\n"}'
# 기대: SYNC=Synced HEALTH=Healthy
```

## ArgoCD UI

```
브라우저: https://argocd.skala25a.project.skala-ai.com
username: admin
password: 매니저에 문의 (또는 argocd-initial-admin-secret 의 값)
```

port-forward 불필요 — 외부 ingress 로 직접 접속.

## 변경 시 주의

- `targetRevision` 을 `develop` → `main` 으로 옮기려면 [docs/ci-cd-plan.md §4](../../docs/ci-cd-plan.md)
- `selfHeal: false → true` 전환은 P6 rollback drill 검증 후. 현재 false (디버그 안전).
- HPA 가 axis-ai 까지 확장되면 `ignoreDifferences` 에 추가.
- `finalizers` 가 있으면 Application 삭제 시 cluster 리소스 cascade delete — 발표 직전 finalizer 제거 검토.

## 운영 부담 (매니저 영역)

다음은 *우리 영역 X* — 매니저 권한 필요:

- ArgoCD upgrade (helm chart 버전)
- ArgoCD admin password / cluster admin
- argocd-cm 의 cluster-wide 설정 (resource.exclusions, application.namespaces)
- argocd-notifications-cm 의 SMTP 설정 (P8 — `briefing.skala-ai.com` domain verify 후)
- ingress / TLS cert

## P8 — Notifications 이메일 추가 (발표 후)

[k8s/argocd-self/values.yaml](../argocd-self/values.yaml) 의 notifications 섹션이 *참조 spec* — 매니저가 공용 `argocd-notifications-cm` 에 추가할 때 그대로 활용 가능.

- SMTP: Resend / Brevo / AWS SES (도메인 verify 통과 후)
- 트리거: on-deployed / on-sync-failed / on-health-degraded
- 수신자: team13 6명 (현재) → SK AX 사업전략팀 (운영)
