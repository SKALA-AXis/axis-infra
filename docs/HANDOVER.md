# AXIS CI/CD 인계 가이드

> 대상: 본인 (메니스커스 / 김가은) 가 졸업/퇴사/팀 변경 후 시스템 유지하려는 다음 사람
> 작성: 2026-05-11
> Reference: [ci-cd-plan.md](./ci-cd-plan.md)

## 시스템 개요

AXIS 의 CI/CD 는 GitOps 패턴 — `git push` → 자동 cluster 배포.

```
service repo push → GitHub Actions → Harbor → axis-infra deploy commit
  → 자체 ArgoCD (cluster 내 axis-argocd helm release) → cluster sync
```

본인 Mac 은 **셋업/디버그 도구**. 모든 영구 state 는 cluster + GitHub + Harbor + Resend.

## 1. 필수 access 인계

### 1.1 GitHub `SKALA-AXis` org

- 4 repo (`axis-ai` / `axis-backend` / `axis-frontend` / `axis-infra`) 의 **Maintainer** 권한 이상
- Actions Secrets 편집 권한 (HARBOR_USERNAME / HARBOR_PASSWORD / INFRA_DISPATCH_PAT)
- org admin 에 권한 부여 요청

### 1.2 SKALA EKS cluster

```bash
# 본인 Mac 의 kubectl context
kubectl config current-context
# arn:aws:eks:ap-northeast-2:881490135253:cluster/skala-2025

# 인계 절차 — 본인 IAM 만으로 access 안 되면 매니저에 요청:
# "team13 의 (새 사람 이름) 에게 skala-2025 cluster 의 skala3-finalproj-class3-team13 namespace
#  접근 권한 부여 부탁드립니다. IAM role 또는 kubeconfig 발급."
```

검증:
```bash
kubectl auth can-i list pods -n skala3-finalproj-class3-team13
kubectl auth can-i delete crd                           # 응급 시 cluster cleanup
```

### 1.3 Harbor (`amdp-registry.skala-ai.com`)

- robot account `robot$skala26a-ai3` (또는 매니저가 발급한 다른 이름)
- 매니저 발급. token 만료 시 갱신 요청.

### 1.4 Resend (이메일)

- 본인 가입 이메일 (예: meniscus220@gmail.com) 의 계정 owner
- API key 만료 / 회전 시 새 key 발급 후 cluster secret 갱신 ([§5](#5-smtp-resend-key-회전) 참조)
- 팀 service account 로 전환 시 API key + 본인 계정 transfer 필요

## 2. PAT 회전 (90일 주기) 🔴 가장 중요

GitHub fine-grained PAT 2개:

### 2.1 `INFRA_DISPATCH_PAT` (GH Actions 가 axis-infra push)

```
경로: GitHub → Settings → Developer settings → Fine-grained tokens
권한: SKALA-AXis/axis-infra, Contents: Read and Write
사용처: 3 service repo 의 Actions Secrets
```

회전 절차:
```bash
# 1) GitHub UI 에서 새 PAT 발급 (만료 전 1주일 권장)
# 2) 3 repo 의 Actions Secrets 갱신:
#    https://github.com/SKALA-AXis/{axis-ai,axis-backend,axis-frontend}/settings/secrets/actions
# 3) 옛 PAT revoke
# 4) 검증 — 아무 service repo 에 trivial commit 후 push
#    GH Actions 의 build-and-push.yml 의 "Bump tag in axis-infra" step 성공 확인
```

### 2.2 ArgoCD 의 `axis-infra-repo` PAT (ArgoCD 가 axis-infra pull)

```
경로: 같은 GitHub Settings
권한: SKALA-AXis/axis-infra, Contents: Read-only
사용처: cluster 의 secret/axis-infra-repo
```

회전 절차:
```bash
read -s NEW_PAT
export NEW_PAT
sed "s|REPLACE_GITHUB_PAT_READ_ONLY|$NEW_PAT|" \
  k8s/argocd/repo-secret.yaml | kubectl apply -f -
unset NEW_PAT

# 검증 — ArgoCD UI 의 Settings → Repositories 에서 "Successful" 확인
# 또는 application refresh:
kubectl annotate application axis-team13 -n skala3-finalproj-class3-team13 \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 2.3 만료 알림

캘린더 reminder (Google Calendar / iCal) 에 90일 전부터 5일 간격 reminder 등록. PAT 발급 시 expiration 메모.

## 3. ArgoCD admin password 인계

### 3.1 현재 상태

본인이 `kubectl patch` 로 reset 한 bcrypt hash 가 cluster 의 `argocd-secret` 에 있음. plaintext 는 본인만 안다.

→ **1Password / Bitwarden 같은 팀 vault 에 plaintext 저장 권장**. 또는 다음 사람에게 reset 절차 안내.

### 3.2 인계자 reset 절차

```bash
read -s NEW_PWD     # 새 비번 입력
HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$NEW_PWD', bcrypt.gensalt(rounds=10)).decode())")
unset NEW_PWD
kubectl -n skala3-finalproj-class3-team13 patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"}}"
kubectl rollout restart deploy/axis-argocd-server -n skala3-finalproj-class3-team13
# ~30초 후 새 비번으로 https://localhost:8080 로그인
```

### 3.3 helm upgrade 시 주의 ⚠️

`--set configs.secret.argocdServerAdminPassword=...` **사용 금지** — kubectl-patch fieldManager 와 helm SSA fieldManager 충돌. `--set` 없이 upgrade 하면 chart 가 argocd-secret 의 data 안 박음 → 우리 reset pw 보존.

```bash
helm upgrade axis-argocd argo/argo-cd \
  -n skala3-finalproj-class3-team13 \
  -f k8s/argocd-self/values.yaml \
  --version 9.5.13
```

## 4. ArgoCD UI 일상 접속

```bash
# 별도 터미널에서 port-forward 켜둠
kubectl port-forward -n skala3-finalproj-class3-team13 svc/axis-argocd-server 8080:443
# 브라우저: https://localhost:8080
# username: admin / password: vault 에 저장된 값 또는 [§3.2](#32-인계자-reset-절차) 로 reset
```

운영 화면:
- Applications → `axis-team13` → 트리 다이어그램 (Synced/Healthy 색)
- History → 이전 sync 시점 + Rollback 버튼
- Settings → Repositories → axis-infra 인증 상태

## 5. SMTP (Resend) key 회전

```bash
# 1) Resend dashboard (https://resend.com) → API Keys → 새 key 생성
read -s NEW_KEY
export NEW_KEY

# 2) axis-secrets (axis-ai email_agent 용)
kubectl patch secret axis-secrets -n skala3-finalproj-class3-team13 \
  -p "{\"stringData\":{\"SMTP_PASSWORD\":\"$NEW_KEY\"}}"

# 3) argocd-notifications-secret (ArgoCD 알림 용)
kubectl create secret generic argocd-notifications-secret \
  -n skala3-finalproj-class3-team13 \
  --from-literal=email-password="$NEW_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

unset NEW_KEY

# 4) pod restart (env reload)
kubectl rollout restart deploy/axis-ai deploy/axis-backend \
  deploy/axis-argocd-notifications-controller \
  -n skala3-finalproj-class3-team13

# 5) Resend dashboard 의 옛 key revoke
```

## 6. 일상 모니터링

### 6.1 시스템 헬스 한 줄 명령

```bash
# Application 상태
kubectl get application axis-team13 -n skala3-finalproj-class3-team13 \
  -o jsonpath='SYNC={.status.sync.status} HEALTH={.status.health.status} REV={.status.sync.revision}{"\n"}'

# 모든 axis 서비스 pods
kubectl get pods -n skala3-finalproj-class3-team13 -l 'app.kubernetes.io/part-of=axis'

# ALB endpoint
kubectl get ingress axis -n skala3-finalproj-class3-team13 \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

### 6.2 GH Actions 확인

```bash
gh run list --repo SKALA-AXis/axis-ai --limit 5
gh run list --repo SKALA-AXis/axis-infra --limit 5  # auto-commit 추적
```

## 7. 트러블슈팅

### 7.1 GH Actions 의 build-and-push 실패

`Bump tag in axis-infra` step 에서 fail 가장 흔함 — PAT 만료. [§2.1](#21-infra_dispatch_pat-gh-actions-가-axis-infra-push) 의 PAT 회전.

### 7.2 ArgoCD sync 영구 OutOfSync

cluster cache 빌드 fail. 가장 흔한 원인 = Tekton 좀비 CRD (cluster 의 알려진 문제). 우리 argocd-cm 의 `resource.exclusions` 에 tekton 박혀있어 회피. 만약 새 좀비 CRD 추가되면 같은 패턴으로 exclusion 추가:

```bash
kubectl edit cm argocd-cm -n skala3-finalproj-class3-team13
# resource.exclusions 섹션에 새 apiGroup 추가
kubectl rollout restart deploy/axis-argocd-application-controller \
  -n skala3-finalproj-class3-team13
```

### 7.3 ArgoCD UI 로그인 실패 (5회 fail → lockout)

[§3.2](#32-인계자-reset-절차) 의 reset 절차.

### 7.4 새 service 추가 시 ResourceQuota services 한도 막힘

현재 10/10. 매니저에 quota 증액 1줄 요청 또는 ApplicationSet pod/svc 직접 삭제 ([ci-cd-plan.md §11 P8](./ci-cd-plan.md) 참조).

### 7.5 pod 가 새 이미지 안 받음

`imagePullPolicy: Always` 인지 확인. 또는 `kubectl rollout restart deploy/<name>` 수동.

## 8. 비상 절차

### 8.1 잘못된 코드 deploy → 즉시 rollback

```bash
cd axis-infra
git log --oneline -10                     # 최근 deploy commits 확인
git revert <bad-commit-sha>
git push origin develop
# ArgoCD 3분 polling 또는 즉시:
kubectl annotate application axis-team13 -n skala3-finalproj-class3-team13 \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 8.2 발표/리뷰 직전 freeze

```bash
# ArgoCD 가 자동 sync 안 하게
kubectl patch application axis-team13 -n skala3-finalproj-class3-team13 \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 풀기
kubectl patch application axis-team13 -n skala3-finalproj-class3-team13 \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}'
```

### 8.3 Application 삭제 시 cluster 리소스 cascade delete 방지

finalizer 먼저 제거 — [ci-cd-plan.md §12 W2](./ci-cd-plan.md) 참조.

## 9. P8 진행 시 우선순위

[ci-cd-plan.md §11 P8](./ci-cd-plan.md) 의 8개 항목 중 권장 순서:

1. **Resend domain verify** — 매니저에 DNS TXT 요청. 통과 시 이메일 알림 활성.
2. **services quota 증액** — 매니저 1줄 요청. ApplicationSet 정리보다 우선.
3. **selfHeal: true 전환** — `argocd app set ... --sync-policy none` 룰 정착 후.
4. **on-deployed trigger 끄기** — 운영 spam 방지.
5. **Sealed Secrets / ESO** — secret GitOps 화.
6. **branch protection** — develop merge 보호.
7. **production overlay** — 시나리오 B 검토.
8. **ApplicationSet 정리** — services quota 증액 통과 시 자연 해결.

## 10. 외부 의존성 한 줄 요약

| 외부 | 영향 시 | 대안 |
|---|---|---|
| GitHub | push 안 됨 → 배포 멈춤 | mirror repo |
| Harbor | image push 안 됨 | local registry |
| SKALA cluster | 모든 게 멈춤 | 매니저 응급 |
| Resend | 이메일만 안 옴 | Brevo / SES pivot |
| AWS Route53 (skax.skala.ai) | domain verify 불가 | 매니저 |

## 끝

문의: README.md / ci-cd-plan.md / k8s/argocd/README.md 참조. 매니저 access 가 막혀있으면 SKALA infra 팀에 (조 13 멘션 + 본인 인계 받은 사람 이름) 요청.
