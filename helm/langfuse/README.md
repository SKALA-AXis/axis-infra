# Langfuse v2 self-host (axis-team13)

LLM trace / prompt 본문 / cost 추적용 self-host observability. SKALA EKS team13 namespace 에 띄움.

> 전체 spec: [`docs/OBSERVABILITY_LANGFUSE.md`](../../docs/OBSERVABILITY_LANGFUSE.md)
> ArgoCD Application: [`k8s/argocd/langfuse-application.yaml`](../../k8s/argocd/langfuse-application.yaml)

## 구성

- **Chart**: [`langfuse/langfuse-k8s`](https://github.com/langfuse/langfuse-k8s) (Helm)
- **version**: `0.6.0` (v2 마지막 호환 — `helm search repo langfuse/langfuse` 로 정확한 버전 확인 후 ArgoCD `targetRevision` 갱신)
- **image tag**: `2.94` (Langfuse v2 안정)
- **Namespace**: `skala3-finalproj-class3-team13`
- **Pods**: 3 (web + worker + 내장 PG)
- **PVC**: 1 (5Gi gp3 — 내장 PG 만)
- **Ingress**: `langfuse.skala25a.project.skala-ai.com` (public-nginx, 매니저 등록 필요)

## 사전 작업 (1회)

1. **Helm repo 등록 (local 검증 시)**

   ```bash
   helm repo add langfuse https://langfuse.github.io/langfuse-k8s
   helm repo update
   helm search repo langfuse/langfuse --versions | head -5
   ```

2. **Secret 생성** — `k8s/base/langfuse-secret.example.yaml` 복사 후 실값 채워서 apply

   ```bash
   cp k8s/base/langfuse-secret.example.yaml k8s/base/langfuse-secret.yaml  # gitignored
   # 안의 REPLACE_* 값 채움 (NEXTAUTH_SECRET / SALT / POSTGRES_PASSWORD 32 bytes+ random hex)
   kubectl apply -f k8s/base/langfuse-secret.yaml
   ```

3. **매니저에게 ingress host 등록 신청** — `langfuse.skala25a.project.skala-ai.com` DNS + ALB target. 기존 loki / tempo / jaeger 와 동일 패턴.

## ArgoCD 배포

```bash
kubectl apply -f k8s/argocd/langfuse-application.yaml

# sync 확인
kubectl get applications.argoproj.io -n skala-argocd langfuse \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# 기대: Synced Healthy (initial provisioning ~3분)
```

## 로컬 dry-run

```bash
helm template langfuse langfuse/langfuse --version 0.10.0 \
  -f helm/langfuse/values.yaml \
  --namespace skala3-finalproj-class3-team13 \
  | less
```

## 초기 admin 가입

배포 후 `https://langfuse.skala25a.project.skala-ai.com` 접근 → 첫 사용자로 가입 → 그 후 `auth.signupDisabled=true` 가 효과 발휘하여 추가 가입 차단됨.

가입 시 자동 생성되는 Project 의 **public key** + **secret key** 발급 → axis-ai 가 `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` 로 사용 (별도 PR 에서 `axis-secrets` 에 추가).

## 자원 / quota 영향

team13 namespace 의 ResourceQuota 잔여 (확인일 2026-05-13):

| 항목 | Langfuse 사용 | quota 잔여 사용 후 |
|---|---|---|
| pods | +3 | 7+3=10 / 30 |
| PVC | +1 | 3+1=4 / 5 |
| CPU requests | +0.8 | 3+0.8=3.8 / 8 |
| memory requests | +1.75Gi | 7.4+1.75=9.15Gi / 16Gi |
| services | +2 (web + pg) | 6+2=8 / 10 |

→ 여유 한도 안에 fit ✓ (PVC 만 4/5 로 빠듯 — 다른 PVC 1개만 더 가능)

## 운영 노트

- **Backup**: Langfuse PG 의 backup 은 미구현. 30일 trace retention 정책이라 손실 영향 작음. P10+ 에서 `pgdump` cron 추가 검토
- **Upgrade**: v2 → v3 시 ClickHouse 추가 필요 → team13 PVC quota 한도 (5) 도달. 매니저에게 quota 상향 요청 또는 별도 namespace 분리 신청
- **Secret rotation**: NEXTAUTH_SECRET / SALT 변경 시 모든 session token 무효화 → 사용자 재로그인. 변경 신중

## 검증

```bash
# Pod 상태
kubectl get pods -n skala3-finalproj-class3-team13 -l app.kubernetes.io/name=langfuse

# Ingress 응답
curl -I https://langfuse.skala25a.project.skala-ai.com  # 200 또는 302 (로그인 redirect) 기대

# axis-ai 에서 trace push test (별도 PR 의 langfuse_client 사용 후)
```
