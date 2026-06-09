# AXIS 인프라 지식베이스 (Notion 기록용)

> 팀13(AXIS) 프로젝트의 인프라를 분야별로 정리한 문서. 실제 레포(`axis-infra`, `axis-backend`, `axis-ai`, `axis-frontend`) 구성을 기준으로 작성.
>
> 최종 갱신: 2026-06-08

---

## 0. 한눈에 보기

| 항목 | 값 |
|---|---|
| 클라우드 | AWS EKS (SKALA 공용 클러스터), `ap-northeast-2` |
| 네임스페이스 | `skala3-finalproj-class3-team13` |
| 이미지 레지스트리 | Harbor `amdp-registry.skala-ai.com` / project `skala26a-ai3` |
| GitOps | ArgoCD (`skala-argocd` ns, app `axis-team13`), `develop` 브랜치 추적 |
| 공개 진입점 | `https://axis-team13.skala25a.project.skala-ai.com` (public-nginx + cert-manager TLS) |
| 공용 백킹스토어 | PostgreSQL(`postgres` in-ns), Qdrant(`qdrant` in-ns) |
| 관측성 | Langfuse Cloud SaaS (`LANGFUSE_*` in axis-secrets) |

### 서비스 구성

| 서비스 | 스택 | 포트 | 역할 |
|---|---|---|---|
| `axis-frontend` | React + Vite, nginx 정적 서빙 | 3000 | SPA. API 는 same-origin(`/api`)로 호출 |
| `axis-backend` | Spring Boot, Java 17 | 8080 | REST API, 인증, Flyway 마이그레이션, SES 메일 |
| `axis-ai` | FastAPI, Python 3.11 | 8001 | LLM 분석 파이프라인, 크롤러, BGE-M3 임베딩 |

리포 4개로 분리: 코드 3개(`axis-frontend/backend/ai`) + 인프라/계약 1개(`axis-infra`: K8s 매니페스트, OpenAPI, DB 스키마, ArgoCD/Helm).

---

## 1. Container (Docker)

3개 서비스 모두 **멀티스테이지 + 비루트 + 슬림 베이스** 원칙.

### axis-backend — `eclipse-temurin:17`
```dockerfile
FROM eclipse-temurin:17-jdk-jammy AS builder   # gradlew bootJar
FROM eclipse-temurin:17-jre-jammy              # 런타임은 JRE만
USER axis                                       # 비루트
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75","-jar","app.jar"]
```
- 의존성 레이어(`gradlew dependencies`)를 코드 복사 전에 분리 → 캐시 활용.
- `MaxRAMPercentage=75` 로 컨테이너 메모리 한도 기준 힙 자동 산정.

### axis-ai — `python:3.11-slim` + uv
- 의존성은 **uv + `uv.lock` 단일 진실원**. `uv export → uv pip install --system` 으로 venv 없이 설치.
- FlagEmbedding(torch ~2GB) 포함 → 빌드 ~5분. Playwright `chromium-headless-shell`(SPA IR 사이트 크롤링용) 추가 설치.
- `CMD ["uvicorn","src.api.main:app","--host","0.0.0.0","--port","8001"]`
- 같은 이미지를 CronJob entrypoint 로도 재사용(`python -m scripts.xxx`).

### axis-frontend — `node:20-alpine` → `nginx:alpine`
- `npm run build` 결과(`dist/`)를 nginx 로 서빙. `nginx.conf` 가 SPA fallback(`try_files ... /index.html`) 처리.
- **중요**: 빌드 시 `VITE_API_BASE_URL` 을 build-arg 로 주입하지 **않음** → 번들에 API URL 이 baked 되지 않고, `env.ts` 가 `window.location.origin`(same-origin)으로 폴백. 따라서 호스트/스킴(HTTP↔HTTPS) 변경에 프론트 재빌드 불필요.

---

## 2. CI (GitHub Actions)

리포별로 CI 가 분리되어 있고, 공통 패턴은 **`develop` push → 테스트 → 이미지 빌드/푸시 → infra 태그 bump**.

### 코드 리포 CI (`ci.yml`)

| 리포 | 트리거 | 검증 단계 |
|---|---|---|
| axis-backend | push/PR (main, develop) | `./gradlew build` → `./gradlew test` (JDK 17, gradle 캐시) |
| axis-ai | push/PR (main, develop, feat/**, fix/**) | `ruff format --check` → `ruff check` → `mypy src/` → `pytest tests/ -v` (uv) |
| axis-frontend | push/PR | 린트/빌드 (ci.yml) |

### 이미지 빌드/푸시 (`build-and-push.yml`) — 3 코드 리포 공통
1. 트리거: `CI` 워크플로가 **develop 에서 success** 한 직후 (`workflow_run`) 또는 수동.
2. 보안 가드: `workflow_run.event == 'push'` + `head_repository == 본 repo`(fork PR 차단).
3. Buildx 로 `linux/amd64` 빌드 → Harbor 에 `:<shortSHA>`, `:develop`, `:buildcache` 푸시(레지스트리 캐시 `mode=max`).
4. **GitOps bump**: `axis-infra` 를 clone → `kustomize edit set image <base>=<harbor>:<sha>` → `k8s/overlays/skala/kustomization.yaml` 커밋(`deploy: <svc> → <sha>`) → push. 충돌 시 rebase 재시도(최대 3회).

### axis-infra CI (`validate.yml`) — 계약/매니페스트 검증
- **gitleaks**: OSS CLI v8.21.2 (`--no-git`, `.gitleaks.toml` allowlist). `gitleaks-action@v2` 는 org repo 에 유료 라이선스 필요.
- **SQL**: `postgres:16` 서비스 컨테이너에 `db/schema.sql` 적용 → 스키마 유효성 검증.
- **OpenAPI**: `swagger-cli validate` 로 `api/openapi.yaml`, `api/ai-internal-api.yaml` 검증.
- **K8s 매니페스트**: `kubectl kustomize` 렌더 → `kubeconform -strict` 스키마 검증(base + overlays/local + **overlays/skala**).
- **API 스펙 변경 알림**: PR 에서 `api/*.yaml` 변경 시, 각 리포의 타입 재생성 명령을 PR 코멘트로 자동 안내.

---

## 3. CD / GitOps (ArgoCD)

### 파이프라인 전체 흐름
```
코드 push(develop) → CI 통과 → 이미지 Harbor push
   → axis-infra 의 kustomization.yaml image tag 자동 commit
   → ArgoCD 가 develop 변경 감지(3분 polling) → cluster sync
```

### ArgoCD Application (`k8s/argocd/axis-application.yaml`)
| 설정 | 값 | 의미 |
|---|---|---|
| 위치 | `skala-argocd` ns (매니저 운영 공용 인스턴스) | 팀이 직접 접근 불가, UI/CLI 로만 |
| source | `axis-infra`, `develop`, `path: k8s/overlays/skala` | overlay 하나가 배포 단위 |
| `automated.prune` | `true` | git 에 없는 리소스 제거(보호 annotation 예외) |
| `automated.selfHeal` | **`false`** | 디버그 중 ArgoCD 가 즉시 되돌리는 사고 방지 |
| syncOptions | `ServerSideApply`, `PruneLast`, `PrunePropagationPolicy=foreground`, `CreateNamespace=false` | |
| ignoreDifferences | Secret `/data`,`/stringData`; Deployment `/spec/replicas`(HPA) | 외부 관리 필드 diff 제외 |

> **실무 함의**: `develop` 에 머지되어야 클러스터에 반영됨. 클러스터에 직접 `kubectl apply`/`patch` 한 변경은 다음 sync 때 **git 기준으로 되돌려짐**. 따라서 영구 변경은 항상 PR → 머지.

### 보호 리소스 (Prune 제외)
`axis-secrets`, `axis-postgres-bootstrap`, `harbor-creds` Secret 과 PVC 3종(`postgres-data`, `qdrant-data`, `axis-images`)은 `argocd.argoproj.io/sync-options: Prune=false` 로 보호.

---

## 4. Kubernetes 리소스

`k8s/base` 에 전 리소스 정의, overlay 가 환경별로 패치.

### 워크로드 / 네트워크
- **Deployment 3종** + **Service 3종**(ClusterIP). 프론트 2, 백엔드 2, AI 1 replica.
- **HPA**: `axis-backend`, `axis-frontend` (replicas 는 ArgoCD ignoreDifferences 로 제외).
- **PVC `axis-images`**: 카드뉴스 이미지 저장용 RWX(EFS `efs-sc-shared`). backend·ai·pg-dump 가 공유.
- **Ingress**: §6 참조.

### Probe 설계 (axis-ai 안정화 교훈)
- 무거운 동기 작업이 FastAPI 이벤트 루프를 막아 **liveness probe 타임아웃 → 재시작** 되던 문제를, 경량 `/healthz` 엔드포인트 + `asyncio.to_thread()` 오프로딩으로 해결. 프로브는 `/healthz` 사용 + 타임아웃 완화.

### ResourceQuota (team13 네임스페이스)
pods 30, PVC 5, CPU req 8, mem req 16Gi, services 10 한도. PVC(5)가 가장 빠듯 — 신규 PVC 추가 시 주의.

### ReplicaSet 히스토리
세 Deployment 모두 `revisionHistoryLimit: 10` → 롤아웃마다 0-replica 옛 RS 가 최대 10개 보존(롤백용). ArgoCD UI 에 "RS 10개씩" 으로 보이는 건 정상이며 자원 소비 없음. 정리하려면 limit 를 3~5 로 낮춤.

---

## 5. Kustomize 구조

```
k8s/
├── base/                 # 전 리소스 단일 인덱스 (kustomization.yaml)
│   ├── *-deployment/service.yaml, ingress.yaml, configmap.yaml
│   ├── cronjob-*.yaml (11종), hpa-*, networkpolicy, serviceaccounts, pvc
└── overlays/
    ├── local/            # kind 로컬 (NodePort, pullPolicy: Never, secret.local)
    └── skala/            # SKALA EKS (ArgoCD 배포 대상)
        ├── kustomization.yaml   # 이미지→Harbor 치환, image tag, 패치 목록
        └── patches/
            ├── deployment-*.yaml      # pullPolicy, imagePullSecrets
            ├── configmap-env.yaml     # DATABASE_URL/Qdrant/URL 등 환경값
            ├── ingress-host.yaml      # host (JSON6902)
            ├── ingress-skala.yaml     # ingressClass/annotations/tls (JSON6902)
            └── pvc-images.yaml        # storageClass → efs-sc-shared
```
- **base/labels**: `app.kubernetes.io/part-of: axis` 공통 라벨 부여(`includeSelectors: false` 로 셀렉터 변형 방지).
- **이미지 치환**: kustomize `images:` 로 ECR placeholder(`REPLACE_ACCOUNT...`) → Harbor 경로 + `newTag`(CI 가 bump).
- **Secret 은 base resources 에 미포함**: 환경별 충돌 방지. cloud 는 `secret.skala.yaml`(gitignored)을 직접 apply, local 은 overlay 에서 추가.

---

## 6. Ingress & HTTPS

### 현재 구성 (공용 nginx + cert-manager)
| 항목 | 값 |
|---|---|
| ingressClass | `public-nginx` (공용 nginx Ingress Controller) |
| host | `axis-team13.skala25a.project.skala-ai.com` (플랫폼 와일드카드 도메인) |
| TLS | `cert-manager.io/cluster-issuer: letsencrypt-prod`, secret `axis-tls-cert` (HTTP-01 자동 발급/갱신) |
| 라우팅 | `/api`,`/actuator`,`/swagger-ui`,`/api-docs` → backend:8080 / `/` → frontend:3000 |

> **운영 도구 노출(의도적)**: class/dev 환경에서 API 명세·actuator 디버깅을 위해 공개 HTTPS 에 유지.
> 개선 옵션(운영 전환 시): (1) skala overlay 에서 `/actuator`·`/swagger-ui` path 제거,
> (2) nginx `auth-url` / basic-auth annotation 으로 IP·VPN·Basic Auth 추가,
> (3) Spring `springdoc.swagger-ui.enabled=false` + prod profile 분리,
> (4) 별도 internal host(`axis-team13-admin.*`) 로만 노출.

### ALB → nginx 전환 이력 (2026-05-29)
- 기존: AWS ALB Ingress(HTTP-only, ACM 미발급). HTTP 환경에서 refresh 쿠키 `Secure=true` 가 브라우저에서 거부 → **새로고침 시 로그인 풀림**.
- 전환: 도메인 구매 없이 플랫폼 공용 도메인 + cert-manager 로 무료 HTTPS. HTTPS 가 되며 `Secure` 쿠키 정상 동작 → 세션 유지. (team5/team6 검증 패턴)
- 부수효과: 프론트는 same-origin 이라 재빌드 불필요, 쿠키 설정 변경 불필요.

---

## 7. CronJobs (스케줄러)

모든 크론 `timeZone: Asia/Seoul`, `concurrencyPolicy: Forbid`, history limit 3.

| CronJob | 스케줄(KST) | 실행 | 비고 |
|---|---|---|---|
| ingestion-a | 매시 | curl backend `/api/pipeline/trigger?track=A` | 수집 |
| ingestion-b / b-midday / b-close | 평일 09:30 / 13:00 / 18:00 | backend 트리거 | 장중/마감 |
| ingestion-c | 08:30, 17:30 | backend 트리거 | |
| ingestion-d | 03:30 | backend 트리거 track=D | |
| delivery | 평일 08:30 | 일일 브리핑 메일 발송 | |
| card-evaluator | 5분마다 | `axis-ai-cron` 이미지로 LLM-as-Judge | Playwright/torch 제외 |
| global-trend | 월 02:30 | curl axis-ai `/global/trends/run` (retry-connrefused) | LLM |
| profile-refresh | 분기 1/4/7/10 03:00 | axis-ai `refresh_peer_profile_snapshots.py` | PYTHONPATH=/app |
| sector-pulse | 월 02:00 | psql REFRESH MV (retry + CONCURRENTLY 폴백) | |
| capability-evolution | 매월 1일 03:00 | **suspend: true** (스크립트 미구현) | 수동 `diag-*` Job 금지 |
| weak-signal | 월 09:00 | suspend: true | |
| **pg-dump** | 매일 **05:40 KST** (UTC 20:40) | DB 백업 → `axis-images` PVC + S3 `axis-team13-backups/pg/` | §11 백업 |

> **호출형 cron resilience (2026-06)**: ingestion/global-trend/delivery/weak-signal 은 curl `--retry-connrefused` + `CRON_INTERNAL_TOKEN optional:true`. sector-pulse 는 psql 재시도 루프.

---

## 8. 네트워킹 & 보안

### PodDisruptionBudget
- `axis-backend-pdb` / `axis-frontend-pdb`: `minAvailable: 1` — 노드 drain·클러스터 업그레이드 시 최소 1 Pod 유지.
- axis-ai 는 replicas=1 이라 PDB 효과 제한적(의도적 단일 replica).

### NetworkPolicy (`networkpolicy.yaml`)
- **default-deny ingress** + 명시적 allow. egress 는 전체 허용(외부 SaaS: OpenAI/DART/Naver/SES 등).
- frontend/backend ← **`public-nginx`** + legacy `kube-system`(ALB) ingress controller.
- backend ← cron pods, **ai ← backend + cron**(global-trend 직접 호출).
- 전제: NetworkPolicy 지원 CNI 활성 시에만 enforce. SKALA 기본 VPC CNI 는 미지원일 수 있음 — 매니페스트는 CNI 활성화 대비용.

### Cron 내부 인증
- CronJob → backend `/api/pipeline/trigger|delivery` 는 `Authorization: Bearer ${CRON_INTERNAL_TOKEN}`.
- **prod(profile=prod)**: `axis.scheduler.cron-auth-required=true` — 토큰 미설정 시 **401 fail-closed**.
- local: 토큰 없어도 허용(개발 편의). 클러스터 `axis-secrets` 에 64B 토큰 적용됨(2026-06-08).

### Secret 관리
- `axis-secrets`(앱 환경 비밀), `harbor-creds`, `axis-postgres-bootstrap`.
- gitignored `.env` → `scripts/env-to-skala-secret.sh` → `make skala-secret` → 클러스터 merge-patch/apply. ArgoCD 는 Secret diff ignore.
- JWT 키 이름: **`AXIS_AUTH_JWT_SECRET`** (backend `application.yml`). `JWT_SECRET` 은 legacy·**클러스터에서 제거 권장** (`scripts/remove-legacy-jwt-secret-key.sh`).
- ⚠ `kustomize` 렌더 산출물(`json` 등)은 `.gitignore` — 실 secret 포함 가능.

### ServiceAccount / IRSA
- 워크로드별 SA: `axis-frontend-sa`, `axis-backend-sa`, `axis-ai-sa`, `axis-cron-sa`.
- 이메일: **AWS SES V2 + IRSA** (`ses-mailer-sa`) — SMTP 없이 API 직접 호출.
- 백업: **S3 pg dump + IRSA** (`axis-backup-sa`) — `s3://axis-team13-backups/pg/`. `scripts/provision-backup-s3.sh` 1회.

### axis-ai replicas=1 (×2 금지)
- `axis-images` PVC(RWX)에 **동시 write race** — ai-deployment.yaml 주석으로 ×2 명시 금지.
- `model-cache` = `emptyDir` → 재시작마다 BGE-M3 **1~3분 콜드스타트** (~5Gi mem ×2 = quota 압박).
- `maxSurge:0` → 롤아웃 시 완전 다운타임. 완화: cron curl 재시도(#44), 중기 HF cache PVC(RWX) 또는 backend 프록시.

## 9. 설정 (ConfigMap `axis-config`)
주요 키:
- `AI_SERVER_URL: http://axis-ai:8001`, `QDRANT_HOST/PORT`
- `AXIS_APP_BASE_URL: https://axis-team13.skala25a.project.skala-ai.com` (이메일 인증 링크)
- `SPRING_PROFILES_ACTIVE: prod`, `SPRING_JPA_HIBERNATE_DDL_AUTO: validate`(entity↔DB 정합성 부팅 검증; Flyway 가 스키마 변경)
- `AXIS_SCHEDULER_ENABLED: false` — Spring `@Scheduled` 끔. **트리거는 CronJob 단일화**(과거 이중 발송 버그 방지).
- LLM 비용 제어: `ENABLE_RELEVANCE_LLM`, 배치 크기/최대 배치 수 제한.

---

## 10. 관측성 — Langfuse

- **Langfuse Cloud SaaS** (`LANGFUSE_HOST` / `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` in axis-secrets).
- self-host Helm(`k8s/argocd/langfuse-application.yaml`) 은 레거시 참조 — 2026-05-14 Cloud 전환(PVC quota·chart v2/v3 이슈).
- axis-ai 가 LLM trace/cost 푸시.

---

## 11. 데이터베이스 & 마이그레이션

- **Flyway**: backend 가 기동 시 `src/main/resources/db/migration/V*.sql` 자동 적용(현재 ~V39). `DDL_AUTO=validate` 로 entity↔DB drift 시 **부팅 실패**(의도). 스키마 변경은 Flyway 단일 관리.
- **CI 검증 (2단)**: ① `axis-infra` CI — `db/schema.sql` 적용 가능 여부. ② `axis-backend` CI `PostgreSqlSchemaValidationIT` — Flyway migrate 후 Hibernate `validate` 부팅. skala overlay 에 `update/create` 금지 grep.
- **선언적 스키마**: `axis-infra/db/schema.sql` + `schema.dbml` 을 진실원으로 두고 CI 가 검증. (마이그레이션과 선언 스키마 정합성 유지 필요 — 예: CHECK 제약)
- ⚠ **버전 충돌 주의**: 기능 브랜치가 오래 분기되면 같은 `Vnn` 번호가 둘이 되어 Flyway 가 기동 실패(`more than one migration with version`). 머지 전 배포된 최고 버전 위로 재넘버링 필요.
- **백업**: `axis-pg-dump` CronJob — **KST 05:40**(UTC 20:40), `axis-images` PVC `/data/backups` + **S3** `s3://axis-team13-backups/pg/` (IRSA `axis-backup-sa`, 14일 lifecycle). per-pod deadline 600s + backoff 3.

---

## 12. 운영 플레이북 / 트러블슈팅 이력

최근 인프라 관점에서 처리한 이슈들(재발 시 참고).

| 증상 | 근본 원인 | 해결 |
|---|---|---|
| axis-ai 잦은 재시작(exit 137 의심) | OOM 이 아니라 **동기 CPU 작업이 이벤트 루프 차단 → liveness 타임아웃** | 경량 `/healthz` + `asyncio.to_thread()`, 프로브 완화, BGE-M3 배치/`max_length`/프리로드 튜닝 |
| pg-dump degraded(`DeadlineExceeded`) | 공유 EFS PVC I/O 경합(피크 시간) | 스케줄 한산 시간대 이동 + `activeDeadlineSeconds` 상향 |
| 새로고침 시 로그인 풀림 | HTTP-only ALB 에서 `Secure` refresh 쿠키 거부 | HTTPS 전환(공용 nginx + cert-manager) — §6 |
| sector-pulse 한 번도 성공 못함 | `secretKeyRef: axis-secrets/POSTGRES_URL` **키 부재** → 파드 기동 실패 | 실재하는 `DATABASE_URL`(libpq) 키로 교체 |
| profile-refresh 한 번도 성공 못함 | `python scripts/x.py` 에서 `import src` 실패(PYTHONPATH 부재) | 크론에 `PYTHONPATH=/app` 추가 |
| global-trend / ingestion Degraded | axis-ai 콜드스타트·단일 replica 다운타임 / cron curl 재시도 없음 | PR #44: curl `--retry-connrefused`, ingestion optional secret |
| sector-pulse 실패 | psql 일시 연결거부 / MV edge | PR #45: psql 재시도 + CONCURRENTLY→blocking 폴백 |
| capability-evolution Degraded | `refresh_capability_evolution.py` **미구현** | PR #46: CronJob suspend |
| CRON 토큰 우회 | backend fail-open(빈 토큰=허용) | prod `cron-auth-required=true` fail-closed (2026-06) |
| JWT 키 이름 혼동 | 예시 `JWT_SECRET` vs backend `AXIS_AUTH_JWT_SECRET` | 예시/스크립트 통일 + legacy 키 클러스터 제거 |
| card-evaluator 6GB pull | full axis-ai 이미지(Playwright/torch) 재사용 | `axis-ai-cron` 슬림 이미지 + 리소스 하향 |
| gitleaks 미적용 | CI secret scan 없음 | OSS gitleaks CLI (`--no-git`) |
| diag-cap Degraded | suspend CronJob 에서 수동 `kubectl create job` | Job 삭제 + notifier가 `diag-*` 제외 |
| ArgoCD UI RS 10개씩 | `revisionHistoryLimit: 10` 의 0-replica 히스토리 | 정상. 필요 시 limit 하향 |

### GitOps 디버깅 체크리스트
1. 클러스터 실제 상태: `kubectl -n <ns> get <res>` / `describe` / `logs`
2. degraded 크론 판별: `lastScheduleTime > lastSuccessfulTime` 인 CronJob 탐색
3. 영구 수정은 반드시 `axis-infra` PR → develop 머지(직접 apply 는 sync 때 롤백됨)
4. 검증 후 `kubectl kustomize k8s/overlays/skala` 로 렌더 확인

---

## 13. 비용 관점

- LLM 호출 크론(global-trend, profile-refresh, capability-evolution, 카드뉴스 생성)이 비용 주요인.
- 카드뉴스 생성 파이프라인은 비용 이슈로 상시 자동화 대신 **주기적 수동 트리거** 운용 중(가변).
- 관련 가드: ConfigMap 의 `ENABLE_RELEVANCE_LLM`, 배치 상한, 일부 크론 `suspend`.

---

## 부록 — 자주 쓰는 명령

```bash
# 상태
kubectl -n skala3-finalproj-class3-team13 get pods,svc,ingress,cronjob

# overlay 렌더 검증 (CI 와 동일)
kubectl kustomize k8s/overlays/skala | kubeconform -strict -summary

# 로컬 kind 전체 기동
make local-up

# SKALA 수동 배포 흐름 (보통은 ArgoCD 자동)
make skala-build && make skala-push && make skala-apply

# degraded 크론 마지막 성공시각 점검
kubectl -n <ns> get cronjobs -o json | jq -r '.items[]|[.metadata.name,.status.lastScheduleTime,.status.lastSuccessfulTime]|@tsv'
```
