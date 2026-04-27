# AXIS — 프로젝트 마스터 컨텍스트

> 이 파일은 axis-infra 레포의 CLAUDE.md입니다.
> Claude Code가 세션 시작 시 자동으로 읽습니다.
> 프로젝트 전체 맥락을 담고 있습니다.

---

## 서비스 개요

**서비스명**: AXIS (AX Intelligence Signal)
**한 줄 정의**: Peer사(삼성SDS·LG CNS)의 전략적 변화를 24/7 자동 감지하여, SK AX 관점의 시사점 초안까지 제공하는 전략기획 담당자 전용 AI 브리핑 시스템
**발주**: SK AX 사업전략팀
**수행**: SKALA AI 13조 (김가은·박지원·박진·심유정·안가은·최종민)
**기간**: 2026-04-16 ~ 2026-06-23 (9주)

---

## 문제 정의

전략기획 조직의 손실은 정보 부족이 아닙니다.
**"중요하지 않은 기사까지 검토하느라 중요한 타이밍을 놓치는 것"** 이 진짜 문제입니다.

- 하루 2~3시간: 수동 뉴스 검색·분류
- 현재 도구: 구글 검색만 사용
- 병목: 'SK AX 관점에서 이게 왜 중요한가' 연결에 가장 많은 시간 소요
- 리스크: 중요 신호를 며칠 뒤에야 발견

---

## 레포 구조

```
GitHub Organization: skala-ai-13 (또는 팀 org)

axis-infra      ← 이 레포 (Docker, DB, API 스펙, 문서)
axis-backend    ← SpringBoot REST API 서버 (Java)
axis-ai         ← Python AI 파이프라인 (LangGraph, RAG, 크롤러)
axis-frontend   ← React 대시보드 (TypeScript)
```

### 이 레포(axis-infra)가 하는 일

- `docker-compose.yml` — 전체 서비스 로컬 실행
- `db/schema.sql` — PostgreSQL DDL (Single Source of Truth)
- `api/openapi.yaml` — REST API 계약서 (SpringBoot ↔ Frontend)
- `api/ai-internal-api.yaml` — 내부 API 계약서 (SpringBoot ↔ Python AI)
- `docs/` — ADR, 컨벤션, 회의록
- `docs/conventions/CONVENTION.md` — Git 브랜치·커밋 규칙

---

## 전체 시스템 아키텍처

```
React (Frontend)
    ↕ REST API (openapi.yaml 계약)
SpringBoot (Backend — Java 17)
    ↕ HTTP 내부 통신 (ai-internal-api.yaml 계약)
Python AI Server (FastAPI — Python 3.11)
    ├── LangGraph AI 파이프라인
    ├── BGE-M3 임베딩
    ├── Qdrant 하이브리드 검색
    ├── GPT-4o API (OpenAI)
    └── 크롤러 (뉴스·공시·채용공고)
        ↕
PostgreSQL (원문 아카이브)    Qdrant (벡터 검색엔진)
```

### 통신 흐름 예시 — 사용자가 "LG CNS 전략 검색"

```
1. React → POST /api/search { query: "LG CNS 전략" } → SpringBoot
2. SpringBoot → POST http://ai:8001/search → Python AI 서버
3. Python AI → BGE-M3 임베딩 → Qdrant RRF 검색
4. Python AI → GPT-4o API → Generative Search
5. Python AI → SpringBoot (응답)
6. SpringBoot → React (응답)
```

### 통신 흐름 예시 — 오전 8:30 자동 브리핑 (v3: 이메일 발송)

```
1. SpringBoot 스케줄러 → POST http://ai:8001/pipeline/run (1시간마다)
2. Python AI → 크롤링 → credibility → dedup → classify → issue_card → evidence → DB 저장
3. SpringBoot 스케줄러 → POST http://ai:8001/pipeline/delivery (오전 8:30)
4. Python AI → 동향 카드 + 검증 첨부 4종 조회 → 이메일 본문 구성 → 발송
```

---

## 기술 스택 확정

| 레이어 | 기술 | 버전 | 비고 |
|---|---|---|---|
| LLM | GPT-4o | gpt-4o | OpenAI API |
| 임베딩 | BGE-M3 (로컬) | FlagEmbedding 1.x | Dense+Sparse 원샷, MIT 라이선스 |
| Reranker | BGE-reranker-v2-m3 | FlagEmbedding 1.x | Cross-Encoder 방식 |
| Vector DB | Qdrant | 1.9.x | 하이브리드 검색 네이티브 |
| Raw DB | PostgreSQL | 16.x | 원문 아카이브 |
| 파이프라인 | LangGraph | 0.2.x | Supervisor 패턴 |
| AI 서버 | FastAPI + uv | FastAPI 0.115.x | Python 내부 서버 |
| 백엔드 | SpringBoot | 3.x (Java 17) | REST API 서버 |
| 프론트 | React + Vite | React 18.x | TypeScript |
| 배포 | Docker Compose | v2.x | MVP 단계 |
| 모니터링 | MLflow | 2.x | 실험·메트릭 추적 |
| CI/CD | GitHub Actions | - | 각 레포 독립 CI |

---

## Docker Compose 서비스 구성

```yaml
# docker-compose.yml 서비스 목록
services:
  postgres:   포트 5432, DB명 axis
  qdrant:     포트 6333 (HTTP), 6334 (gRPC)
  backend:    포트 8080 (SpringBoot)
  ai:         포트 8001 (Python FastAPI)
  frontend:   포트 3000 (React)
```

**전체 실행 명령어:**
```bash
docker compose up -d
```

**로컬 개발 시 (각 서비스 별도 실행):**
```bash
docker compose up -d postgres qdrant  # DB만 올리고
# backend/ai/frontend는 각자 로컬에서 실행
```

---

## DB 설계 원칙

### 저장소 책임 분리

| 저장소 | 책임 | 저장 대상 | 보존 기간 |
|---|---|---|---|
| PostgreSQL | 원문 보존·감사 추적·재처리 | 수집 원문 전량 + 메타데이터 | 6개월 |
| Qdrant main | 최근 3개월 검색엔진 | 대표 기사 Dense+Sparse 벡터 | 3개월 TTL |
| Qdrant history | 1년치 히스토리 분석 | 1년치 벡터 (시그널 히스토리 전용) | 12개월 TTL |

### 핵심 원칙
- **원문은 항상 PostgreSQL에 보관** (벡터 만료 후 재임베딩 가능)
- **Qdrant에 원문 텍스트 저장 금지** (페이로드는 메타데이터만)
- **삽입 비율**: 수집 500건/일 → 필터 후 약 50건만 Qdrant에 삽입

---

## API 계약 원칙

- `api/openapi.yaml` 변경 시 **반드시 팀 공지 후 각 레포 자동 생성 재실행**
- 프론트: `npx openapi-typescript api/openapi.yaml -o src/types/api.ts`
- SpringBoot: openapi-generator-cli로 Controller 인터페이스 생성
- Python: `datamodel-codegen --input api/ai-internal-api.yaml --output src/schemas.py`

---

## 핵심 비즈니스 로직 원칙

### 환각 방지 (최우선)
- **근거 없으면 생성하지 않음** — 원칙 절대 불변
- SC(Self-Consistency) 검증: 동일 입력으로 3회 생성 후 2/3 일치 시 Pass
- 출처에 없는 수치(금액·%·날짜) 포함 시 자동 Fail

### 파이프라인 분리 원칙
```
수집 파이프라인 (1시간마다)  ≠  전달 파이프라인 (오전 8:30)
```
- 실행 주기가 다른 에이전트는 반드시 별도 LangGraph 그래프
- 두 파이프라인은 PostgreSQL을 통해서만 데이터 교환 (직접 호출 금지)

### 저장소 사용 원칙
- 크롤링된 원문 → PostgreSQL 전량 저장 (Gate 통과 여부 무관)
- Gate 1(품질) + Gate 2(신뢰도) + Gate 3(중복) 통과한 대표 기사만 → Qdrant
- Qdrant 페이로드: rdb_id(FK), peer_id, event_type, sector, exposure_band, exposure_score, pub_date, cluster_id, title, summary
- 동향 카드 검증 첨부 4종(source_links / provenance / financial_refs / mbb_refs)은 `evidence_chain` 테이블에 별도 저장

---

## Peer사 정보

### 모니터링 대상 (v3 — 1차 미팅 확정)
| ID | 회사명 | 경쟁 강도 | 비고 |
|---|---|---|---|
| samsung_sds | 삼성SDS | 🔴 매우 높음 | AX 풀스택 전략, OpenAI 리셀러 1호 |
| lg_cns | LG CNS | 🔴 매우 높음 | 팔란티어 파트너십, 에이전트웍스 |
| hyundai_autoever | 현대오토에버 | 🟡 높음 | 모빌리티 SI |
| posco_dx | 포스코DX | 🟡 높음 | 산업 DX |

### 이벤트 타입 Taxonomy (6개 고정)
```
partnership   파트너십·제휴
ma            M&A·투자·IPO
personnel     인사·조직 개편
tech          기술 발표·제품 출시
regulation    규제·정책
new_biz       신규 사업 진출
```

### 트렌드 섹터 (v3 — 1차 미팅 확정 5종)

```
security      보안
ai_tech       AI 기술
large_deal    대형 수주
sk_ax_biz     SK AX 사업
other         기타
```

### 노출도 밴드 (v3 — 결정적 산식)

```
exposure_score = 0.40·cluster_size + 0.30·credibility_max
               + 0.20·peer_mention + 0.10·tier1_diversity

high     ≥ 0.70
medium   0.40 ~ 0.70
low      < 0.40
```

> v1의 urgent/notable/reference는 폐기 (deprecated). 호환을 위해 API 스키마에서만 표시 유지.

---

## 성능 목표 (Success Criteria)

| 지표 | 최소 기준 | 목표 | 측정 시점 |
|---|---|---|---|
| 중요도 분류 F1 | 0.70 | 0.80 | 4주차 |
| RAG Hit@5 | 0.80 | 0.90 | 5주차 |
| RAG MRR | 0.65 | 0.75 | 5주차 |
| LLM 환각률 | 5% 이하 | 2% 이하 | 6주차 |
| 대시보드 응답 | 3,000ms | 2,000ms (95th) | 8주차 |
| 이슈카드 E2E | 60초 | 30초 | 4주차 |
| 일일 LLM 비용 | ₩10,000 | ₩5,000 | 상시 |

---

## 9주 스프린트 요약

| 주차 | 핵심 목표 |
|---|---|
| 1주 | BGE-M3 PoC Hit@5 측정 + 크롤러 프로토타입 + CI 세팅 |
| 2주 | 팀장 인터뷰 + 크롤러 확장 + OpenAPI 스펙 확정 |
| 3주 | 수집·정제 파이프라인 완성 + 골든셋 레이블링 |
| 4주 | AI 분석 파이프라인 완성 + 스테이징 배포 |
| 5주 | RAG + Generative Search + 프론트 연동 |
| 6주 | 통합 테스트 + Slack 브리핑 + 골든셋 최종 평가 |
| 7주 | 약한 신호 감지기 구현 |
| 8주 | 버그 수정 + 성능 최적화 + 인수 기준 검증 |
| 9주 | 발표 준비 + 데모 리허설 |

---

## 역할 분담

| 역할 | 담당자 | 주 책임 레포 |
|---|---|---|
| AI Lead + PM | 김가은 | axis-ai (파이프라인), axis-infra (일정) |
| AI Engineer A | 박진 | axis-ai (RAG·검색·평가) |
| AI Engineer B | 심유정 | axis-ai (크롤러·전처리) |
| Backend Lead | 박지원 | axis-backend, axis-infra |
| Frontend | 안가은·최종민 | axis-frontend |

---

## 이번 주 최우선 과제

1. 🔴 BGE-M3 + Qdrant PoC — 한국어 IT뉴스 50건 Hit@5 측정 (AI Engineer A)
2. 🔴 네이버뉴스 크롤러 프로토타입 — 기사 10건 PostgreSQL 저장 (AI Engineer B)
3. 🔴 팀장 인터뷰 일정 확정 (PM)
4. 🟡 GitHub Actions CI 세팅 (Backend Lead)
5. 🟡 골든셋 레이블링 20건 착수 (AI Engineer B)

---

## 파일 구조 (이 레포)

```
axis-infra/
├── CLAUDE.md                    ← 이 파일
├── README.md
├── .env.example                 ← 환경변수 템플릿 (실제 값 절대 커밋 금지)
├── .gitignore
├── docker-compose.yml           ← 로컬 전체 실행
├── docker-compose.prod.yml      ← 운영 배포
├── .github/
│   └── workflows/
│       └── validate.yml         ← SQL·OpenAPI 유효성 검사 CI
├── db/
│   └── schema.sql               ← PostgreSQL DDL
├── api/
│   ├── openapi.yaml             ← SpringBoot ↔ Frontend 계약
│   └── ai-internal-api.yaml     ← SpringBoot ↔ Python AI 계약
└── docs/
    ├── conventions/
    │   └── CONVENTION.md        ← 팀 개발 컨벤션
    ├── adr/
    │   ├── 0001-springboot-selection.md
    │   ├── 0002-qdrant-selection.md
    │   ├── 0003-bge-m3-selection.md
    │   ├── 0004-pipeline-separation.md
    │   └── 0005-two-storage-design.md
    ├── meetings/                ← 회의록 (YYYY-MM-DD.md)
    └── sprints/                 ← 스프린트 계획 및 회고
```

---

## 절대 하지 말 것

- `.env` 파일 커밋 금지 (API 키 노출)
- `openapi.yaml` 변경 후 팀 공지 없이 머지 금지
- `schema.sql` 직접 수정 금지 (마이그레이션 파일로 관리)
- Qdrant 페이로드에 원문 전체 텍스트 저장 금지
- 수집 파이프라인과 전달 파이프라인을 같은 LangGraph 그래프에 묶는 것 금지
