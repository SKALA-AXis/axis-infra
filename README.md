# AXIS — AX Intelligence Signal

AXIS는 Peer사(삼성SDS·LG CNS·현대오토에버·포스코DX)의 전략적 변화를 자동 감지하여, SK AX 관점의 시사점 초안까지 제공하는 전략기획 담당자용 AI 브리핑 시스템입니다. 뉴스·공시·채용공고를 자동 수집하고 LangGraph 기반 AI 파이프라인이 동향 카드를 생성해 매일 오전 이메일로 전달합니다.

이 레포(`axis-infra`)는 **4개 레포를 묶는 단일 기준(Single Source of Truth)**이자 **로컬 풀스택 실행의 오케스트레이션 허브**입니다.

```
React (frontend :3000)  ──REST──→  Spring Boot (backend :8080)  ──HTTP 내부──→  Python AI (FastAPI :8001)
                                          │                                          │
                                   PostgreSQL :5432 (원문 전량)            Qdrant :6333 (벡터)
```

---

## 1. 빠른 시작 — 완전 로컬 실행 (클러스터·팀 시크릿 불필요)

> **평가자/처음 받는 분은 이 섹션만 보면 됩니다.** SKALA EKS 접근 권한이나 팀 비밀값 없이, 로컬 Docker만으로 전체 스택(DB·벡터DB·backend·ai·frontend)이 뜹니다.

### 1-1. 사전 요구사항

| 도구 | 버전 | 비고 |
|---|---|---|
| Docker + Docker Compose v2 | 최신 | `docker compose version` 으로 v2 확인 (`docker-compose` 아님) |
| git | 최신 | 4개 레포 clone |
| (호스트 직접 실행 시) JDK | **17** | backend — [axis-backend/README](https://github.com/SKALA-AXis/axis-backend) |
| (호스트 직접 실행 시) Python | **3.11** + [uv](https://docs.astral.sh/uv/) | ai — [axis-ai/README](https://github.com/SKALA-AXis/axis-ai) |
| (호스트 직접 실행 시) Node.js | **20+** | frontend — [axis-frontend/README](https://github.com/SKALA-AXis/axis-frontend) |

> Docker compose 경로만 쓰면 JDK/Python/Node는 컨테이너가 처리하므로 호스트에 설치 불필요.

### 1-2. 레포 배치 — 4개를 **형제 디렉토리**로

`docker-compose.yml`은 `../axis-backend`, `../axis-ai`, `../axis-frontend`를 빌드 컨텍스트로 사용합니다. 반드시 같은 부모 폴더 아래에 나란히 두세요.

```bash
mkdir axis && cd axis
git clone https://github.com/SKALA-AXis/axis-infra.git
git clone https://github.com/SKALA-AXis/axis-backend.git
git clone https://github.com/SKALA-AXis/axis-ai.git
git clone https://github.com/SKALA-AXis/axis-frontend.git
# 결과 레이아웃:
# axis/
# ├── axis-infra/      ← 여기서 docker compose 실행
# ├── axis-backend/
# ├── axis-ai/
# └── axis-frontend/
```

### 1-3. 환경변수 파일 생성

```bash
cd axis-infra
cp .env.local.example .env          # .env 는 git-ignore 됨 (절대 커밋 금지)
```

그다음 `.env`를 열어 최소 한 줄만 채우면 됩니다:

```bash
OPENAI_API_KEY=sk-...               # AI 카드 생성·요약·챗봇·시맨틱 검색에 필요
```

나머지(DB 계정/포트, JWT 시크릿 등)는 로컬 기본값이 그대로 들어 있어 수정 없이 동작합니다. 변수별 상세는 [2. 환경변수](#2-환경변수)를 보세요.

### 1-4. 실행

```bash
docker compose --profile local up -d --build
```

- `--profile local` : 로컬 `postgres` + `qdrant` 컨테이너까지 함께 기동 (이게 없으면 DB가 안 뜹니다)
- `--build` : sibling 레포에서 이미지 빌드 (**최초 1회는 ai 이미지가 torch/FlagEmbedding 때문에 5~10분** 소요)
- 최초 기동 시 ai 컨테이너가 임베딩 모델(BGE-M3)을 내려받느라 몇 분 더 걸립니다 — `docker compose logs -f ai`로 진행 확인

### 1-5. 접속 & 상태 확인

| URL | 서비스 |
|---|---|
| http://localhost:3000 | **프론트엔드 대시보드** (여기서 시작) |
| http://localhost:8080/swagger-ui | Backend Swagger UI |
| http://localhost:8080/health | Backend 헬스 |
| http://localhost:8001/health | AI 서버 헬스 |

```bash
docker compose ps                 # 컨테이너 healthy 확인
docker compose logs -f backend    # 로그 추적
```

### 1-6. 로컬 로그인 (이메일/SES 없이)

로컬 프로파일은 `AXIS_AUTH_EMAIL_VERIFICATION_DELIVERY=log`, `AXIS_AUTH_ALLOWED_EMAIL_DOMAINS=*` 이므로:

1. 대시보드(http://localhost:3000)에서 아무 이메일로 **회원가입**
2. 인증 메일이 실제로 발송되는 대신 **backend 로그에 인증 링크가 출력**됩니다
   ```bash
   docker compose logs backend | grep -iE "verif|인증"
   ```
3. 그 링크로 인증 → 로그인

### 1-7. 데이터에 관하여 (중요)

로컬 DB는 `db/schema.sql`로 **스키마만** 초기화되고 **데이터는 비어 있습니다.** 화면을 데이터로 채우는 방법:

- **수집 파이프라인 실행** — 뉴스/공시/채용 크롤러가 동작하려면 크롤러 API 키(NAVER/DART 등, [2. 환경변수](#2-환경변수))가 필요합니다. 키가 있으면:
  ```bash
  curl -X POST http://localhost:8080/api/pipeline/trigger \
       -H "Authorization: Bearer local-dev-cron-token"   # .env 의 CRON_INTERNAL_TOKEN 값
  ```
- 키가 없으면 앱은 정상 기동하지만 대시보드는 빈 상태입니다(인증·화면·API 동작 자체는 확인 가능).

### 1-8. 종료

```bash
docker compose --profile local down          # 컨테이너 정지/삭제 (데이터 볼륨 유지)
docker compose --profile local down -v       # 볼륨까지 삭제 (DB 초기화)
```

---

## 2. 환경변수

`cp .env.local.example .env` 후 `.env`에서 설정합니다. (실값 커밋 금지 — `.env`는 git-ignore)

### 필수

| 변수 | 로컬 기본값 | 설명 |
|---|---|---|
| `OPENAI_API_KEY` | (직접 입력) | AI 카드/브리핑 생성·요약·챗봇·시맨틱 검색. **없으면 AI 기능 동작 안 함** |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | `axis` / `axuser` / `axpass` | 로컬 postgres 컨테이너 초기화 값 (수정 불필요) |
| `DATABASE_URL` | `postgresql://axuser:axpass@postgres:5432/axis` | Python(ai)용 |
| `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` | `jdbc:postgresql://postgres:5432/axis` 외 | Backend(JDBC)용 |
| `AXIS_AUTH_JWT_SECRET` | `local-dev-...`(32바이트+) | Spring Security JWT 서명 키 |
| `CRON_INTERNAL_TOKEN` | `local-dev-cron-token` | 파이프라인/알림 트리거 엔드포인트 Bearer 토큰 |

### 선택 (없어도 기동됨 — 해당 기능만 비활성)

| 변수 | 없으면 |
|---|---|
| `NAVER_CLIENT_ID` / `NAVER_CLIENT_SECRET` (+ `NAVER_CLIENT_IDS/SECRETS` 다중키) | 뉴스 수집 불가 |
| `DART_API_KEY` | 공시(재무) 수집 불가 |
| `KIPRIS_API_KEY` | 특허 수집 불가 |
| `SARAMIN_API_KEY` / `WORK24_API_KEY` | 채용공고 수집 불가 |
| `BRIEFING_TIME` (`08:30`) / `BRIEFING_RECIPIENTS` | 이메일 정기 브리핑 비활성 |
| `MLFLOW_TRACKING_URI` | 실험 추적 비활성 |
| `QDRANT_API_KEY` | (로컬은 비워둠) |

### 인증/프로파일 (로컬 기본값 권장)

| 변수 | 로컬 기본값 | 의미 |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | `local` | Spring 프로파일 |
| `AXIS_AUTH_ENFORCE` | `true` | 인증 강제 (false면 모든 API permitAll) |
| `AXIS_AUTH_ALLOWED_EMAIL_DOMAINS` | `*` | 가입 허용 이메일 도메인 |
| `AXIS_AUTH_EMAIL_VERIFICATION_DELIVERY` | `log` | 인증 링크를 메일 대신 **로그 출력** |
| `VITE_API_BASE_URL` | `http://localhost:8080` | 프론트가 호출할 backend |

> 이메일 발송은 **AWS SES V2 + IRSA만** 사용합니다 (Slack·SMTP 폐기). 로컬에서는 SES 자격 없이도 위 `=log` 설정으로 인증 흐름을 테스트할 수 있습니다.

---

## 3. 서비스 포트

| 서비스 | 포트 | 설명 |
|---|---|---|
| PostgreSQL | 5432 | 원문 아카이브 DB |
| Qdrant HTTP / gRPC | 6333 / 6334 | 벡터 검색엔진 |
| SpringBoot Backend | 8080 | REST API (외부 노출 대상) |
| Python AI Server | 8001 | FastAPI 내부 서버 (backend에서만 호출) |
| React Frontend | 3000 | 대시보드 |

---

## 4. 레포별 단독 실행 (호스트 직접 / 빠른 iterate)

DB·Qdrant만 컨테이너로 띄우고 각 서비스는 호스트에서 직접 실행하면 HMR·디버거·빠른 빌드 사이클이 가능합니다. 각 레포 README에 상세 가이드가 있습니다.

```bash
# 1) DB + Qdrant 만 컨테이너로
cd axis-infra
docker compose --profile local up -d postgres qdrant

# 2) 각 서비스를 호스트에서 (별도 터미널)
cd ../axis-backend  && ./gradlew bootRun --args='--spring.profiles.active=local'   # :8080
cd ../axis-ai       && uv sync && uv run uvicorn src.api.main:app --port 8001      # :8001
cd ../axis-frontend && npm install && npm run dev                                  # :3000 (Vite proxy → 8080)
```

| 레포 | 스택 | 로컬 가이드 |
|---|---|---|
| [axis-backend](https://github.com/SKALA-AXis/axis-backend) | Spring Boot 3 / Java 17 / Gradle | `axis-backend/README.md` |
| [axis-ai](https://github.com/SKALA-AXis/axis-ai) | FastAPI / Python 3.11 / uv / LangGraph | `axis-ai/README.md` |
| [axis-frontend](https://github.com/SKALA-AXis/axis-frontend) | React 18 / TypeScript / Vite | `axis-frontend/README.md` |

> ai/backend는 컨테이너 네트워크 hostname(`postgres`, `qdrant`, `ai`)을 쓰므로, 호스트 실행 시에는 각 레포 README의 로컬 `.env`(호스트는 `localhost`) 안내를 따르세요.

---

## 5. 팀 개발자 모드 (SKALA EKS 접근 필요)

> 팀원이 공용 클러스터 DB를 보며 작업하거나 운영 배포할 때 사용. 평가자는 무시해도 됩니다.

| 모드 | 명령 | 용도 |
|---|---|---|
| **A. Cluster DB** | `make up-cluster` / `make down-cluster` | 팀 공용 DB 보면서 dev (port-forward 자동) |
| **B. Local docker** | `docker compose --profile local up -d --build` | 위 [1. 빠른 시작](#1-빠른-시작--완전-로컬-실행-클러스터팀-시크릿-불필요)과 동일 (오프라인·스키마 실험) |
| **C. kind 로컬 K8s** | `make local-up` / `make local-down` | 매니페스트를 로컬 kind에 적용해 검증 |

- DB 스키마 변경은 **반드시 Mode B(격리 docker DB)에서 검증 후 PR** — 절대 클러스터 DB에 직접 migrate 금지 (Flyway 비활성 + `beforeMigrate__prod_guard.sql` 3중 가드).
- 매니페스트 검증(CI 동일): `make validate`
- 운영 배포(Harbor push + ArgoCD): `make skala-build && make skala-push` → axis-infra deploy 커밋 → 공용 ArgoCD sync. 상세는 `Makefile` 주석과 [docs/ci-cd-plan.md](docs/ci-cd-plan.md).

---

## 6. 레포 구조

```
axis-infra/
├── CLAUDE.md                      # 프로젝트 마스터 컨텍스트 (정본)
├── docker-compose.yml             # 로컬 풀스택 (local 프로파일)
├── docker-compose.cluster-db.yml  # Mode A 보조 (cluster DB + 로컬 ai/frontend)
├── .env.local.example             # 로컬 환경변수 템플릿  →  cp .env.local.example .env
├── Makefile                       # up-cluster / local-up / validate / skala-* 등
├── db/
│   ├── schema.sql                 # PostgreSQL DDL (V40 스냅샷, 로컬 초기화에 사용)
│   └── schema.dbml                # ERD 소스
├── api/
│   ├── openapi.yaml               # Frontend ↔ Backend 계약 (단일 기준)
│   └── ai-internal-api.yaml       # Backend ↔ AI 계약 (단일 기준)
├── k8s/
│   ├── base/                      # 공통 매니페스트
│   └── overlays/{skala,local}/    # 환경별 kustomize overlay
├── helm/                          # (보조) helm 차트
├── scripts/                       # env→secret 변환, cron 윈도우 검증 등
└── docs/                          # 아키텍처·ADR·컨벤션·CI/CD·인계 가이드
```

---

## 7. 문서 지도 (어디가 정본인가)

> 전체 지도: **[docs/README.md](docs/README.md)**

| 주제 | 정본 |
|---|---|
| 프로젝트 마스터 컨텍스트 | [CLAUDE.md](CLAUDE.md) |
| 팀 개발 컨벤션 (DB 마이그레이션 안전 규칙 §15 포함) | [docs/conventions/CONVENTION.md](docs/conventions/CONVENTION.md) |
| API 계약 | [api/openapi.yaml](api/openapi.yaml) · [api/ai-internal-api.yaml](api/ai-internal-api.yaml) |
| DB 스키마 | V40까지 [db/schema.sql](db/schema.sql) 스냅샷, **V41+ 진실은 backend Flyway** ([규칙](docs/DB_METADATA.md)) |
| 아키텍처 결정 | [docs/adr/](docs/adr/) |
| CI/CD·운영·인계 | [docs/ci-cd-plan.md](docs/ci-cd-plan.md) · [docs/HANDOVER.md](docs/HANDOVER.md) · [docs/SES_INTEGRATION.md](docs/SES_INTEGRATION.md) |

---

## 8. 운영 배포 (SKALA EKS GitOps) — 참고

| 항목 | 값 |
|---|---|
| Cluster / Namespace | `skala-2025` (EKS, ap-northeast-2) / `skala3-finalproj-class3-team13` |
| 배포 흐름 | 서비스 레포 `develop` push → GitHub Actions → Harbor → axis-infra deploy 커밋 → 공용 ArgoCD sync |
| Rollback | `git revert` |
| 이미지 레지스트리 | Harbor (`amdp-registry.skala-ai.com/skala26a-ai3`) |
| 이메일 발송 | AWS SES V2 SDK + IRSA |
| 운영 제약 | 클러스터 노드 매일 23:00–07:00 KST 셧다운 → CronJob은 07:00–22:59 KST 안에만 |

---

## 9. 팀원

| 이름 | 역할 | 담당 레포 |
|---|---|---|
| 김가은 | AI Lead + PM | axis-ai, axis-infra |
| 박진 | AI Engineer | axis-ai (RAG·검색·평가) |
| 심유정 | AI Engineer | axis-ai (크롤러·전처리) |
| 박지원 | Backend Lead | axis-backend, axis-infra |
| 안가은 | Frontend | axis-frontend |
| 최종민 | Frontend | axis-frontend |

---

**SKALA AI 13조 · 2026-04-16 ~ 2026-06-23**
