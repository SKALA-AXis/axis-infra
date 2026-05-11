# AXIS CI/CD 계획서 (v6 — 운영 진입)

> 작성: 2026-05-11 (v6 — 자체 ArgoCD pivot · Tekton 좀비 회피 · Resend SMTP · P1-P6 완료)
> 이전 버전: v5 (5 critical + 5 medium + 3 minor) · v4 (workflow_run head_sha) · v3 (project=default) · v2 (ArgoCD 도입) · v1 (GH Actions only)
> 대상: 4 레포 (axis-ai · axis-backend · axis-frontend · axis-infra) → SKALA EKS 클러스터
> ArgoCD: **우리 ns 의 자체 axis-argocd helm release** (공용 skala-argocd 가 Tekton 좀비 CRD 로 ComparisonError)

---

## 1. 목표 (달성됨)

본인 Mac 에서 수동 `make skala-build skala-push skala-apply` → **`git push` 만 하면 자동 배포** + ArgoCD UI 시각화.

- 매뉴얼 ~15분 → CI 5-10분 자동 ✅
- GitOps: manifest = git, deploy = `git commit/revert` ✅
- Rollback: `git revert` 또는 ArgoCD UI 클릭 (P6 drill 23초 자동 복원 검증) ✅

---

## 2. 핵심 결정사항 (v6 — 운영 진입)

| 항목 | 결정 | 비고 |
|---|---|---|
| CD 도구 | **자체 ArgoCD** (helm release `axis-argocd`) | 공용 `skala-argocd` 가 Tekton 좀비 CRD 의 conversion webhook fail 로 sync 불가 → pivot |
| Install 모드 | namespace-scoped minimal | server / controller / repo-server / redis (+ applicationset 강제 포함) |
| 트리거 | service repo push → GH Actions → axis-infra commit → ArgoCD sync | |
| Sync 정책 | `selfHeal: false` (발표 단계) | P6 drill 통과 — 발표 후 P8 에서 true 전환 검토 |
| Sync 트리거 | 3분 polling | demo 시 `argocd app sync` 또는 UI SYNC 버튼 즉시 강제 |
| AppProject | `default` (자체 ArgoCD 내) | |
| Secret 관리 | 수동 1회 apply + ignoreDifferences | Sealed Secrets / ESO 는 P8 |
| 이미지 태그 갱신 | `kustomize edit set image` CLI | sed regex 폐기 |
| 이미지 태그 값 | git short SHA (예: `04a01d5`) | 추적성 |
| 빌드 platform | `linux/amd64` 강제 | EKS 노드 amd64 |
| CI gating | `workflow_run` (ci.yml 성공시만) | test fail → deploy 차단 |
| Concurrency | `cancel-in-progress=false` | image / commit 불일치 방지 |
| 알림 | ArgoCD notifications (SMTP) | 구조 완성, Resend onboarding 제약으로 실 수신 보류 → P8 domain verify |
| ★ Tekton 좀비 CRD 회피 | argocd-cm 의 `resource.exclusions` 에 tekton 명시 제외 | cluster cache 빌드 시 conversion webhook 안 호출 |
| ★ ResourceQuota | services 10/10 도달 (axis 6 + ArgoCD 4) | 새 svc 추가 시 막힘. P8 매니저 quota 증액 또는 ApplicationSet pod/svc 정리 |
| ★ ArgoCD admin pw | `kubectl patch secret argocd-secret` (bcrypt) | 자동 random pw 폐기. reset 절차는 README |
| ★ helm upgrade 주의 | `--set configs.secret.argocdServerAdminPassword` 사용 금지 | SSA fieldManager 충돌 (kubectl-patch vs helm) — `--set` 빼면 chart 가 admin.password data 안 박음 → 우리 reset pw 보존 |

---

## 3. 전체 흐름 (실 동작 확인됨)

```
[service repo (axis-ai/backend/frontend) develop push]
         ↓
   ci.yml (test + lint + build validate)  [GATE — fail 시 중단]
         ↓
   build-and-push.yml (workflow_run trigger)
         ├─ disk free (runner ~10GB 회수)
         ├─ Docker buildx --platform=linux/amd64
         ├─ Harbor push (tag: git SHA + :develop + :buildcache)
         └─ axis-infra clone (depth=10) → kustomize edit set image → commit → push (3회 retry)
                 ↓
[axis-infra develop 에 "deploy: axis-ai → 04a01d5" commit]
         ↓
   자체 axis-argocd (3분 polling, demo 시 수동 강제) develop 변경 감지
         ↓
   auto-sync → kustomize build + apply (ServerSideApply)
         ↓
   Pod rollout (imagePullPolicy: Always)
         ↓
   ArgoCD UI: OutOfSync → Syncing → Synced ✓ / Healthy ✓
```

---

## 4. 브랜치 전략

### 4.1 현재
- **develop** = 활성 개발 + ArgoCD 자동 배포
- main = 거의 미사용 (PR 머지 base 만)

### 4.2 develop → main 이전 (시나리오별)

| 시나리오 | 작업량 | 언제 |
|---|---|---|
| **A. 단순 rename** | 30분 (sed) | 단일 환경 운영 + main 을 주력으로 바꿀 때 |
| **B. 환경 분리** (dev/prod) | 2-3시간 (Application + workflow 추가) | 발표 후 운영 단계 + production 분리 |
| **C. Promotion flow** (PR merge → prod) | 1시간 (workflow 1개 추가) | dev 항상 + prod 가끔 |

### 4.3 시나리오 A 구체

```bash
# 3 service repos
for repo in axis-ai axis-backend axis-frontend; do
  cd $repo
  sed -i '' 's/branches: \[develop\]/branches: [main]/g; s/-b develop/-b main/g; s/origin develop/origin main/g' \
    .github/workflows/*.yml
  git add . && git commit -m "ci: switch deploy branch to main" && git push
done

# axis-infra Application CR
cd axis-infra
sed -i '' 's/targetRevision: develop/targetRevision: main/g' \
  k8s/argocd/axis-application.yaml
git add . && git commit -m "cd: ArgoCD now watches main" && git push
```

→ ArgoCD 다음 sync 시 main branch 추적. **yml 재작성 X — 4개 라인 sed**.

---

## 5. service repo 변경 (axis-ai · axis-backend · axis-frontend) — 적용 완료

각 repo 의 `.github/workflows/build-and-push.yml` 가 동일 패턴 (IMAGE_NAME 만 다름).

- workflow_run trigger: `workflows: [CI]` (ci.yml 의 name 과 일치)
- concurrency: `cancel-in-progress=false`
- Free disk: ~10GB 회수
- buildx + `--platform=linux/amd64` + Harbor :SHA + :develop + :buildcache 3 tag
- `kustomize edit set image` → axis-infra develop auto-commit (3회 retry + `--depth=10` + `fetch --unshallow` on rebase)

검증: rev `04a01d5` (axis-ai), `37a87a8` (axis-backend), `dfeeb1b` (axis-frontend) 자동 deploy commits 확인됨.

---

## 6. 자체 ArgoCD (axis-argocd) — 핵심 변경 v6

### 6.1 왜 자체 ArgoCD?

공용 `skala-argocd` cluster cache 가 cluster 의 좀비 Tekton CRD (`tasks.tekton.dev` 등 19개) 의 conversion webhook 호출에서 영구 fail. webhook svc (`tekton-pipelines-webhook` in `tekton-pipelines` ns) 가 cluster 에 실재하지 않음 (uninstall 미완 후 480일 방치). 모든 Application sync 불가.

→ 우리 ns 에 namespace-scoped ArgoCD 설치 + argocd-cm 의 `resource.exclusions` 로 Tekton CRD 회피.

### 6.2 helm values 핵심 ([k8s/argocd-self/values.yaml](../k8s/argocd-self/values.yaml))

```yaml
crds:
  install: false                        # CRD 이미 cluster 에 있음

dex:
  enabled: false                        # SSO X
notifications:
  enabled: true                         # 알림 controller
applicationSet:
  enabled: false                        # chart v9.5+ 강제 포함 (services quota 차지) — P8 정리

controller:
  clusterAdminAccess:
    enabled: false                      # ClusterRole 제한
server:
  service:
    type: ClusterIP                     # port-forward 로 접근
redis:
  enabled: true

configs:
  cm:
    application.namespaces: "skala3-finalproj-class3-team13"
    resource.exclusions: |
      - apiGroups: [tekton.dev, triggers.tekton.dev, resolution.tekton.dev, dashboard.tekton.dev]
        kinds: ['*']
        clusters: ['*']
```

### 6.3 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install axis-argocd argo/argo-cd \
  -n skala3-finalproj-class3-team13 \
  -f k8s/argocd-self/values.yaml \
  --version 9.5.13
```

### 6.4 Application + repo Secret ([k8s/argocd/](../k8s/argocd/))

- `axis-application.yaml`: metadata.namespace=skala3-finalproj-class3-team13 (자체 ArgoCD ns), project=default, selfHeal=false, HPA replicas + Secret stringData ignoreDifferences
- `repo-secret.yaml`: gitignored — GitHub fine-grained PAT (read-only). 직접 apply.

---

## 7. ArgoCD UI 접속

```bash
# port-forward (server type: ClusterIP)
kubectl port-forward -n skala3-finalproj-class3-team13 svc/axis-argocd-server 8080:443
# 브라우저: https://localhost:8080 (cert warning 무시)

# admin 비번 (chart 의 random 값)
kubectl -n skala3-finalproj-class3-team13 get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### 비번 reset 절차 (망각 또는 보안 강화 시)

```bash
read -s NEW_PWD
HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$NEW_PWD', bcrypt.gensalt(rounds=10)).decode())")
unset NEW_PWD
kubectl -n skala3-finalproj-class3-team13 patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"}}"
kubectl rollout restart deploy/axis-argocd-server -n skala3-finalproj-class3-team13
```

### helm upgrade 시 주의

`--set configs.secret.argocdServerAdminPassword=...` **사용 금지** — kubectl-patch fieldManager 와 helm SSA fieldManager 충돌. `--set` 없이 upgrade 시 chart 가 argocd-secret 의 data 안 박음 → 우리 reset pw 보존.

---

## 8. Secret 관리

### 8.1 axis-secrets / axis-postgres-bootstrap (cluster 직접 apply)

```bash
cd axis-infra
$EDITOR .env                                            # 새 값 채움
make skala-secret                                       # secret.skala.yaml 생성 (gitignored)
kubectl apply -f k8s/overlays/skala/secret.skala.yaml   # 1회 또는 키 갱신 시
```

`scripts/env-to-skala-secret.sh` 가 `argocd.argoproj.io/sync-options: Prune=false` annotation 자동 박음 — ArgoCD 가 manifest 에서 빠져도 prune X.

### 8.2 ArgoCD repo Secret

```bash
read -s ARGOCD_PAT
export ARGOCD_PAT
sed "s|REPLACE_GITHUB_PAT_READ_ONLY|$ARGOCD_PAT|" k8s/argocd/repo-secret.yaml \
  | kubectl apply -f -
unset ARGOCD_PAT
```

### 8.3 SMTP — Resend (구조 완성, 실 수신 보류)

발표 단계: `smtp.resend.com:587` (axis-ai) / `:465` (ArgoCD), sender=`onboarding@resend.dev`, API key 는 `axis-secrets.SMTP_PASSWORD` 와 `argocd-notifications-secret.email-password` 에 동일 박힘.

**보류 사유**: Resend 의 `onboarding@resend.dev` sender 가 *verified email* 에만 deliver. 도메인 verify 없으면 silent drop (dashboard 에 0건). domain verify 는 `skax.skala.ai` 의 DNS TXT 추가 필요 — SKALA 매니저 권한. → P8.

### 8.4 추후 (P8) — Sealed Secrets / ESO

SKALA 매니저에게 controller 설치 요청 후 `kubeseal` 로 git commit 가능.

---

## 9. GitHub Actions Secrets (등록 완료)

### service repo 공통 (axis-ai / axis-backend / axis-frontend)

| Secret | 값 | 어디서 |
|---|---|---|
| `HARBOR_USERNAME` | `robot$skala26a-ai3` | 매니저 발급 |
| `HARBOR_PASSWORD` | robot token | 매니저 발급 |
| `INFRA_DISPATCH_PAT` | fine-grained PAT, `SKALA-AXis/axis-infra` **contents: write** | 본인 발급, 90일 만료 |

### axis-infra

ArgoCD 가 cluster 내부에서 동작 → GH Actions 에 AWS / kubectl creds 0건. validate.yml 만 유지.

---

## 10. Phase 로드맵 (P1-P6 완료 + P7 부분 보류 + P8)

| Phase | 기간 | 상태 | 검증 |
|---|---|---|---|
| **P1 — axis-infra 준비** | 0.5일 | ✅ 완료 | kustomization secret 분리 / PVC + Secret prune 방지 / argocd 디렉토리 |
| **P2 — Build & Push** | 1일 | ✅ 완료 | 3 service repo build-and-push.yml + HARBOR_* / PAT secret |
| **P3 — Manifest 자동 commit** | 0.5일 | ✅ 완료 | "deploy: SVC → SHA" commits 자동 들어옴 |
| **P4 — ArgoCD Application** | 0.5일 | ✅ 완료 (pivot: 공용 → 자체) | helm release `axis-argocd` + Application 등록 |
| **P5 — E2E 검증** | 0.5일 | ✅ 완료 | 35+ 리소스 Synced + new SHA pod rollout |
| **P6 — Rollback drill** | 0.5일 | ✅ 완료 | git revert push → 23초 자동 복원 |
| **P7 — 이메일 알림** | 1일 | 🟡 부분 | 구조 ✅ (controller / trigger / template). 실 수신 보류 (도메인 verify 필요) |
| **P8 — 운영 강화 (발표 후)** | 2-3일 | 대기 | 아래 §11 |

---

## 11. P8 — 운영 강화 (발표 후)

발표 통과 후 진행 권장:

1. **Resend domain verify** — SKALA 매니저에 `skax.skala.ai` 의 DNS TXT 레코드 추가 요청 (Resend 가이드 4-5 레코드). verify 후 sender = `axis-cicd@skax.skala.ai`. 실 6명 수신 활성.
2. **ApplicationSet pod/svc 정리** — chart v9.5+ 부터 disable 불가. 직접 `kubectl delete svc/deploy axis-argocd-applicationset-controller` (helm 이 매번 다시 만들 거 → cluster 내 admission webhook 또는 매니저에 services quota 증액 요청 시 자연 해결).
3. **services quota 증액** — 매니저에 `services: 10 → 15` 1줄 요청.
4. **`selfHeal: true` 전환 검토** — P6 drill 통과. 디버그 시 ArgoCD 가 즉시 복원 = 사고 위험 룰 (argocd app set ... --sync-policy none) 정착 후 전환.
5. **`on-deployed` trigger 끄기** — 운영 시 매 deploy 마다 이메일 = spam. on-sync-failed + on-health-degraded 만 유지.
6. **Sealed Secrets / ESO** — secret.skala.yaml / argocd-notifications-secret / repo-secret.yaml 을 GitOps 화.
7. **branch protection** — develop merge PR review 1명 + CI 통과 필수 (bot push bypass 허용).
8. **production overlay** — 시나리오 B (dev/prod 환경 분리) 시 두 ArgoCD Application + ApplicationSet 검토.

---

## 12. 위험 / 운영

### 위험
1. **자동 commit 의 git history 오염** — `deploy: ...` commit 이 develop 에 쏟아짐. squash merge 또는 별도 `gitops` 브랜치 검토 (P8)
2. **selfHeal 사고** — 디버그 시 ArgoCD 가 즉시 복원. 룰:
   ```bash
   argocd app set axis-team13 --sync-policy none
   # 디버그 작업
   argocd app set axis-team13 --sync-policy automated
   ```
3. **PAT 만료** — fine-grained PAT 1년 expiry. 캘린더 reminder (HANDOVER.md §3)
4. **race condition** — retry 로직으로 완화. concurrent push 잦으면 ApplicationSet 검토 (P8)
5. **GH Actions free minutes** — Org 가 private 면 월 2000분 한도. 한 달 ~3000-6000분 예상이라 빠듯. 필요시 self-hosted runner 또는 일시적 public 전환

### v6 신규 위험
- **W5: Tekton 좀비 CRD** — cluster 의 19개 좀비 CRD 가 conversion webhook fail. 우리 자체 ArgoCD 의 `resource.exclusions` 로 회피. 다른 도구 (helm / kubectl get all) 도 같은 영향. 매니저에 1줄 알림 권장.
- **W6: ResourceQuota services 10/10** — 발표 cluster 상태. 새 svc 추가 시 reject. P8 quota 증액 또는 ApplicationSet 정리.
- **W7: Resend onboarding sender 제약** — domain verify 없으면 verified email 만 deliver. P7 보류 → P8.
- **W8: helm upgrade SSA 충돌** — kubectl-patch fieldManager (admin password) vs helm SSA. `--set configs.secret.argocdServerAdminPassword` 빼고 upgrade.

### 잠재 위험 (모니터링)
- **W1: 첫 sync conflict** — 검증됨 (ServerSideApply=true 로 해결)
- **W2: Application 의 `finalizers` cascade delete** — 발표 직전 finalizer 제거 검토:
  ```bash
  kubectl patch application axis-team13 -n skala3-finalproj-class3-team13 \
    --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  ```
- **W3: ConfigMap 변경 시 Pod 미재시작** — `axis-config` 갱신 시 자동 rollout X. 수동 `kubectl rollout restart` 또는 configMapGenerator + hash suffix (P8)
- **W4: Harbor 디스크 누적** — Harbor GC 정책 매니저 확인 (P8)

---

## 13. Rollback 절차 (P6 검증됨)

**1순위 — git revert** (GitOps 정통, P6 drill 23초 자동 복원 검증):

```bash
cd axis-infra
git revert <bad-commit-sha>
git push origin develop
# ArgoCD 3분 polling 내 detect → auto-sync → 이전 image 로 복원
# 즉시 강제 (demo):
kubectl annotate application axis-team13 -n skala3-finalproj-class3-team13 \
  argocd.argoproj.io/refresh=hard --overwrite
```

**2순위 — ArgoCD UI**: History → 이전 sync → "Rollback" 클릭 → ~30초

**3순위 — Emergency kubectl** (selfHeal: false 인 경우만 유효):
```bash
kubectl rollout undo deployment/axis-backend -n skala3-finalproj-class3-team13
# 직후 반드시 git revert 도 같이 (selfHeal: true 면 ArgoCD 가 다시 복원)
```

---

## 14. 발표 데모 시나리오

ArgoCD UI 가 시각적 어필 큼. 4 화면 같이:

1. 본인 Mac (vscode + 터미널)
2. GitHub Actions 페이지 (https://github.com/SKALA-AXis/{axis-ai,backend,frontend}/actions)
3. ArgoCD UI (`https://localhost:8080` port-forward) — sync 색 변화 + 트리 다이어그램
4. ALB endpoint (`http://skala3-team13-axis-alb-1349892737.ap-northeast-2.elb.amazonaws.com`) — 변경 반영

**시연 흐름**:
1. axis-frontend 소문구 수정 → `git push origin develop`
2. Actions 로그: CI ✓ → build → push → axis-infra commit (~5분)
3. axis-infra 페이지: "deploy: axis-frontend → SHA" commit 등장
4. ArgoCD UI 의 SYNC 버튼 으로 즉시 트리거 (polling 30초 단축)
5. UI 상태: `OutOfSync` → `Syncing` → `Synced` → `Healthy` 시각 변화
6. frontend hard reload → 변경 반영

→ "**`git push` 한 번 으로 production deploy**" GitOps 정통 시연.

---

## 15. v5 → v6 변경 요약

1. **공용 skala-argocd → 자체 axis-argocd pivot** (Tekton 좀비 회피)
2. **helm chart values 추가** (`k8s/argocd-self/values.yaml`)
3. **ArgoCD admin pw reset 절차** (bcrypt patch + rollout restart)
4. **helm upgrade SSA 충돌 회피** (`--set configs.secret.argocdServerAdminPassword` 사용 금지)
5. **SMTP SendGrid → Resend pivot** (SendGrid 가입 거부 대안). 발표 단계 onboarding sender 제약으로 실 수신 보류 → P8 domain verify
6. **P7 부분 보류 표시** (구조 OK, 실 수신 X)
7. **P8 운영 강화** 항목 확장 (8개)
8. **W5-W8 신규 위험** 추가
9. **P6 drill 검증** 결과 반영 (23초 자동 복원)
10. **HANDOVER.md** 별도 작성 (PAT 회전 / cluster access / SMTP key rotation 등 인계)
