# AXIS CI/CD 계획서 (v7 — 공용 ArgoCD 정착)

> 작성: 2026-05-11 (v7 — 자체 ArgoCD pivot 정정 · Tekton CRD cleanup · 공용 skala-argocd 정착)
> 이전 버전: v6 (자체 ArgoCD pivot) · v5 (5 critical + 5 medium + 3 minor) · v4 · v3 · v2 · v1
> 대상: 4 레포 (axis-ai · axis-backend · axis-frontend · axis-infra) → SKALA EKS 클러스터
> ArgoCD: **공용 `skala-argocd`** (매니저 운영, HA controller × 3, 외부 ingress)

---

## 1. 목표 (달성됨)

`git push` 만 하면 자동 배포 + ArgoCD UI 외부 URL 시각화.

- 매뉴얼 ~15분 → CI 5-10분 자동 ✅
- GitOps: manifest = git, deploy = `git commit/revert` ✅
- Rollback: `git revert` 또는 ArgoCD UI 클릭 (P6 drill 23초 자동 복원) ✅
- UI: https://argocd.skala25a.project.skala-ai.com (외부 ingress, port-forward 불필요) ✅

---

## 2. 핵심 결정사항 (v7 — 공용 정착)

| 항목 | 결정 | 비고 |
|---|---|---|
| CD 도구 | **공용 SKALA ArgoCD** (`skala-argocd` release) | 매니저 운영, HA × 3, 399일 운영 |
| Tekton 좀비 회피 | **cluster 의 Tekton CRD 19개 cleanup** (매니저 처리 완료) | finalizer stuck 2개는 우리가 강제 제거 (안전 — 480일 dead CR 0건) |
| 자체 ArgoCD pivot | **폐기** — Tekton cleanup 후 공용 사용 가능 | v6 의 자체 axis-argocd helm release 는 uninstall 완료 |
| Application ns | `skala-argocd` (공용 controller 의 ns) | destination ns = 우리 ns 유지 |
| 트리거 | service repo push → GH Actions → axis-infra commit → ArgoCD sync | |
| Sync 정책 | `selfHeal: false` 유지 | 발표 후 P8 에서 true 전환 검토 |
| Sync 트리거 | 3분 polling | demo 시 `argocd app sync` 또는 UI SYNC 버튼 즉시 |
| AppProject | `default` | server dry-run 통과 |
| Secret 관리 | 수동 1회 apply + ignoreDifferences | Sealed Secrets 는 P8 |
| 이미지 태그 갱신 | `kustomize edit set image` | git short SHA |
| 빌드 platform | `linux/amd64` 강제 | EKS amd64 |
| CI gating | `workflow_run` (ci.yml 성공시만) | test fail → deploy 차단 |
| Concurrency | `cancel-in-progress=false` | image / commit 불일치 방지 |
| 알림 | 구조 완성, 실 수신 보류 → P8 domain verify | `skala-ai.com` sub 도메인 가이드 매니저 요청 중 |
| ArgoCD admin / upgrade | **매니저 영역** | 우리 관리 부담 0 (v6 자체 ArgoCD 의 admin pw reset / helm upgrade SSA 충돌 절차 모두 불필요) |
| ResourceQuota | services 6/10 (여유 4) | 자체 ArgoCD 의 4 svc 회수 |

---

## 3. 전체 흐름 (실 동작 검증됨)

```
[service repo (axis-ai/backend/frontend) develop push]
         ↓
   ci.yml (test + lint + build validate)  [GATE — fail 시 중단]
         ↓
   build-and-push.yml (workflow_run trigger)
         ├─ disk free (~10GB 회수)
         ├─ Docker buildx --platform=linux/amd64
         ├─ Harbor push (tag: git SHA + :develop + :buildcache)
         └─ axis-infra clone (depth=10) → kustomize edit set image → commit → push (3회 retry)
                 ↓
[axis-infra develop 에 "deploy: SVC → SHA" auto-commit]
         ↓
   공용 skala-argocd controller (3분 polling, demo 시 수동 강제) develop 변경 감지
         ↓
   auto-sync → kustomize build + apply (ServerSideApply)
         ↓
   Pod rollout (imagePullPolicy: Always)
         ↓
   ArgoCD UI (https://argocd.skala25a.project.skala-ai.com):
   OutOfSync → Syncing → Synced ✓ / Healthy ✓
```

---

## 4. 브랜치 전략

### 4.1 현재
- **develop** = 활성 개발 + ArgoCD 자동 배포
- main = 거의 미사용

### 4.2 develop → main 이전 시나리오

| 시나리오 | 작업량 | 언제 |
|---|---|---|
| A. 단순 rename | 30분 (sed) | 단일 환경 + main 주력 |
| B. 환경 분리 (dev/prod) | 2-3시간 | 발표 후 운영 + production 분리 |
| C. Promotion flow | 1시간 | dev 항상 + prod 가끔 |

### 4.3 시나리오 A 구체

```bash
# 3 service repos
for repo in axis-ai axis-backend axis-frontend; do
  cd $repo
  sed -i '' 's/branches: \[develop\]/branches: [main]/g; s/-b develop/-b main/g; s/origin develop/origin main/g' \
    .github/workflows/*.yml
  git add . && git commit -m "ci: switch deploy branch to main" && git push
done

cd axis-infra
sed -i '' 's/targetRevision: develop/targetRevision: main/g' k8s/argocd/axis-application.yaml
git add . && git commit -m "cd: ArgoCD now watches main" && git push
```

---

## 5. service repo 변경 — 적용 완료

각 repo 의 `.github/workflows/build-and-push.yml` 가 동일 패턴 (IMAGE_NAME 만 다름).

- workflow_run trigger: `workflows: [CI]`
- concurrency: `cancel-in-progress=false`
- Free disk: ~10GB 회수
- buildx + `--platform=linux/amd64` + Harbor :SHA + :develop + :buildcache
- `kustomize edit set image` → axis-infra develop auto-commit (3회 retry + `--depth=10` + `fetch --unshallow` on rebase)

---

## 6. axis-infra 변경 (Phase A-E 완료)

### 6.1 kustomization.yaml — Secret 분리 ([k8s/overlays/skala/](../k8s/overlays/skala/))

```
resources:
  - ../../base
  # secret.skala.yaml — gitignored, 클러스터 직접 1회 apply
  - postgres.yaml / qdrant.yaml / cronjob-pg-dump.yaml / networkpolicy-db.yaml / service-aliases.yaml
```

### 6.2 PVC prune 보호

postgres-data / qdrant-data / axis-images PVC 에 `argocd.argoproj.io/sync-options: Prune=false` annotation. manifest 에서 빠져도 데이터 보호.

### 6.3 Secret prune 보호

`scripts/env-to-skala-secret.sh` 가 generated YAML 에 prune 방지 annotation 자동 박음.

### 6.4 공용 ArgoCD repo Secret ([k8s/argocd/repo-secret.yaml](../k8s/argocd/repo-secret.yaml))

- metadata.namespace = `skala-argocd`
- labels = `argocd.argoproj.io/secret-type: repository`
- GitHub fine-grained PAT (Contents: Read-only)
- gitignored — PAT 실값은 cluster 직접 apply

### 6.5 Application CR ([k8s/argocd/axis-application.yaml](../k8s/argocd/axis-application.yaml))

```yaml
metadata:
  name: axis-team13
  namespace: skala-argocd          # 공용 ArgoCD controller 의 ns
spec:
  project: default
  source:
    repoURL: https://github.com/SKALA-AXis/axis-infra.git
    targetRevision: develop
    path: k8s/overlays/skala
  destination:
    server: https://kubernetes.default.svc
    namespace: skala3-finalproj-class3-team13
  syncPolicy:
    automated: {prune: true, selfHeal: false}
    syncOptions: [ServerSideApply=true, PruneLast=true, CreateNamespace=false]
  ignoreDifferences:
    - {group: '', kind: Secret, jsonPointers: [/stringData, /data]}
    - {group: apps, kind: Deployment, name: axis-backend, jsonPointers: [/spec/replicas]}
    - {group: apps, kind: Deployment, name: axis-frontend, jsonPointers: [/spec/replicas]}
```

### 6.6 자체 ArgoCD values 참조 자료 ([k8s/argocd-self/values.yaml](../k8s/argocd-self/values.yaml))

자체 ArgoCD 는 uninstall 됐지만 values.yaml 보존 — **P8 notifications 활성 시 공용 argocd-notifications-cm 에 추가할 spec 참조 자료**.

핵심 섹션:
- SMTP host/port/from/username (Resend / Brevo / SES 별 패턴)
- subscriptions (team13 6명)
- 3 triggers + 한국어 본문 templates

---

## 7. ArgoCD UI 접속

```
브라우저: https://argocd.skala25a.project.skala-ai.com
username: admin
password: 매니저 가이드 (또는 cluster 의 argocd-initial-admin-secret 의 값)
```

**port-forward 불필요** — 외부 ingress 로 직접 접속. 발표 시 4 화면 셋업 단순화.

---

## 8. Secret 관리

### 8.1 axis-secrets / axis-postgres-bootstrap (cluster 직접 apply)

```bash
cd axis-infra
$EDITOR .env
make skala-secret                                       # secret.skala.yaml 생성 (gitignored)
kubectl apply -f k8s/overlays/skala/secret.skala.yaml
```

`scripts/env-to-skala-secret.sh` 가 prune 방지 annotation 자동 박음.

### 8.2 ArgoCD repo Secret

```bash
read -s ARGOCD_PAT
sed "s|REPLACE_GITHUB_PAT_READ_ONLY|$ARGOCD_PAT|" k8s/argocd/repo-secret.yaml \
  | kubectl apply -f -
unset ARGOCD_PAT
```

### 8.3 SMTP (P7 보류 — P8 domain verify 후 활성)

- 발신 도메인: `skala-ai.com` sub (매니저 가이드 중)
- ESP 후보: Brevo / AWS SES (가입 + 도메인 verify)
- 6명 수신자 + 한국어 본문 templates 는 [k8s/argocd-self/values.yaml](../k8s/argocd-self/values.yaml) 참조

### 8.4 추후 (P8) — Sealed Secrets / ESO

매니저에 controller 설치 요청 후 `kubeseal` 로 git commit.

---

## 9. GitHub Actions Secrets (등록 완료)

### service repo 공통

| Secret | 값 | 만료 |
|---|---|---|
| `HARBOR_USERNAME` | `robot$skala26a-ai3` | 매니저 발급 |
| `HARBOR_PASSWORD` | robot token | 매니저 발급 |
| `INFRA_DISPATCH_PAT` | fine-grained PAT (axis-infra Contents write) | 90일 |

### axis-infra

GH Actions 에 AWS / kubectl creds 0건 (ArgoCD 가 cluster 내부에서 pull).

---

## 10. Phase 진행 상태

| Phase | 기간 | 상태 |
|---|---|---|
| P1 — axis-infra 준비 | 0.5일 | ✅ 완료 |
| P2 — Build & Push | 1일 | ✅ 완료 |
| P3 — Manifest auto-commit | 0.5일 | ✅ 완료 |
| P4 — ArgoCD Application | 0.5일 | ✅ 완료 (공용 정착) |
| P5 — E2E auto-sync | 0.5일 | ✅ 완료 |
| P6 — Rollback drill | 0.5일 | ✅ 완료 (23초 자동 복원) |
| P7 — 이메일 알림 | 1일 | 🟡 구조 완성, 실 수신 보류 (도메인 verify 대기) |
| P8 — 운영 강화 (발표 후) | 2-3일 | 대기 |

---

## 11. P8 — 운영 강화 (발표 후)

발표 통과 후 진행 권장:

1. **Resend / Brevo / AWS SES domain verify** — 매니저가 `*.skala-ai.com` sub 도메인 발급 + DNS TXT 추가 (가이드 진행 중). verify 후 sender = `axis-cicd@<sub>.skala-ai.com` 또는 `axis-briefing@<sub>.skala-ai.com`. 6명 실 수신 활성.
2. **공용 argocd-notifications-cm 갱신** — 매니저가 [k8s/argocd-self/values.yaml](../k8s/argocd-self/values.yaml) 의 notifications spec 을 공용 argocd-notifications-cm 에 추가. team13 의 subscriptions / templates / triggers.
3. **`selfHeal: true` 전환 검토** — P6 drill 통과. 디버그 시 `argocd app set ... --sync-policy none` 룰 정착 후.
4. **`on-deployed` trigger off** — 운영 시 매 deploy 마다 이메일 = spam. on-sync-failed + on-health-degraded 만 유지.
5. **Sealed Secrets / ESO** — secret.skala.yaml / repo-secret.yaml 의 GitOps 화.
6. **branch protection** — develop merge PR review 1명 + CI 통과 필수.
7. **production overlay** — 시나리오 B (dev/prod 환경 분리).
8. **production ESP (AWS SES)** — SK AX 인수 후 정공 (cluster 가 AWS 위라 IAM/CloudWatch 통합).

---

## 12. 위험 / 운영

### 위험
1. **자동 commit 의 git history 오염** — `deploy: ...` commit 이 develop 에 쏟아짐. squash merge 또는 별도 gitops 브랜치 검토 (P8)
2. **selfHeal 사고** — 디버그 시 ArgoCD 가 즉시 복원. 룰:
   ```bash
   argocd app set axis-team13 --sync-policy none
   # 디버그 작업
   argocd app set axis-team13 --sync-policy automated
   ```
3. **PAT 만료** — fine-grained PAT 90일 expiry. 캘린더 reminder ([HANDOVER.md §2](./HANDOVER.md))
4. **GH Actions free minutes** — Org 가 private 면 월 2000분 한도. 필요시 self-hosted runner

### v6 → v7 해소된 위험
- ~~W5: Tekton 좀비 CRD~~ — **매니저 cleanup 완료** (19 → 0)
- ~~W6: ResourceQuota services 10/10~~ — **자체 ArgoCD 회수 후 6/10**
- ~~W8: helm upgrade SSA 충돌~~ — **자체 ArgoCD 폐기로 무관**

### 남은 위험
- **W7: SMTP sender 도메인 미인증** — P8 매니저 가이드 진행 중
- **W1: 첫 sync conflict** — ServerSideApply=true 로 해결 (검증됨)
- **W2: Application finalizer cascade delete** — 발표 직전 finalizer 제거 검토:
  ```bash
  kubectl patch application axis-team13 -n skala-argocd \
    --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  ```
- **W3: ConfigMap 변경 시 Pod 미재시작** — `axis-config` 갱신 시 수동 `kubectl rollout restart`
- **W4: Harbor 디스크 누적** — Harbor GC 정책 매니저 확인 (P8)

---

## 13. Rollback 절차 (P6 23초 자동 복원 검증됨)

**1순위 — git revert** (GitOps 정통):

```bash
cd axis-infra
git revert <bad-commit-sha>
git push origin develop
# ArgoCD 3분 polling 내 detect, 즉시 강제:
kubectl annotate application axis-team13 -n skala-argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

**2순위 — ArgoCD UI**: History → 이전 sync → Rollback → ~30초

**3순위 — Emergency kubectl** (selfHeal: false 인 경우만):
```bash
kubectl rollout undo deployment/axis-backend -n skala3-finalproj-class3-team13
# 직후 git revert 동반 (selfHeal: true 면 ArgoCD 가 다시 복원)
```

---

## 14. 발표 데모 시나리오

4 화면:
1. 본인 Mac (vscode + 터미널)
2. GitHub Actions (https://github.com/SKALA-AXis/{axis-ai,backend,frontend}/actions)
3. **ArgoCD UI** (https://argocd.skala25a.project.skala-ai.com) — port-forward 불필요!
4. ALB endpoint (frontend) — 변경 반영

**시연 흐름**:
1. axis-frontend 소문구 수정 → `git push origin develop`
2. Actions: CI ✓ → build → Harbor push → axis-infra commit (~5분)
3. axis-infra: "deploy: axis-frontend → SHA" commit 등장
4. ArgoCD UI 의 SYNC 버튼 즉시 트리거 (polling 30초 단축)
5. UI: OutOfSync → Syncing → Synced → Healthy 시각 변화
6. frontend hard reload → 변경 반영

→ "**git push 한 번 으로 production deploy**" GitOps 정통 시연.

---

## 15. v6 → v7 변경 요약

1. **자체 ArgoCD pivot 폐기** — Tekton 좀비 CRD cleanup 후 공용 사용 가능 (helm uninstall + values.yaml 은 spec 참조용 보존)
2. **Tekton 19 CRD cleanup** — 매니저 17개 + 우리 finalizer 강제 제거 2개 = 19 → 0. cluster cache 정상 빌드.
3. **공용 skala-argocd 정착** — 외부 ingress URL (https://argocd.skala25a.project.skala-ai.com), 매니저 운영
4. **ResourceQuota 회복** — services 10 → 6 (여유 4), pods 17 → 9
5. **자체 ArgoCD 관리 부담 0** — admin pw reset / helm upgrade SSA 절차 모두 불필요 (HANDOVER.md 단순화)
6. **P8 — sender 도메인 verify** 매니저 가이드 진행 중 (`*.skala-ai.com` sub 도메인)
7. **HANDOVER.md** 갱신 (자체 ArgoCD 절차 제거)
