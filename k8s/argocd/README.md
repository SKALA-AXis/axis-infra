# ArgoCD 리소스 — axis-team13

> AXIS 의 GitOps 진입점.
> 자세한 흐름은 [docs/ci-cd-plan.md](../../docs/ci-cd-plan.md) 참조.

## 파일

| 파일 | 역할 | git 커밋 |
|---|---|---|
| `repo-secret.yaml` | ArgoCD → axis-infra private repo 인증 (GitHub fine-grained PAT) | ❌ gitignored |
| `axis-application.yaml` | ArgoCD Application CR (develop → skala-overlay sync) | ✅ |
| `README.md` | 이 파일 | ✅ |

## 최초 적용 (P4)

```bash
# 1) PAT 생성 — Settings → Developer settings → Fine-grained tokens
#    repo: SKALA-AXis/axis-infra, contents: Read-only, expiration: 90d
# 2) repo-secret.yaml 의 password 자리 채움
# 3) 두 리소스 순서 apply
kubectl apply -f k8s/argocd/repo-secret.yaml
kubectl apply -f k8s/argocd/axis-application.yaml

# 4) 검증
kubectl get applications.argoproj.io -n skala-argocd axis-team13 \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# 기대: Synced Healthy
```

## ArgoCD UI

```bash
# 외부 노출 확인
kubectl get svc -n skala-argocd | grep -i server

# 미노출 시
kubectl port-forward -n skala-argocd svc/skala-argocd-server 8080:80
# 또는 svc/argocd-server (cluster 마다 다름)

# admin 비밀번호
kubectl -n skala-argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## 변경 시 주의

- `targetRevision` 을 main 으로 옮기려면 [docs/ci-cd-plan.md §4](../../docs/ci-cd-plan.md) 의 시나리오 A 참조 (sed 4 라인).
- `selfHeal` 을 true 로 전환은 P6 rollback drill 통과 후.
- HPA 가 axis-ai 까지 확장되면 ignoreDifferences 에 추가.
- `finalizers` 가 있으면 Application 삭제 시 cluster 리소스 cascade delete — 발표 직전 제거 검토.
