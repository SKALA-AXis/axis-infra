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

## 🚀 로컬 개발 방법 (3가지 모드)

| 모드 | DB / Qdrant | 명령 | 용도 |
|---|---|---|---|
| **A. Cluster DB** ⭐ 권장 | SKALA EKS (port-forward 자동) | `make up-cluster` | 일상 dev — 팀 공용 DB 보면서 코드 작업 |
| **B. Local docker** | 로컬 docker postgres + qdrant | `docker compose --profile local --env-file .env.local up -d` | 오프라인 작업, **새 migration 스키마 실험** |
| **C. Host 실행** | (A 또는 B 선택) | `kubectl port-forward …` + `./gradlew bootRun` / `uv run python` | 빠른 iterate (HMR), debugger 부착 |

> 옛 Supabase / Qdrant Cloud 모드는 폐기됨 (cluster in-cluster Postgres + Qdrant 전환 완료).

### Mode A — Cluster DB + docker compose ⭐ 권장

cluster 의 Postgres + Qdrant 에 docker compose 가 띄운 backend·ai·frontend 가 연결. 팀원과 같은 DB 보면서 개발 — 데이터 일관성·격리 둘 다.

```bash
# 1. SKALA EKS 접근 권한 (kubeconfig) 가 있는지 확인
kubectl config current-context
# arn:aws:eks:ap-northeast-2:...:cluster/skala-2025

# 2. 한 명령으로 띄움 (port-forward 자동 + docker compose)
make up-cluster

# 3. 접근:
#    - frontend: http://localhost:3000
#    - backend:  http://localhost:8080
#    - ai:       http://localhost:8001
#    - cluster postgres: localhost:5432 (port-forward 경유)
#    - cluster qdrant:   localhost:6333

# 4. 종료
make down-cluster
```

**자동 보호장치** ([docker-compose.cluster-db.yml](docker-compose.cluster-db.yml)):

- `SPRING_FLYWAY_ENABLED=false` — backend container 가 cluster DB 에 silent 자동 migrate 못 함 (PR #20 의 application-local.yml 와 별개의 환경변수 차원 이중 안전)
- `host.docker.internal` 통해 host port-forward 로 cluster DB 접근
- postgres / qdrant 컨테이너는 안 뜸 (Mode B 와 격리)

**Mode A 에서 절대 하지 말 것**:

- 새 V28+ migration 파일 작업 트리에 두고 실행 — Flyway 비활성이지만 명시 override (`--spring.flyway.enabled=true`) 시 cluster DB 에 silent 적용 위험
- DB schema 변경은 **반드시 Mode B 에서 검증** 후 PR

### Mode B — Local docker (스키마 실험 / 오프라인)

로컬 docker 의 postgres + qdrant 컨테이너로 격리 환경.

```bash
# 1. .env.local 작성
cp .env.local.example .env.local
#   DATABASE_URL=postgresql://axuser:axpass@postgres:5432/axis
#   SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/axis
#   QDRANT_HOST=http://qdrant  QDRANT_API_KEY=  (비워둠)

# 2. 전체 스택 (postgres + qdrant + backend + ai + frontend)
docker compose --profile local --env-file .env.local up -d

# 3. DB·Qdrant 만 띄우고 코드는 host 에서 실행 (Mode C 와 결합)
docker compose --profile local --env-file .env.local up -d postgres qdrant
```

**새 migration 검증 워크플로**:

```bash
# 1. Mode B 로 격리 docker DB 띄움
docker compose --profile local --env-file .env.local up -d postgres qdrant

# 2. backend 를 명시 Flyway enable 로 실행 (Mode A·application-local.yml 의 차단 우회)
cd ../axis-backend
./gradlew bootRun --args='--spring.profiles.active=local --spring.flyway.enabled=true'

# 3. 검증 후 PR → 머지 → ArgoCD sync → cluster pod 가 prod profile 로 적용
```

### Mode C — Host 실행 (개별 서비스 빠른 iterate)

DB / Qdrant 는 Mode A 또는 B 로 띄우고, backend / ai / frontend 는 host 에서 직접 실행. HMR / debugger / 빠른 빌드 사이클.

```bash
# DB·Qdrant 준비 (둘 중 하나)
make up-cluster                            # cluster DB
# 또는
docker compose --profile local --env-file .env.local up -d postgres qdrant

# 각 서비스 host 실행
cd ../axis-backend && ./gradlew bootRun --args='--spring.profiles.active=local'
cd ../axis-ai      && uv run python -m src.main
cd ../axis-frontend && npm run dev
```

### 환경 설정 체크리스트 (신규 팀원)

- [ ] kubeconfig 로 SKALA EKS 접근 가능한지 확인 (Mode A 필수)
- [ ] `.env` 받기 — 노션·1Password 에서 공유, **절대 커밋 금지**
- [ ] Mode B 쓸 거면 `.env.local` 작성
- [ ] DB schema 변경 시 Mode B 검증 → PR — 절대 Mode A 에서 schema 변경 X
- [ ] CI 검증 항목: SQL 스키마 + OpenAPI 유효성 ([.github/workflows/validate.yml](.github/workflows/validate.yml))

### 모드별 빠른 비교

| 작업 | Mode A (cluster) | Mode B (local docker) | Mode C (host) |
| --- | --- | --- | --- |
| 시작 | `make up-cluster` | `docker compose --profile local --env-file .env.local up -d` | `./gradlew bootRun` / `uv run` |
| Postgres | cluster (port-forward) | docker postgres:5432 | (A 또는 B 선택) |
| Qdrant | cluster (port-forward) | docker qdrant:6333 | (A 또는 B 선택) |
| 협업 | ✅ 팀 공유 DB | ❌ 로컬 격리 | (선택에 따라) |
| Flyway 자동 migrate | ❌ 차단 (이중 안전) | ✅ 활성 (격리 docker DB) | local profile 비활성 / 명시 enable 가능 |
| Schema 변경 | ❌ 금지 (PR 경유) | ✅ 권장 | ✅ 명시 enable 시 가능 |
| 코드 변경 iterate | docker rebuild 필요 | docker rebuild 필요 | ⭐ HMR / 빠름 |

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
