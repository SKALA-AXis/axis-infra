# AXIS — AX Intelligence Signal

AXIS는 Peer사(삼성SDS·LG CNS·현대오토에버·포스코DX)의 전략적 변화를 24/7 자동 감지하여, SK AX 관점의 시사점 초안까지 제공하는 전략기획 담당자 전용 AI 브리핑 시스템입니다. 뉴스·공시·채용공고를 자동 수집하고 LangGraph 기반 AI 파이프라인이 동향 카드를 생성해 매일 오전 이메일로 전달합니다.

---

## 레포 구조

```
axis-infra/                     ← 이 레포 (Single Source of Truth)
├── CLAUDE.md                   # Claude Code 프로젝트 컨텍스트
├── docker-compose.yml          # 로컬 전체 실행
├── docker-compose.prod.yml     # 운영 배포
├── .env.example                # 환경변수 템플릿
├── db/
│   └── schema.sql              # PostgreSQL DDL
├── api/
│   ├── openapi.yaml            # SpringBoot ↔ Frontend 계약
│   └── ai-internal-api.yaml    # SpringBoot ↔ Python AI 계약
├── .github/
│   └── workflows/
│       └── validate.yml        # SQL·OpenAPI 유효성 검사 CI
└── docs/
    ├── conventions/
    │   └── CONVENTION.md       # 팀 개발 컨벤션
    ├── adr/                    # 기술 결정 기록 (ADR)
    ├── meetings/               # 회의록
    └── sprints/                # 스프린트 계획 및 회고
```

---

## 빠른 시작

```bash
# 1. 레포 클론
git clone https://github.com/skala-ai-13/axis-infra.git
cd axis-infra

# 2. 환경변수 설정
cp .env.example .env
# .env 파일을 열어 OPENAI_API_KEY 등 실제 값 입력

# 3. 전체 서비스 실행 (처음 실행 시 이미지 빌드에 시간이 걸립니다)
docker compose up -d

# 4. 로그 확인
docker compose logs -f

# 로컬 개발 시 DB·Qdrant만 올리기
docker compose up -d postgres qdrant
```

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
| [axis-infra](https://github.com/skala-ai-13/axis-infra) | Docker, DB, API 스펙 | 전체 |
| [axis-backend](https://github.com/skala-ai-13/axis-backend) | SpringBoot 3.x (Java 17) | 박지원 |
| [axis-ai](https://github.com/skala-ai-13/axis-ai) | Python 3.11, FastAPI, LangGraph | 김가은·박진·심유정 |
| [axis-frontend](https://github.com/skala-ai-13/axis-frontend) | React 18 + TypeScript | 안가은·최종민 |

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
