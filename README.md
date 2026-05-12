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

## 🚀 실행 방법

운영(Production) 은 **SKALA EKS in-cluster** 에서 돌고, 로컬 개발은 **docker-compose** 로 한다. 둘 다 in-cluster · 컨테이너 Postgres / Qdrant 를 사용하며 외부 SaaS DB (Supabase / Qdrant Cloud) 는 사용하지 않는다.

| 환경 | PostgreSQL | Qdrant | 사용 위치 |
|---|---|---|---|
| **SKALA EKS (운영)** | in-cluster Deployment + 5Gi gp3 PVC (`postgres:5432`) | in-cluster Deployment + 5Gi gp3 PVC (`qdrant:6333/6334`) | ns `skala3-finalproj-class3-team13` · ArgoCD GitOps |
| **로컬 dev** | docker postgres:5432 | docker qdrant:6333 | `.env.local` + `--profile local` |

### 운영 (SKALA EKS)

`develop` push → GitHub Actions (CI + Build-and-Push to Harbor) → `axis-infra` 에 `deploy: SVC → SHA` auto-commit → 공용 ArgoCD 가 develop watch 후 ServerSideApply. 자세한 GitOps 흐름은 [docs/ci-cd-plan.md](docs/ci-cd-plan.md).

```bash
# 클러스터 상태 보기 (kubeconfig 필요)
kubectl -n skala3-finalproj-class3-team13 get all

# 일일 브리핑 수동 트리거 (검증용)
kubectl -n skala3-finalproj-class3-team13 exec deploy/axis-backend -- \
  curl -s -X POST http://localhost:8080/api/pipeline/briefing
```

### 로컬 dev — docker-compose

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

- [ ] 로컬 dev 면 `.env.local` 작성 (template 참고)
- [ ] 운영 cluster 작업 필요 시 매니저로부터 kubeconfig + Harbor robot 자격 받기
- [ ] `db/schema.sql` 마이그레이션은 SpringBoot Flyway 가 자동 적용 — 직접 `psql -f` 할 필요 없음
- [ ] CI 검증 항목: SQL 스키마 + OpenAPI 유효성 + API 스펙 변경 PR 코멘트 ([.github/workflows/validate.yml](.github/workflows/validate.yml))

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
