# axis-infra 인프라 및 운영 설계 문서

## 문서 메타

- 문서 기준일: 2026-06-09
- 범위: `k8s`, `api`, `db`, `scripts`, `docs`, `docker-compose*.yml`
- 작성자/작업일 산정 방식: GitLens와 동일하게 커밋 이력(`git log`) 기준으로 인프라 기능의 핵심 manifest, contract, script 파일별 주요 작성자와 작업 기간을 추출했다.

| 기능 | 담당자(커밋 수 기준) | 작업 기간 | 최근 커밋 |
|---|---:|---|---|
| OpenAPI 계약 | jiwon, Toucan, jin, ickell | 2026-04-21 ~ 2026-06-09 | 2026-06-09 ickell `6bcfe31` |
| DB Schema 계약 | Toucan, jiwon/jiwonij, jin | 2026-04-21 ~ 2026-05-29 | 2026-05-29 jiwonij `5ed09a1` |
| Frontend/Backend/AI Workloads | ickell, Toucan, jiwon | 2026-05-04 ~ 2026-06-09 | 2026-06-09 jiwon `678d92e` |
| 수집/배송 CronJob | ickell, jiwon, Toucan | 2026-05-04 ~ 2026-06-09 | 2026-06-09 ickell `f9dbdcb` |
| 분석/운영 CronJob | ickell, Toucan, jiwon | 2026-05-21 ~ 2026-06-09 | 2026-06-09 Toucan `70a4bf2` |
| Security/Ingress/Availability | ickell, Toucan | 2026-05-04 ~ 2026-06-08 | 2026-06-08 ickell `bd6bb6d` |
| Overlay/ArgoCD 배포 | axis-ci-bot(자동), Toucan, ickell | 2026-05-04 ~ 2026-06-09 | 2026-06-09 axis-ci-bot `f3ddd88` |
| Local Compose | Toucan, ickell, jin | 2026-04-21 ~ 2026-06-09 | 2026-06-09 Toucan `70a4bf2` |
| Secret/Backup/Ops Scripts | ickell, Toucan, jiwon | 2026-05-04 ~ 2026-06-09 | 2026-06-09 ickell `f9dbdcb` |
| 운영 문서/ADR | Toucan, ickell, jiwon | 2026-04-21 ~ 2026-06-08 | 2026-06-08 ickell `bd6bb6d` |

## 전체 설계 의도

`axis-infra`는 AXIS의 실행 환경, 배포 리소스, API 계약, DB 스키마 기준, 운영 문서를 관리한다. 애플리케이션 코드는 `axis-frontend`, `axis-backend`, `axis-ai`에 있고, 이 레포는 세 서비스를 하나의 시스템으로 묶는 계약과 운영 제어면을 제공한다.

핵심 의도는 다음과 같다.

- 프론트/백엔드/AI의 배포 경계를 명확히 분리한다.
- PostgreSQL과 Qdrant를 공통 데이터 저장소로 두고, 앱별 접근 권한과 네트워크 경로를 제한한다.
- 수집/분석/브리핑/백업 같은 반복 작업은 K8s CronJob으로 운영한다.
- OpenAPI와 DBML/SQL을 팀 간 계약 문서로 유지한다.

## 전체 배포 흐름

```text
GitHub Actions / CI
→ ECR image push
→ axis-infra image tag update
→ kustomize overlay
→ ArgoCD apply
→ Kubernetes namespace skala3-finalproj-class3-team13
→ frontend / backend / ai / cronjobs / postgres / qdrant
```

## `k8s/base`

### 목적

환경과 무관한 공통 Kubernetes 리소스의 기준이다. Deployment, Service, HPA, PDB, CronJob, NetworkPolicy, Ingress, ConfigMap, ServiceAccount를 정의한다.

### 주요 리소스

| 리소스 | 목적 | 입력 | 출력/효과 |
|---|---|---|---|
| `frontend-deployment.yaml` | React/Vite 빌드 결과를 서비스 | image tag, API base URL | 웹 UI Pod |
| `frontend-service.yaml` | frontend 내부 Service | Pod selector | HTTP service |
| `backend-deployment.yaml` | Spring Boot API 서버 | DB/AI/env secrets | `/api/**`, `/health` |
| `backend-service.yaml` | backend 내부 Service | Pod selector | `axis-backend:8080` |
| `ai-deployment.yaml` | FastAPI AI 서버 | DB/Qdrant/OpenAI/API keys | `/pipeline`, `/mixer`, `/chat` 등 |
| `ai-service.yaml` | AI 내부 Service | Pod selector | `axis-ai:8001` |
| `ingress.yaml` | 외부 HTTP(S) 진입 | host/path | frontend/backend 라우팅 |
| `networkpolicy.yaml` | Pod 간 접근 제한 | namespace/pod labels | 서비스 통신 제어 |
| `axis-images-pvc.yaml` | 카드 이미지 공유 저장소 | PVC | AI write, backend read |
| `pdb-*.yaml` | drain 중 최소 가용성 | replicas | 무중단성 개선 |
| `hpa-*.yaml` | frontend/backend autoscaling | CPU/memory metric | scale out/in |

### 서비스별 설계

| 서비스 | Replica | Probe | 리소스 | 설계 포인트 |
|---|---:|---|---|---|
| frontend | HPA 대상 | HTTP | 경량 | 정적 UI, backend API 호출 |
| backend | 기본 2 | `/health` | Java 17, 1~2Gi | 외부 API 계약, AI 프록시, DB read/write |
| axis-ai | 1 | `/healthz` | 5~8Gi | BGE-M3/LLM client, Qdrant/DB, 이미지 write; 동시 2 Pod 금지 |

`axis-ai`는 모델 메모리와 공유 PVC write race를 고려해 단일 replica로 설계되어 있다. `/healthz`는 DB/Qdrant를 호출하지 않는 경량 probe이고, `/health`는 상세 진단용이다.

## `k8s/base` CronJob

### 목적

수집, 분석 보조, 브리핑, 백업/알림 등 반복 작업을 애플리케이션 Pod와 분리해 운영한다.

| CronJob | Schedule(KST) | 호출/실행 대상 | 목적 | 연결 앱 |
|---|---:|---|---|---|
| `axis-cron-ingestion-a` | 매시 정각 | backend `/api/pipeline/trigger?track=A` | 뉴스/공식 소스 고빈도 수집 | backend → axis-ai |
| `axis-cron-ingestion-b` | 평일 09:30, 13:00, 18:00 | backend track B | 시장/증권 리포트 수집 | backend → axis-ai |
| `axis-cron-ingestion-c` | 매일 08:30, 17:30 | backend track C | 채용/회사 공식 자료 수집 | backend → axis-ai |
| `axis-cron-ingestion-d` | 매일 03:30 | backend track D | DART/IR/search/trend 자료 수집 | backend → axis-ai |
| `axis-cron-delivery` | 평일 08:30 | backend `/api/pipeline/delivery` | 일일 브리핑 발송 | backend + SES |
| `axis-cron-global-trend` | 월요일 02:30 | axis-ai `/global/trends/run` | 글로벌 IT 트렌드 갱신 | axis-ai |
| `axis-cron-profile-refresh` | 분기 첫 달 1일 03:00 | `scripts/refresh_peer_profile_snapshots.py` | 피어 프로필 snapshot 갱신 | axis-ai |
| `axis-cron-card-evaluator` | 매일 22:30 | `scripts.evaluate_recent_cards` | 카드 LLM judge/evaluation | axis-ai-cron |
| `axis-cron-sector-pulse` | 월요일 02:00 | psql/materialized view refresh | 섹터 pulse 갱신 | PostgreSQL |
| `axis-cron-capability-evolution` | 매월 1일 03:00 | `scripts/refresh_capability_evolution.py` | 역량 변화 context 갱신 | axis-ai |
| `axis-cron-failure-notifier` | 10분마다 | kubectl + Slack webhook | CronJob 실패 알림 | K8s API/Slack |

### CronJob 데이터 흐름

```text
CronJob curl
→ axis-backend /api/pipeline/trigger
→ AiClientService.triggerPipeline
→ axis-ai /pipeline/run
→ crawler/preprocessing/analysis
→ PostgreSQL + Qdrant + image PVC
→ frontend/backend read APIs
```

브리핑은 별도 흐름이다.

```text
axis-cron-delivery
→ axis-backend /api/pipeline/delivery
→ BriefingService.generateAndSend
→ CardNewsService.getTodayCards
→ SES email
```

## `k8s/overlays`

### 목적

환경별 차이를 base 위에 patch한다. 로컬/kind, SKALA 운영 환경, ArgoCD self 관리 구성이 분리되어 있다.

| Overlay | 목적 | 주요 입력 |
|---|---|---|
| `overlays/local` | 로컬 kind/kustomize 실행 | local postgres/qdrant, local secret example |
| `overlays/skala` | SKALA 운영 배포 | 운영 ingress, secret example, postgres/qdrant service, image PVC |
| `argocd` | ArgoCD Application | repo/path/revision |
| `argocd-self` | ArgoCD 자체 값 관리 | chart values |

`axis-ci-bot` 커밋은 주로 image tag 배포 자동화 이력이다. 설계 담당자 산정 시 운영 자동화 커밋과 수동 설계 커밋을 구분해 보는 것이 좋다.

## `api`

### 목적

프론트-백엔드, 백엔드-AI 간 API 계약을 관리한다.

| 파일 | 목적 | 소비자 |
|---|---|---|
| `openapi.yaml` | Frontend → Spring Boot REST API 계약 | frontend, backend smoke test, 문서 |
| `ai-internal-api.yaml` | Spring Boot → axis-ai 내부 API 계약 | backend `AiClientService`, axis-ai |
| `openapi copy.yaml` | 과거/복사본 계약 | deprecated 후보 |

### API 데이터 흐름

```text
api/openapi.yaml
→ backend Controller path/response alignment
→ frontend repository path/type alignment
→ smoke/contract test
```

AI 내부 API는 외부 프론트에 직접 노출하지 않고 backend가 프록시한다.

```text
frontend /api/mixer
→ backend MixerController
→ ai-internal-api contract
→ axis-ai /mixer/analyze
```

## `db`

### 목적

PostgreSQL schema의 참조 기준이다. `schema.sql`은 로컬 compose 초기화와 스키마 검토에 사용되고, `schema.dbml`은 ERD/문서화에 사용된다. 실제 애플리케이션 마이그레이션은 `axis-backend`의 Flyway가 기준이다.

### 주요 데이터 그룹

| 그룹 | 테이블 예시 | 생산자 | 소비자 |
|---|---|---|---|
| Peer master | `peer_companies` | migration/admin | backend, axis-ai |
| 원문 | `raw_articles`, `crawl_runs`, `crawl_run_articles` | axis-ai crawler | preprocessing, backend Raw/Card APIs |
| 파싱/신호 | `raw_article_parse_results`, `raw_article_financial_metrics`, `raw_article_business_signals` | parsers/extractors | Peer+, profile, analysis context |
| 카드/이슈 | `integrated_issues`, `card_news`, `analysis_ledger` | axis-ai agents | backend/frontend |
| 사용자 | `users`, `auth_tokens`, `user_settings`, `user_access_logs` | backend | auth/settings/admin |
| 알림/북마크 | `user_notifications`, `user_card_news_bookmarks` | backend/notification logic | frontend |
| 운영/브리핑 | `briefing_reports`, `today_insight_reports`, `admin_audit_logs` | backend/axis-ai | dashboards/admin |

## `docker-compose`

### 목적

로컬/클라우드 개발 실행을 제공한다. 기본은 외부 PostgreSQL/Qdrant를 바라보는 cloud 모드이고, `local` profile에서 Postgres/Qdrant 컨테이너를 함께 띄운다.

### 로컬 데이터 흐름

```text
frontend:3000
→ backend:8080
→ ai:8001
→ postgres:5432
→ qdrant:6333
```

이미지는 `axis-images` 볼륨을 공유한다.

```text
axis-ai writes /data/images
→ axis-images volume
→ axis-backend reads /data/images read-only
→ frontend receives image URL
```

## `scripts`

### 목적

Secret 생성, 백업/복구, 진단 cleanup 등 운영 보조 작업을 제공한다.

| 스크립트 | 목적 |
|---|---|
| `env-to-secret.sh`, `env-to-skala-secret.sh` | `.env` 값을 K8s Secret manifest로 변환 |
| `remove-legacy-jwt-secret-key.sh` | 구 JWT secret key 정리 |
| `provision-backup-s3.sh` | PostgreSQL dump S3 버킷/권한 준비 |
| `cleanup-diag-jobs.sh` | 진단 Job cleanup |

## 연결된 에이전트/백엔드/프론트

| Infra 요소 | 연결된 앱 로직 | 연결된 AI/DB |
|---|---|---|
| `axis-cron-ingestion-*` | Backend `PipelineController.trigger` | axis-ai crawler/preprocessing/pipeline, PostgreSQL, Qdrant |
| `axis-cron-global-trend` | Backend/Frontend Global Trends read API | `ITTrendAgent`, global trend tables |
| `axis-cron-profile-refresh` | Peer+ / analysis context | `PeerProfileAgent`, `peer_companies.profile_snapshot` |
| `axis-cron-card-evaluator` | 카드 품질/관리자 검수 | card evaluation payload |
| `axis-cron-delivery` | `BriefingService.generateAndSend` | `card_news`, AWS SES |
| `axis-images` PVC | Backend image serving, frontend cards | axis-ai image writer |
| `openapi.yaml` | frontend repository, backend controller | API contract |
| `schema.sql/dbml` | backend/AI DB alignment | PostgreSQL |

## 운영 주의사항

- `axis-ai`는 단일 replica가 기본이다. 모델 메모리와 이미지 PVC write 충돌을 고려해 임의 scale-out을 피한다.
- Qdrant는 v1.9.4로 pin되어 있다. PVC segment format 호환성 때문에 버전 업그레이드는 별도 마이그레이션 검토가 필요하다.
- CronJob은 `concurrencyPolicy: Forbid`로 중복 실행을 줄인다. 그래도 backend 내부 `@Scheduled`와 K8s CronJob 중복 여부는 운영 profile에서 확인해야 한다.
- Secret은 base resources에 직접 포함하지 않는다. 환경별 overlay 또는 수동 Secret 적용으로 충돌을 피한다.
- OpenAPI와 실제 backend controller가 어긋나면 frontend repository 타입과 런타임 오류가 동시에 발생한다. API 변경은 `api/openapi.yaml`, backend smoke test, frontend repository를 함께 수정한다.
