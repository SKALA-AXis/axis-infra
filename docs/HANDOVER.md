# AXIS CI/CD 인계 가이드

> 대상: 본인이 졸업/퇴사/팀 변경 후 시스템 유지하려는 다음 사람
> 작성: 2026-05-11 (v2 — 공용 ArgoCD 정착 후 갱신)
> Reference: [ci-cd-plan.md](./ci-cd-plan.md)

## 시스템 개요

AXIS 의 CI/CD 는 GitOps 패턴 — `git push` → 자동 cluster 배포.

```
service repo push → GitHub Actions → Harbor → axis-infra deploy commit
  → 공용 SKALA ArgoCD (매니저 운영) → cluster sync
```

본인 Mac 은 **셋업/디버그 도구**. 모든 영구 state 는 cluster + GitHub + Harbor + ESP.

## 1. 필수 access 인계

### 1.1 GitHub `SKALA-AXis` org

- 4 repo (`axis-ai` / `axis-backend` / `axis-frontend` / `axis-infra`) 의 **Maintainer** 권한
- Actions Secrets 편집 권한 (HARBOR_USERNAME / HARBOR_PASSWORD / INFRA_DISPATCH_PAT)
- org admin 에 권한 부여 요청

### 1.2 SKALA EKS cluster

```bash
# 본인 Mac 의 kubectl context
kubectl config current-context
# arn:aws:eks:ap-northeast-2:881490135253:cluster/skala-2025

# 인계 절차 — 매니저에 요청:
# "team13 의 (새 사람) 에게 skala-2025 cluster 의 skala3-finalproj-class3-team13 ns
#  + skala-argocd ns 의 Application/Secret create 권한 부여 부탁드립니다."
```

검증:
```bash
kubectl auth can-i list pods -n skala3-finalproj-class3-team13
kubectl auth can-i create applications.argoproj.io -n skala-argocd
```

### 1.3 Harbor (`amdp-registry.skala-ai.com`)

robot account `robot$skala26a-ai3` (매니저 발급). token 만료 시 갱신 요청.

### 1.4 ESP (이메일 발송)

P8 매니저 가이드 통과 후 결정 — Brevo / AWS SES / Resend 중 하나. ESP 계정 owner 또는 팀 service account.

## 2. PAT 회전 (90일 주기) 🔴 가장 중요

GitHub fine-grained PAT 2개:

### 2.1 `INFRA_DISPATCH_PAT` (GH Actions 가 axis-infra push)

```
경로: GitHub → Settings → Developer settings → Fine-grained tokens
권한: SKALA-AXis/axis-infra, Contents: Read and Write
사용처: 3 service repo 의 Actions Secrets
```

회전:
```bash
# 1) 새 PAT 발급 (만료 1주일 전)
# 2) 3 repo 의 Actions Secrets 갱신
#    https://github.com/SKALA-AXis/{axis-ai,axis-backend,axis-frontend}/settings/secrets/actions
# 3) 옛 PAT revoke
# 4) 검증 — 아무 service repo trivial commit 후 push, GH Actions 의 build-and-push 성공 확인
```

### 2.2 ArgoCD 의 `axis-infra-repo` PAT (공용 ArgoCD 가 axis-infra pull)

```
권한: SKALA-AXis/axis-infra, Contents: Read-only
사용처: skala-argocd ns 의 secret/axis-infra-repo
```

회전:
```bash
read -s NEW_PAT
export NEW_PAT
sed "s|REPLACE_GITHUB_PAT_READ_ONLY|$NEW_PAT|" \
  k8s/argocd/repo-secret.yaml | kubectl apply -f -
unset NEW_PAT

# 검증 — ArgoCD UI Settings → Repositories → "Successful"
# 또는 application refresh:
kubectl annotate application axis-team13 -n skala-argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 2.3 만료 알림

캘린더 reminder 90일 전부터 5일 간격. PAT 발급 시 expiration 메모.

## 3. ArgoCD UI 일상 접속

```
브라우저: https://argocd.skala25a.project.skala-ai.com
username: admin
password: 매니저 가이드 또는 cluster 의 argocd-initial-admin-secret 값
```

**port-forward 불필요** — 외부 ingress 로 직접 접속.

운영 화면:
- Applications → `axis-team13` → 트리 다이어그램 (Synced/Healthy 색)
- History → 이전 sync 시점 + Rollback 버튼
- Settings → Repositories → axis-infra 인증 상태

## 4. ArgoCD 관리 부담 (매니저 영역)

다음은 *우리 영역 X*:

- ArgoCD upgrade (helm chart 버전)
- ArgoCD admin password / cluster admin
- argocd-cm 의 cluster-wide 설정 (resource.exclusions, application.namespaces)
- argocd-notifications-cm 의 SMTP 설정
- ingress / TLS cert
- cluster 의 CRD cleanup (예: Tekton 좀비 발생 시)

문의 시 매니저에 "skala-argocd ns 의 ..." 명시.

## 5. SMTP / ESP key 회전 (P8 후 활성)

도메인 verify + ESP 결정 후 회전 절차:

```bash
# 1) ESP dashboard → API Keys → 새 key 생성
read -s NEW_KEY
export NEW_KEY

# 2) axis-secrets (axis-ai email_agent 일일 브리핑)
kubectl patch secret axis-secrets -n skala3-finalproj-class3-team13 \
  -p "{\"stringData\":{\"SMTP_PASSWORD\":\"$NEW_KEY\"}}"

# 3) (매니저 영역) argocd-notifications-secret in skala-argocd ns
#    매니저에 같은 key 로 갱신 요청

unset NEW_KEY

# 4) pod restart (env reload)
kubectl rollout restart deploy/axis-ai deploy/axis-backend \
  -n skala3-finalproj-class3-team13

# 5) ESP dashboard 의 옛 key revoke
```

## 6. 일상 모니터링

### 6.1 시스템 헬스 한 줄 명령

```bash
# Application 상태
kubectl get application axis-team13 -n skala-argocd \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status} REV={.status.sync.revision}'$'\n'

# 모든 axis 서비스 pods
kubectl get pods -n skala3-finalproj-class3-team13 -l 'app.kubernetes.io/part-of=axis'

# ALB endpoint (frontend)
kubectl get ingress axis -n skala3-finalproj-class3-team13 \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'$'\n'
```

### 6.2 GH Actions 확인

```bash
gh run list --repo SKALA-AXis/axis-ai --limit 5
gh run list --repo SKALA-AXis/axis-infra --limit 5  # auto-commit 추적
```

## 7. 트러블슈팅

### 7.1 GH Actions 의 build-and-push 실패

`Bump tag in axis-infra` step 에서 fail 가장 흔함 — PAT 만료. [§2.1](#21-infra_dispatch_pat-gh-actions-가-axis-infra-push) 회전.

### 7.2 ArgoCD sync 영구 OutOfSync / Unknown

cluster cache 빌드 fail. 매니저에 진단 요청:
```bash
# condition 확인
kubectl get application axis-team13 -n skala-argocd \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

ComparisonError 에 *어떤 CRD/리소스* fail 인지 명시됨. 매니저가 cluster-wide cm 수정 또는 CRD cleanup.

### 7.3 새 service 추가 시 ResourceQuota 한도 막힘

현재 services 6/10. 4개 여유. 매니저에 quota 증액 요청 가능.

### 7.4 pod 가 새 이미지 안 받음

`imagePullPolicy: Always` 인지 확인. 또는 `kubectl rollout restart deploy/<name>` 수동.

## 8. 비상 절차

### 8.1 잘못된 코드 deploy → 즉시 rollback

```bash
cd axis-infra
git log --oneline -10                     # 최근 deploy commits
git revert <bad-commit-sha>
git push origin develop
# ArgoCD 3분 polling 또는 즉시:
kubectl annotate application axis-team13 -n skala-argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 8.2 발표/리뷰 직전 freeze

```bash
# ArgoCD 자동 sync 멈춤
kubectl patch application axis-team13 -n skala-argocd \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 풀기
kubectl patch application axis-team13 -n skala-argocd \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}'
```

### 8.3 Application 삭제 시 cluster 리소스 cascade delete 방지

finalizer 먼저 제거:
```bash
kubectl patch application axis-team13 -n skala-argocd \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl delete application axis-team13 -n skala-argocd
# cluster 의 Deployment / Service 등 그대로 유지
```

## 9. P8 진행 시 우선순위

[ci-cd-plan.md §11 P8](./ci-cd-plan.md) 의 8개 항목 중 권장 순서:

1. **Sender 도메인 verify** — 매니저에 `*.skala-ai.com` sub 도메인 발급 + ESP 의 DNS 레코드 추가. 이메일 알림 활성.
2. **공용 argocd-notifications-cm 갱신** — 매니저가 [k8s/argocd-self/values.yaml](../k8s/argocd-self/values.yaml) 의 notifications spec 을 공용 cm 에 박음.
3. **selfHeal: true 전환** — `argocd app set ... --sync-policy none` 룰 정착 후.
4. **on-deployed trigger off** — 운영 spam 방지.
5. **Sealed Secrets / ESO** — secret GitOps 화.
6. **branch protection** — develop merge 보호.
7. **production overlay** — 시나리오 B 검토.
8. **production ESP (AWS SES)** — SK AX 인수 후.

## 10. 외부 의존성 한 줄 요약

| 외부 | 영향 시 | 대안 |
|---|---|---|
| GitHub | push 안 됨 → 배포 멈춤 | mirror repo |
| Harbor | image push 안 됨 | local registry |
| SKALA cluster | 모든 게 멈춤 | 매니저 응급 |
| 공용 ArgoCD | sync 안 됨 | 자체 ArgoCD 다시 띄우기 (k8s/argocd-self/values.yaml 의 spec 참조) |
| ESP (Resend/Brevo/SES) | 이메일만 안 옴 | 다른 ESP pivot |
| AWS Route53 (skala-ai.com) | domain verify 불가 | 매니저 |

## 끝

문의: README.md / ci-cd-plan.md / k8s/argocd/README.md 참조. 매니저 access 가 막혀있으면 SKALA infra 팀에 (조 13 + 본인 인계 받은 사람 이름) 요청.
