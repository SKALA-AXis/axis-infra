# AXIS — AX Intelligence Signal

AXIS는 Peer사(삼성SDS·LG CNS·현대오토에버·포스코DX)의 전략적 변화를 24/7 자동 감지하여, SK AX 관점의 시사점 초안까지 제공하는 전략기획 담당자 전용 AI 브리핑 시스템입니다. 뉴스·공시·채용공고를 자동 수집하고 LangGraph 기반 AI 파이프라인이 동향 카드를 생성해 매일 오전 이메일로 전달합니다.

---

## 레포 구조

```
axis-infra/                     ← 이 레포 (Single Source of Truth)
├── CLAUDE.md                   # Claude Code 프로젝트 컨텍스트
├── docker-compose.yml          # 로컬 개발 (개인 Mac)
├── .env.example                # 환경변수 템플릿
├── Makefile                    # skala-build/push/secret 등
├── db/
│   └── schema.sql              # PostgreSQL DDL
├── api/
│   ├── openapi.yaml            # SpringBoot ↔ Frontend 계약
│   └── ai-internal-api.yaml    # SpringBoot ↔ Python AI 계약
├── k8s/                        # SKALA EKS 운영 배포 매니페스트
│   ├── base/                   #   공통
│   ├── overlays/{skala,local}/ #   환경별 kustomize overlay
│   ├── argocd/                 #   ArgoCD Application + repo Secret (공용 skala-argocd)
│   └── argocd-self/            #   비상용 자체 ArgoCD spec
├── scripts/
│   └── env-to-skala-secret.sh  # .env → cluster Secret
├── .github/workflows/
│   └── validate.yml            # SQL · OpenAPI 검증 CI
└── docs/
    ├── ci-cd-plan.md           # GitOps 자동화 plan (v7)
    ├── HANDOVER.md             # 인계 가이드 (PAT 회전 등)
    ├── SES_INTEGRATION.md      # AWS SES + IRSA spec
    ├── SYSTEM_ARCHITECTURE.md  # 시스템 흐름
    ├── INFRASTRUCTURE_PLAN.md  # 인프라 plan
    ├── conventions/CONVENTION.md
    ├── adr/                    # Architecture Decision Records
    ├── meetings/               # 회의록
    └── sprints/                # 스프린트 계획 및 회고
```

---

## 🚀 실행 방법 (두 가지 모드)

axis-infra 의 docker-compose 는 **Cloud / Local 두 가지 DB 모드**를 한 파일로 지원합니다. `.env` 파일 + `--profile` 플래그 조합으로 전환합니다.

| 모드 | PostgreSQL | Qdrant | 사용 환경 변수 파일 | 컨테이너 기동 범위 |
|---|---|---|---|---|
| **Cloud** (기본) | Supabase | Qdrant Cloud | `.env` | backend / ai / frontend (postgres·qdrant 컨테이너 X) |
| **Local** | docker postgres | docker qdrant | `.env.local` | postgres / qdrant / backend / ai / frontend |

> Cloud 모드에서는 `postgres` · `qdrant` 서비스가 `profiles: ["local"]` 로 묶여 있어 자동으로 제외됩니다.

### Mode 1 — Cloud 모드 (기본)

Supabase Postgres + Qdrant Cloud 에 backend / ai 가 직접 붙는 구성. 팀 공용 DB라 데모·PR 검증 용이.

```bash
# 1. 레포 클론
git clone https://github.com/SKALA-AXis/axis-infra.git
cd axis-infra

# 2. .env 작성 (template 참고; Supabase DSN, Qdrant Cloud URL/API key 입력)
cp .env.example .env
#   필수: DATABASE_URL, SPRING_DATASOURCE_URL/USERNAME/PASSWORD,
#         QDRANT_HOST(https://...cloud.qdrant.io), QDRANT_API_KEY,
#         OPENAI_API_KEY, NAVER_*, DART_API_KEY, KIPRIS_API_KEY

# 3. 전체 서비스 기동 (postgres·qdrant 컨테이너는 안 뜸)
docker compose up -d

# 4. 로그
docker compose logs -f ai backend
```

### Mode 2 — Local 모드 (오프라인 / 비용 절감)

postgres + qdrant 컨테이너를 같이 띄우고 backend/ai 가 같은 네트워크의 컨테이너에 붙는 구성.

```bash
# 1. .env.local 작성
cp .env.local.example .env.local
#   DATABASE_URL=postgresql://axuser:axpass@postgres:5432/axis
#   SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/axis
#   QDRANT_HOST=qdrant   QDRANT_API_KEY=  (비워둠)

# 2. profile=local + --env-file 플래그로 기동 (둘 다 필수)
docker compose --profile local --env-file .env.local up -d

# 3. DB·Qdrant 만 띄우고 backend·ai 는 호스트에서 개발 모드로 돌리기
docker compose --profile local --env-file .env.local up -d postgres qdrant
#   이후 axis-ai: uv run python run_pipeline_once.py --env local
#        axis-backend: ./gradlew bootRun --args='--spring.profiles.active=local'
```

### 환경 설정 체크리스트 (신규 팀원)

- [ ] `.env` (Cloud) 받기 — 노션·1Password 등에서 공유, **절대 커밋 금지**
- [ ] (옵션) Local 모드 쓸 거면 `.env.local` 작성
- [ ] `db/schema.sql` 마이그레이션은 SpringBoot Flyway 가 자동 적용 — 직접 `psql -f` 할 필요 없음
- [ ] CI 검증 항목: SQL 스키마 + OpenAPI 유효성 + API 스펙 변경 PR 코멘트 ([.github/workflows/validate.yml](.github/workflows/validate.yml))

### 모드별 빠른 비교

| 작업 | Cloud | Local |
|---|---|---|
| 시작 명령 | `docker compose up -d` | `docker compose --profile local --env-file .env.local up -d` |
| Postgres | Supabase pooler:6543 (sslmode=require) | docker postgres:5432 |
| Qdrant | https Cloud | http localhost (api_key 비움) |
| LLM 비용 | 동일 | 동일 (OPENAI_API_KEY) |
| 데이터 영속성 | Supabase 영구 | 컨테이너 volume |
| 협업 | ✅ 팀 공유 | ❌ 로컬 격리 |

---

## 서비스 포트

| 서비스 | 포트 | 설명 |
|---|---|---|
| PostgreSQL | 5432 | 원문 아카이브 DB |
| Qdrant HTTP | 6333 | 벡터 검색엔진 |
| Qdrant gRPC | 6334 | 벡터 검색엔진 (gRPC) |
| SpringBoot Backend | 8080 | REST API 서버 |
| Python AI Server | 8001 | FastAPI 내부 서버 |
| React Frontend | 3000 | 대시보드 |

---

## 레포 링크

| 레포 | 기술 스택 | 담당 |
|---|---|---|
| [axis-infra](https://github.com/SKALA-AXis/axis-infra) | k8s, ArgoCD, DB, API 스펙 | 전체 |
| [axis-backend](https://github.com/SKALA-AXis/axis-backend) | SpringBoot 3.x (Java 17) + AWS SES SDK | 박지원 |
| [axis-ai](https://github.com/SKALA-AXis/axis-ai) | Python 3.11, FastAPI, LangGraph | 김가은·박진·심유정 |
| [axis-frontend](https://github.com/SKALA-AXis/axis-frontend) | React 18 + TypeScript + Vite | 안가은·최종민 |

## 운영 배포 (SKALA EKS GitOps)

| 항목 | 값 |
|---|---|
| Cluster | `skala-2025` (EKS, ap-northeast-2) |
| Namespace | `skala3-finalproj-class3-team13` |
| ALB endpoint | http://skala3-team13-axis-alb-1349892737.ap-northeast-2.elb.amazonaws.com |
| ArgoCD UI | https://argocd.skala25a.project.skala-ai.com (공용 `skala-argocd`) |
| 이미지 레지스트리 | Harbor (`amdp-registry.skala-ai.com/skala26a-ai3`) |
| 이메일 발송 | AWS SES V2 SDK + IRSA (sender `noreply@skala-ai.com`) |

자세한 흐름: [docs/ci-cd-plan.md](docs/ci-cd-plan.md), 인계 가이드: [docs/HANDOVER.md](docs/HANDOVER.md), SES 통합: [docs/SES_INTEGRATION.md](docs/SES_INTEGRATION.md).

---

## API 문서

로컬 실행 후 아래 URL에서 확인할 수 있습니다.

- **Swagger UI (Backend)**: http://localhost:8080/swagger-ui
- **OpenAPI YAML (Frontend↔Backend)**: [api/openapi.yaml](api/openapi.yaml)
- **AI Internal API YAML (Backend↔AI)**: [api/ai-internal-api.yaml](api/ai-internal-api.yaml)

---

## 팀원

| 이름 | 역할 | 담당 레포 |
|---|---|---|
| 김가은 | AI Lead + PM | axis-ai (파이프라인), axis-infra (일정) |
| 박진 | AI Engineer A | axis-ai (RAG·검색·평가) |
| 심유정 | AI Engineer B | axis-ai (크롤러·전처리) |
| 박지원 | Backend Lead | axis-backend, axis-infra |
| 안가은 | Frontend | axis-frontend |
| 최종민 | Frontend | axis-frontend |

---

**SKALA AI 13조 · 2026-04-16 ~ 2026-06-23**
