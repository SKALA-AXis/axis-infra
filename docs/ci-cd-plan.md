# AXIS CI/CD 계획서 (v5 — 최종)

> 작성: 2026-05-11 (v5 — private repo credential / PVC prune / HPA replicas / shallow clone / admin secret 명 등 5 critical + 5 medium + 3 minor fix)
> 이전 버전: v4 (workflow_run head_sha) · v3 (project=default) · v2 (ArgoCD 도입) · v1 (GH Actions only)
> 대상: 4 레포 (axis-ai · axis-backend · axis-frontend · axis-infra) → SKALA EKS 클러스터
> ArgoCD: `skala-argocd` namespace (HA), Application CR 권한 ✅, default project dry-run ✅

---

## 1. 목표

매번 본인 Mac 에서 수동 `make skala-build skala-push skala-apply` → **`git push` 만 하면 자동 배포** + ArgoCD UI 시각화.

- iteration 매뉴얼 ~15분 → CI 5-10분 자동
- GitOps: manifest = git, deploy = `git commit/revert`
- Rollback: `git revert` 또는 ArgoCD UI 클릭

---

## 2. 핵심 결정사항 (v5 — 신규 ★)

| 항목 | 결정 | 비고 |
|---|---|---|
| CD 도구 | **ArgoCD** + GitHub Actions (build/push 만) | 클러스터에 이미 있음 |
| 트리거 | service repo push → GH Actions → axis-infra commit → ArgoCD sync | |
| Sync 정책 | `selfHeal: false` 로 시작, 안정화 후 true | 디버그 시 사고 방지 |
| Sync 트리거 | 3분 polling (webhook 미사용) | demo 시 `argocd app sync` 로 즉시 강제 가능 |
| AppProject | `default` (server dry-run 통과) | 발표 후 본인 project 신청 검토 |
| Secret 관리 | 수동 1회 apply + ignoreDifferences | Sealed Secrets 는 발표 후 P8 |
| 이미지 태그 갱신 | `kustomize edit set image` CLI | sed regex 폐기 |
| 이미지 태그 값 | git short SHA (예: `3501567`) | 추적성 |
| 빌드 platform | `linux/amd64` 강제 | EKS 노드 amd64 |
| CI gating | `workflow_run` (ci.yml 성공시만) | test fail → deploy 차단 |
| Concurrency | infra-bump group + retry | race condition 방지 |
| PR / 비 develop | CI 만 (push X / commit X) | 비용 / 안전 |
| ★ private repo 인증 | ArgoCD 의 repository Secret (`labels: argocd.argoproj.io/secret-type: repository`) | axis-infra 가 private 확인됨 |
| ★ PVC prune 보호 | postgres-data / qdrant-data / axis-images 에 `Prune=false` annotation | manifest 에서 빠져도 데이터 보호 |
| ★ HPA replicas | Deployment `/spec/replicas` 를 ignoreDifferences | HPA 와 ArgoCD 충돌 방지 |
| ★ Shallow clone fix | `--depth=10` + fetch --unshallow on rebase | git pull --rebase 동작 보장 |
| ★ ArgoCD admin secret | `argocd-initial-admin-secret` (cluster 확인) | plan 의 `skala-argocd-...` 오류 정정 |

---

## 3. 전체 흐름

```
[service repo (axis-ai/backend/frontend) develop push]
         ↓
   ci.yml (test + lint + build validate)  [GATE — fail 시 중단]
         ↓
   build-and-push.yml (workflow_run trigger)
         ├─ disk free (runner ~10GB 회수)
         ├─ Docker buildx --platform=linux/amd64
         ├─ Harbor push (tag: git SHA + buildcache)
         └─ axis-infra clone → kustomize edit set image → commit → push
                 ↓
[axis-infra develop 에 "deploy: axis-ai → 3501567" commit]
         ↓
   ArgoCD (3분 polling, 또는 demo 시 수동 강제) develop branch 변경 감지
         ↓
   auto-sync → kustomize build + apply (ServerSideApply)
         ↓
   Pod rollout (imagePullPolicy: Always)
         ↓
   ArgoCD UI: OutOfSync → Syncing → Synced ✓ / Healthy ✓
```

---

## 4. 브랜치 전략 ★

### 4.1 현재 (v5 기준)
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

### 4.4 시나리오 B 권장 시점
- 발표 후 1주일+ 운영 시
- 또는 SKALA cluster 가 staging / prod 두 namespace 받았을 때
- ApplicationSet 으로 dev/prod 자동화 가능

---

## 5. service repo 변경 (axis-ai · axis-backend · axis-frontend)

기존 `.github/workflows/ci.yml` 그대로. **신규 `.github/workflows/build-and-push.yml`** 추가:

```yaml
name: Build and Push

on:
  workflow_run:
    workflows: [CI]              # ci.yml 의 'name:' 과 일치 — 3 repo 모두 'CI' 확인
    types: [completed]
    branches: [develop]
  workflow_dispatch:

# 동일 service 의 push 가 연속되면 큐잉 (cancel 안 함 — 빌드/push 중간 cancel 시 image 와 commit 불일치 위험)
concurrency:
  group: build-push-${{ github.workflow }}
  cancel-in-progress: false

env:
  HARBOR_HOST: amdp-registry.skala-ai.com
  HARBOR_PROJECT: skala26a-ai3
  IMAGE_NAME: axis-ai            # axis-backend / axis-frontend 각각 변경

jobs:
  build-push:
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      # ★ workflow_run 은 default branch HEAD 기본 — head_sha 명시
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.workflow_run.head_sha || github.sha }}
          fetch-depth: 1                       # ★ M4: explicit ref 면 1 충분

      # ★ M3: 6GB 이미지 빌드용 디스크 확보 (~10GB)
      - name: Free disk space
        run: |
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL
          docker system prune -af --volumes
          df -h

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Harbor
        uses: docker/login-action@v3
        with:
          registry: ${{ env.HARBOR_HOST }}
          username: ${{ secrets.HARBOR_USERNAME }}
          password: ${{ secrets.HARBOR_PASSWORD }}

      - name: Get short SHA
        id: sha
        run: echo "tag=$(git rev-parse --short HEAD)" >> $GITHUB_OUTPUT

      - name: Build & push image
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: |
            ${{ env.HARBOR_HOST }}/${{ env.HARBOR_PROJECT }}/${{ env.IMAGE_NAME }}:${{ steps.sha.outputs.tag }}
            ${{ env.HARBOR_HOST }}/${{ env.HARBOR_PROJECT }}/${{ env.IMAGE_NAME }}:develop
          cache-from: type=registry,ref=${{ env.HARBOR_HOST }}/${{ env.HARBOR_PROJECT }}/${{ env.IMAGE_NAME }}:buildcache
          cache-to: type=registry,ref=${{ env.HARBOR_HOST }}/${{ env.HARBOR_PROJECT }}/${{ env.IMAGE_NAME }}:buildcache,mode=max

      - name: Setup kustomize
        uses: imranismail/setup-kustomize@v2
        with:
          kustomize-version: "5.4.3"

      - name: Bump tag in axis-infra (with retry)
        env:
          GH_TOKEN: ${{ secrets.INFRA_DISPATCH_PAT }}
          SHA: ${{ steps.sha.outputs.tag }}
          SVC: ${{ env.IMAGE_NAME }}
          HARBOR_HOST: ${{ env.HARBOR_HOST }}
          HARBOR_PROJECT: ${{ env.HARBOR_PROJECT }}
        run: |
          set -e
          for attempt in 1 2 3; do
            rm -rf infra
            # ★ C4: shallow=10 — git pull --rebase 가 base 찾을 수 있도록
            git clone --depth=10 -b develop \
              https://x-access-token:$GH_TOKEN@github.com/SKALA-AXis/axis-infra.git infra
            cd infra/k8s/overlays/skala

            BASE_NAME="REPLACE_ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/${SVC}"
            HARBOR_REF="${HARBOR_HOST}/${HARBOR_PROJECT}/${SVC}:${SHA}"
            kustomize edit set image "${BASE_NAME}=${HARBOR_REF}"

            cd ../../..
            git config user.email "ci@axis.local"
            git config user.name "axis-ci-bot"

            git add k8s/overlays/skala/kustomization.yaml
            git diff --cached --quiet && { echo "no change"; exit 0; }
            git commit -m "deploy: ${SVC} → ${SHA}"

            if git push origin develop; then
              echo "✓ pushed"; exit 0
            fi
            echo "push conflict — attempt $attempt/3, rebasing..."
            # depth=10 으로도 부족하면 unshallow
            git fetch --unshallow origin develop 2>/dev/null || git fetch origin develop
            git pull --rebase origin develop
            if git push origin develop; then
              echo "✓ pushed after rebase"; exit 0
            fi
            cd ..
            sleep $((attempt * 5))
          done
          echo "✗ failed after 3 attempts"; exit 1
```

각 service repo (axis-ai / axis-backend / axis-frontend) 에 위 yml 복사 + `IMAGE_NAME` 만 변경.

---

## 6. axis-infra 변경

### 6.1 `k8s/overlays/skala/kustomization.yaml` — Secret 분리

```diff
 resources:
   - ../../base
-  - secret.skala.yaml          # gitignored — ArgoCD 가 못 빌드함
   - postgres.yaml
   - qdrant.yaml
   - cronjob-pg-dump.yaml
   - networkpolicy-db.yaml
   - service-aliases.yaml
```

`secret.skala.yaml` 은 cluster 에 직접 1회 apply (Section 8).

### 6.2 ★ PVC prune 보호 (C2)

manifest 에서 PVC 가 빠지면 ArgoCD 가 prune → 데이터 손실. 3 PVC 매니페스트에 annotation:

```yaml
# postgres.yaml / qdrant.yaml / base/axis-images-pvc.yaml 의 PVC 에
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

### 6.3 ★ Secret prune 보호 (C2 동반)

```bash
kubectl annotate secret \
  axis-secrets axis-postgres-bootstrap harbor-creds \
  -n skala3-finalproj-class3-team13 \
  argocd.argoproj.io/sync-options=Prune=false --overwrite
```

`scripts/env-to-skala-secret.sh` 의 generated YAML 에 위 annotation 박아둠.

### 6.4 ★ axis-infra repo credential (C1 — private repo)

`k8s/argocd/repo-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: axis-infra-repo
  namespace: skala-argocd
  labels:
    # ★ ArgoCD 가 repo credential 로 인식하는 핵심 label
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  url: https://github.com/SKALA-AXis/axis-infra
  type: git
  # username: ArgoCD-bot (의미상)
  username: argocd
  # password: GitHub PAT (read 권한만 충분 — write 는 GH Actions 의 PAT)
  password: REPLACE_GITHUB_PAT_READ_ONLY
```

**적용**:
```bash
# 1) PAT 생성: GitHub Settings → Developer settings → Fine-grained tokens
#    repo: SKALA-AXis/axis-infra
#    permissions: contents=Read-only (write 불필요 — Application 만 pull)
# 2) repo-secret.yaml 에 PAT 값 채우고 apply
kubectl apply -f k8s/argocd/repo-secret.yaml
# 3) gitignored — git 에 커밋 X
```

`.gitignore` 에 추가:
```
k8s/argocd/repo-secret.yaml
```

### 6.5 `k8s/argocd/axis-application.yaml` — Application CR

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: axis-team13
  namespace: skala-argocd
  labels:
    team: team13
    app.kubernetes.io/part-of: axis
  finalizers:
    - resources-finalizer.argocd.argoproj.io
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
    automated:
      prune: true
      selfHeal: false
      allowEmpty: false
    syncOptions:
      - CreateNamespace=false
      - PrunePropagationPolicy=foreground
      - PruneLast=true
      - ServerSideApply=true
    retry:
      limit: 3
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m

  # ★ C3 — HPA 가 replicas 동적 변경 → ArgoCD 와 줄다리기 방지
  # ★ Secret stringData 외부 관리 → diff 무시
  ignoreDifferences:
    # 모든 Secret 의 stringData / data 무시 (외부 관리)
    - group: ''
      kind: Secret
      jsonPointers:
        - /stringData
        - /data
    # ★ HPA 대상 Deployment 의 replicas 무시
    - group: apps
      kind: Deployment
      name: axis-backend
      jsonPointers:
        - /spec/replicas
    - group: apps
      kind: Deployment
      name: axis-frontend
      jsonPointers:
        - /spec/replicas
```

**최초 등록**:
```bash
kubectl apply -f k8s/argocd/repo-secret.yaml      # 먼저 repo credential
kubectl apply -f k8s/argocd/axis-application.yaml  # 그 다음 Application
```

**검증**:
```bash
kubectl get applications.argoproj.io -n skala-argocd axis-team13 \
  -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
# 기대: Synced Healthy
```

---

## 7. ArgoCD UI 접속

```bash
# 외부 노출 확인
kubectl get svc -n skala-argocd | grep -i server

# 미노출 시 port-forward
kubectl port-forward -n skala-argocd svc/skala-argocd-server 8080:80
# 또는 svc/argocd-server (cluster 마다 다름 — 둘 다 시도)
# 브라우저: http://localhost:8080

# ★ C5 — admin 비밀번호 (cluster 확인됨: argocd-initial-admin-secret)
kubectl -n skala-argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

발표 시 demo: `argocd app sync axis-team13` 로 polling 기다리지 않고 즉시 sync 강제 가능.

---

## 8. Secret 관리 전략

### 8.1 현 단계 — 수동 apply + ignoreDifferences

```bash
cd axis-infra
$EDITOR .env                                            # 새 값 채움
make skala-secret                                       # secret.skala.yaml 생성 (gitignored)
kubectl apply -f k8s/overlays/skala/secret.skala.yaml   # 1회 또는 키 갱신 시
```

**팀원 공유**: 1Password / 이메일 PGP. Slack 폐기.

### 8.2 추후 (P8) — Sealed Secrets
SKALA 매니저에게 controller 설치 요청 후 `kubeseal` 로 git commit 가능.

---

## 9. GitHub Actions Secrets

### service repo 공통 (axis-ai / axis-backend / axis-frontend)

| Secret | 값 | 어디서 |
|---|---|---|
| `HARBOR_USERNAME` | `robot$skala26a-ai3+team13` | 매니저 발급 (완료) |
| `HARBOR_PASSWORD` | robot token | 매니저 발급 (완료) |
| `INFRA_DISPATCH_PAT` | fine-grained PAT, `SKALA-AXis/axis-infra` **contents: write** | 본인 GitHub Settings → Developer settings → Tokens |

### axis-infra

ArgoCD 가 cluster 내부에서 동작 → GH Actions 에 AWS / kubectl creds 0건. validate.yml 만 유지.

---

## 10. Phase 로드맵 (총 3.5일 core + 선택 2일)

| Phase | 기간 | 작업 | 검증 기준 |
|---|---|---|---|
| **P1 — axis-infra 준비** | 0.5일 | kustomization.yaml 정리 / 3 PVC 에 Prune=false / Secret prune 방지 annotation / Application CR + repo Secret yaml 작성 | manifest validate 통과 |
| **P2 — Build & Push** | 1일 | 3 service repo 에 build-and-push.yml (disk free + workflow_run + concurrency + amd64) + HARBOR_* secret 등록 | develop push → Harbor 새 SHA tag + buildcache |
| **P3 — Manifest 자동 commit** | 0.5일 | INFRA_DISPATCH_PAT 발급 + kustomize edit set image + shallow=10 + rebase retry | service push → axis-infra "deploy: ..." commit |
| **P4 — ArgoCD Application** | 0.5일 | repo-secret.yaml 먼저 apply, Application CR 등록 (project=default, selfHeal=false) | ArgoCD UI 에 axis-team13 Synced / Healthy |
| **P5 — E2E 검증** | 0.5일 | 한 service 변경 → push → 5-10분 후 자동 배포 + smoke curl /health | E2E 1 cycle PASS |
| **P6 — Rollback drill** | 0.5일 | git revert 후 ArgoCD 자동 복원 / `selfHeal: true` 로 전환 결정 | 5분 내 rollback |
| **P7 — 알림 (선택)** | 1일 | ArgoCD notifications → 이메일 (SMTP 기존 활용) | sync failed 시 이메일 |
| **P8 — 운영 강화 (선택, 발표 후)** | 1일 | Sealed Secrets / production overlay / main branch CD / 본인 AppProject 신청 | secret 도 GitOps |

> **폐기**: P0 (키 rotation — 사용자 결정으로 스킵)

---

## 11. 위험 / 운영

### 위험
1. ~~AppProject 발급 거절~~ — STALE (default 결정)
2. **자동 commit 의 git history 오염** — `deploy: ...` commit 이 develop 에 쏟아짐. squash merge 또는 별도 `gitops` 브랜치 검토 (P8)
3. **selfHeal 사고** — 디버그 시 ArgoCD 가 즉시 복원. 룰:
   ```bash
   # 디버그 전 (argocd CLI 설치 + login 필요)
   argocd app set axis-team13 --sync-policy none
   # 디버그 작업
   # 끝나면 manifest 반영 후
   argocd app set axis-team13 --sync-policy automated
   ```
4. **PAT 만료** — fine-grained PAT 1년 expiry. 캘린더 reminder
5. **race condition** — retry 로직으로 완화. concurrent push 잦으면 ApplicationSet 검토 (P8)
6. **GH Actions free minutes** — Org 가 private 면 월 2000분 한도. 한 달 ~3000-6000분 예상이라 빠듯. 필요시 self-hosted runner 또는 일시적 public 전환

### 잠재 위험 (모니터링)
- **W1: 첫 sync conflict** — 현재 cluster 에 이미 떠있는 Deployment 와 ArgoCD apply 충돌 가능. `ServerSideApply=true` 로 완화 (적용됨). 첫 sync watch 필수
- **W2: Application 의 `finalizers` cascade delete** — Application 삭제 시 모든 리소스 삭제. 발표 직전 finalizer 제거 검토:
  ```bash
  kubectl patch application axis-team13 -n skala-argocd \
    --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
  ```
- **W3: ConfigMap 변경 시 Pod 미재시작** — `axis-config` 갱신 시 자동 rollout X. 수동 `kubectl rollout restart` 필요. 또는 configMapGenerator + hash suffix 도입 (P8)
- **W4: Harbor 디스크 누적** — 매 commit 마다 SHA tag 누적. Harbor GC 정책 매니저 확인 (P8)

### 완화책
- branch protection (P6 후): develop merge PR review 1명 + CI 통과 필수 (bot push bypass 허용)
- ArgoCD `revisionHistoryLimit: 10` (기본)
- 발표 직전엔 `selfHeal: false` 유지 + 변경 동결

---

## 12. Rollback 절차

**1순위 — git revert** (GitOps 정통):
```bash
cd axis-infra
git revert <bad-commit-sha>
git push origin develop
# ArgoCD 3분 내 detect → auto-sync → 이전 image 로 복원
```

**2순위 — ArgoCD UI**:
- UI → axis-team13 → History → 이전 sync → "Rollback" 클릭 → ~30초

**3순위 — Emergency kubectl** (selfHeal: false 인 경우만 유효):
```bash
kubectl rollout undo deployment/axis-backend -n skala3-finalproj-class3-team13
# 직후 반드시 git revert 도 같이 (selfHeal: true 면 ArgoCD 가 다시 복원)
```

---

## 13. 발표 데모 시나리오

ArgoCD UI 가 시각적 어필 큼. 4 화면 같이:
1. 본인 Mac (코드 + 터미널)
2. GitHub Actions 페이지
3. ArgoCD UI (`http://localhost:8080` port-forward)
4. 배포된 axis frontend

**시연 흐름**:
1. axis-frontend 소문구 수정 → `git push origin develop`
2. Actions 로그: CI → build → push → axis-infra commit (~5분)
3. axis-infra 페이지: "deploy: axis-frontend → SHA" commit 등장
4. ArgoCD UI: 폴링 기다리기 싫으면 `argocd app sync axis-team13` 으로 즉시 트리거 (30초 단축)
5. UI 상태: `OutOfSync` → `Syncing` → `Synced` → `Healthy` 시각 변화
6. frontend hard reload → 변경 반영

→ "`git push` 한 번 으로 production deploy" GitOps 정통 시연.

---

## 14. 즉시 시작 — P1 체크리스트

1. **kustomization.yaml 에서 `secret.skala.yaml` 라인 제거**
2. **3 PVC manifest 에 `argocd.argoproj.io/sync-options: Prune=false` annotation** (postgres.yaml / qdrant.yaml / base/axis-images-pvc.yaml)
3. **3 Secret 에 prune 방지 annotation**:
   ```bash
   kubectl annotate secret axis-secrets axis-postgres-bootstrap harbor-creds \
     -n skala3-finalproj-class3-team13 \
     argocd.argoproj.io/sync-options=Prune=false --overwrite
   ```
4. **`scripts/env-to-skala-secret.sh` 갱신** — generated YAML 에 prune 방지 annotation 자동 박기
5. **`k8s/argocd/repo-secret.yaml` 작성** (gitignored, GitHub PAT read-only)
6. **`k8s/argocd/axis-application.yaml` 작성** (project=default, selfHeal=false, HPA replicas ignoreDifferences)
7. **`.gitignore` 갱신** — `k8s/argocd/repo-secret.yaml` 추가

P1 끝나면 P2 (build-and-push.yml 3 레포) 자동 진행 가능.

---

**v4 → v5 변경 요약** (5 critical + 5 medium + 3 minor):
1. C1 private repo credential Secret 추가
2. C2 PVC prune 보호 (postgres-data / qdrant-data / axis-images)
3. C3 HPA replicas ignoreDifferences
4. C4 shallow clone depth=10 + fetch --unshallow on rebase
5. C5 ArgoCD admin secret 이름 정정 (argocd-initial-admin-secret)
6. M1 cancel-in-progress=false 트레이드오프 명시
7. M2 redundant ignoreDifferences 정리
8. M3 GH Actions runner disk free-up step
9. M4 fetch-depth: 0 → 1
10. M5 phase total 3.5일 (선택 제외) / v5 일관성
11. m1 STALE risk #1 표시
12. m2 secret sharing 절차 명시 (1Password / PGP)
13. m3 demo 시 `argocd app sync` 즉시 트리거
14. ★ 신규 §4 브랜치 전략 (develop → main 이전 시나리오 A/B/C)
15. ★ 신규 W1-W4 잠재 위험 (첫 sync / finalizers / ConfigMap rollout / Harbor GC)
