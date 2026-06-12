# AXIS 프로젝트 구조 관리 계획서

> **작성**: 2026-06-10 · **기준**: 4개 레포 전수 분석 (axis-ai / axis-backend / axis-frontend / axis-infra)
> **목표**: 현업 수준의 프로젝트 구조 관리 체계를 도입하되, **발표(6/23, D-13) 전에는 동작을 바꾸지 않는 작업만** 수행하고 구조 변경은 발표 후로 격리한다.
> **검증 방법**: 레포별 자동 분석 + 핵심 주장(시크릿 추적 여부, 파일 줄 수)은 `git ls-files`/`wc -l`로 직접 재검증함. 본 문서의 수치는 재검증된 값만 사용.

> **레포별 작업 분해**: [structure-tasks/axis-ai.md](structure-tasks/axis-ai.md) · [structure-tasks/axis-backend.md](structure-tasks/axis-backend.md) · [structure-tasks/axis-frontend.md](structure-tasks/axis-frontend.md) · [structure-tasks/axis-infra.md](structure-tasks/axis-infra.md)

---

## 0. 요약 (TL;DR)

| 레포 | 구조 등급 | 핵심 문제 | 발표 전 조치 | 발표 후 조치 |
|---|---|---|---|---|
| axis-ai | C+ | 거대 에이전트 2개(7,028/6,071줄), 모듈 순환 의존, untracked 파일 11건 방치 | 위생·문서만 | 에이전트 분해, 의존 방향 정리 |
| axis-backend | B+ | 거대 서비스 1개(2,223줄), Fixture 단일 클래스 집중, `bin/` 커밋 | 위생·문서만 | 서비스 분해, Fixture 도메인 분리 |
| axis-frontend | C | `app/` ↔ `features/` 이중 구조 + 중복 컴포넌트, 테스트 0개, CLAUDE.md 전면 괴리 | **분석만 — 팀원 협의 필수** | 구조 단일화 (팀원 주도) |
| axis-infra | A- | 문서 중복/버전 산재, 백업·복사본 파일, placeholder 최종 치환 잔여 | 문서 거버넌스 정리 | — |

**전 레포 공통 문제 1순위는 코드가 아니라 "문서-코드 드리프트"다.** 4개 레포 CLAUDE.md 모두 v3 설계 기준(5월 중순)에 멈춰 있고 실제 코드는 v4+다. 신규 합류자(그리고 AI 도구)가 잘못된 지도를 보고 있다.

---

## 1. 현재 아키텍처 (재검증 완료 사항 포함)

### 1.1 시스템 토폴로지

```
React SPA (axis-frontend)  ← 상태 기반 커스텀 라우팅 (React Router 미사용!)
    ↕ REST — axis-infra/api/openapi.yaml (7,229줄, 06-09 갱신, 자동 생성 체인 정상)
Spring Boot (axis-backend) — 5계층 (controller 25 / service 26 / domain 15 / repository 11 / dto 20)
    ↕ HTTP — axis-infra/api/ai-internal-api.yaml
FastAPI (axis-ai) — agents 22 / pipeline 6 / rag 7 / crawler 19 / db 6 / services 20 (총 172 모듈, 약 9.6만 줄)
    ↕
PostgreSQL (Flyway V1~V43 연속) · Qdrant (main 3개월 / history 12개월)
```

### 1.2 운영 환경 제약 (구조 계획에 직접 영향)

- **노드 야간 셧다운**: skala-2025 워커 노드는 매일 23:00–07:00 KST 다운 (ADR 0007). CronJob은 07:00–22:59만 허용, CI 가드 존재 (`scripts/validate-cron-window.py`, PR #59).
- **GitOps**: 서비스 레포 develop push = 운영 배포. 즉 **모든 리팩토링 머지는 곧 배포**다. 발표 전 구조 변경을 금지하는 근거.
- **Harbor 레지스트리**: 프로젝트(skala26a-ai3)가 타 팀과 공유되며, 2026-06-10 우리 메인 이미지 3종이 외부 요인으로 삭제된 사건 발생(원인 매니저 확인 중). 이미지 수명 관리가 우리 통제 밖일 수 있음을 전제.
- **ResourceQuota**: PVC 5/5 (axis-models 머지 시), pods 30, requests.cpu 8. 새 워크로드 추가 전 quota 확인 필수.

---

## 2. 레포별 정밀 진단

### 2.1 axis-ai — 가장 큰 기술 부채, 가장 활발한 개발

**구조 (실측)**

```
src/  (172 .py, ~96,500줄)
├── api/          라우터 898줄 + 도메인별 스키마 7개     ← 테스트 없음
├── agents/       22개 (briefing_generation 7,028줄 / strategic_insight 6,071줄
│   │              / it_trend 1,508줄 / integration 1,162줄)
│   └── _deprecated/   3개 — 어디서도 import 안 됨 (weak_signal 등 v1 유물)
├── pipeline/     analysis_flow_graph.py 966줄 (CLAUDE.md의 "ingestion_graph.py"는 존재하지 않음)
├── rag/ crawler/ preprocessing/ db/ analysis/ services/ composers/ config/ ...
└── tests/        36개 — 모듈 커버 추정 ~47%
```

**잘 된 것**: ingestion/delivery 그래프 분리 원칙 준수 (State 타입까지 분리 확인). config/ 모듈로 상수 외부화 잘 됨. uv + lock 커밋 + cron 의존성 그룹 분리(Dockerfile.cron 경량화) 우수. 의존성 스택 현대적.

**문제 (우선순위순)**

| # | 문제 | 근거 | 위험 |
|---|---|---|---|
| A1 | **거대 에이전트**: `briefing_generation_agent.py` 7,028줄(메서드 ~296개), `strategic_insight_agent.py` 6,071줄 | wc -l 실측 | 두 명 이상이 동시에 못 건드림. PR 충돌의 진원지. 테스트 작성 사실상 불가 |
| A2 | **모듈 순환 의존**: api ↔ agents 양방향 실증 (`router.py`→agents, `chat_orchestrator_agent.py`·`today_insight_agent.py`→api 스키마) + services/pipeline 연쇄 | import grep 실측 | 절단 지점이 좁고 명확(스키마 import 2파일)해서 2-A1 비용은 크지 않음 — 방치 시 확산이 문제 |
| A3 | **untracked 파일 11건 방치**: `crawler/fast_filter.py`, `monitors/urgent.py`, `sources/{bigkinds,consensus,kipris,rss}.py`, `tests/test_parser_agents.py`, `data/peer_financials/sk_ax.json`, `docs/AGENT_ARCHITECTURE_VERIFICATION.md`, `tmp-cards/`, `src/axis_ai.egg-info/` | git status | **로컬에만 존재 = 백업 없음.** 노트북 분실 시 소실. 어떤 게 진행 중 작업이고 어떤 게 쓰레기인지 작성자만 앎 |
| A4 | **CLAUDE.md 드리프트**: ingestion_graph 5노드 서술 vs 실제 analysis_flow 7노드, 신규 에이전트 5개+ 미기재, infra CLAUDE.md와 노출도 산식·섹터 taxonomy 불일치 | 문서 대조 | 온보딩/AI 도구가 틀린 지도 사용 |
| A5 | API 라우터(898줄, 전 엔드포인트) 테스트 0 | tests/ 목록 | 계약 회귀를 backend 스모크에만 의존 |
| A6 | 크롤러 소스별 fetch→parse→post_process 패턴 중복 | 코드 대조 | 신규 소스 추가 비용 |

### 2.2 axis-backend — 기초 견고, 국소 비대

**잘 된 것**: 레이어 위반 없음(controller→repository 직접 호출 0건), Flyway V1~V43 연속·설정 무결, OpenAPI 계약 일치율 90%+ (추가 경로는 전부 내부용), SesMailService 등 신규 코드가 구조 원칙 준수, AI 실패 시 fixture fallback 패턴 일관적.

**문제**

| # | 문제 | 근거 | 위험 |
|---|---|---|---|
| B1 | `PeerOverviewTableService` 2,223줄 — 조회+변환+캐싱+계산+정규식이 한 클래스 | wc -l 실측 | JDBC 강결합으로 테스트 불가 |
| B2 | `ApiContractFixtureService` 778줄을 97개 사용처가 의존(실측 grep) — 전 도메인 fixture가 한 파일 | 사용처 검색 | 도메인 하나 고치면 전 컨트롤러 재컴파일·충돌 |
| B3 | `bin/` 디렉토리(빌드 산출물 38개)가 커밋됨 | git ls-files | diff 노이즈, 소스와 산출물 불일치 혼동 |
| B4 | peer 5사·IP 대역·기본 기간값 하드코딩 | 코드 확인 | peer 추가 = 코드 수정 배포 |
| B5 | 거대 서비스(CardNews/GlobalSearch/PeerOverview) 단위 테스트 부재 — 테스트 10개 중 단위 4개 | tests 목록 | 리팩토링 안전망 없음 |

### 2.3 axis-frontend — 이중 구조 과도기 (⚠️ 팀원 2명 주도 영역)

**실태**: CLAUDE.md가 서술하는 `pages/components/hooks/store` 구조, React Router v6, Zustand, React Query는 **전부 현재 코드와 다름**. 실제는:

- `src/app/` (레거시, 90 TSX — DashboardShell이 11개 뷰를 상태 기반 분기) + `src/features/` (신 구조, 27개 feature 디렉토리) **이중 구조**
- 동일 이름 컴포넌트가 양쪽에 존재 (HomeDashboardView, BriefingsView, KeywordGraphView 등) — 실사용은 `app/` 쪽, `features/` 쪽 다수는 미사용 추정
- Repository 패턴(HTTP+mock 듀얼) 자체는 우수하나 KeywordGraphView 등에서 httpClient 직접 호출로 우회 사례
- 거대 컴포넌트: `AxisPlanningViews.tsx` 2,980줄(실측), MixerView 1,218줄 등
- **테스트 0개** (`"test": "echo 'No tests yet'"`), 인라인 style 85건, untracked 47개
- `src/types/api.ts`는 자동 생성 상태 유지 중이나 마지막 재생성 5/18 — openapi.yaml은 6/9 갱신 → **재생성 필요 가능성**

**원칙**: 이 레포의 구조 결정권은 진행 중인 팀원(안가은·최종민)에게 있다. 본 계획서는 ①사실 전달 ②단일화 시점 협의 요청 ③CLAUDE.md 현행화까지만 다룬다.

### 2.4 axis-infra — 가장 건강, 문서 거버넌스만 정리

**잘 된 것**: base/overlay 책임 분리 우수, compose 3모드(cluster/local/host) 문서·구현 일치, k8s↔compose 간 포트/환경변수 전수 대조 불일치 0건, ADR 체계 가동, Makefile 타깃 전부 현행.

**문제**

| # | 문제 | 비고 |
|---|---|---|
| I1 | 문서 중복·버전 산재: `CLAUDE.md`≈`AGENTS.md`, `CONVENTION.md`≈`AXIS_개발표준정의서_infra_v1.0.md`(80% 중복), 개발계획 v2/v3 공존, `.docx`·한글파일명 PDF 혼입 | 단일 소스 불명 |
| I2 | 백업/복사본 파일: `api/openapi copy.yaml`(131KB, 5/18 시점 사본), 로컬의 `secret.skala 2.yaml`·`.env.skala.tmp.bak` (※ **git 추적 아님** — 로컬 위생 문제) | 혼동 유발 |
| I3 | ~~placeholder 잔여~~ → **2차 검증에서 기각**: `kubectl kustomize overlays/skala` 렌더 결과 REPLACE 잔존 0건 — base의 placeholder는 전부 overlay가 치환함. 발표 전 작업은 "렌더 grep REPLACE = 0건 확인" 1줄로 충분 | 정정됨 |
| I4 | 네이밍 불일치(정정): CronJob 이름은 `axis-cron-failure-notifier`로 파일명과 일치. 불일치는 같은 파일 내 보조 리소스(Role/RoleBinding/SA/ConfigMap = `axis-cron-notifier`)와 CronJob 사이 | 경미 |
| I5 | schema.sql(V40 스냅샷)과 backend Flyway(V43)의 동기화 프로세스 미문서화 | 어느 쪽이 SSoT인지 V41+ 구간 모호 |

### 2.5 오탐 정정 (분석 도구가 보고했으나 직접 검증으로 기각한 것)

> 팀이 불필요하게 패닉하지 않도록 명시한다.

1. **"`.env` 실값·`secret.skala 2.yaml`이 git에 커밋됨" → 사실 아님.** `git ls-files` 확인 결과 양 레포 모두 추적 파일은 `.example` 계열뿐이다. 실값 파일은 gitignore가 정상 작동 중이며 **로컬 작업 디렉토리에만 존재**한다. 따라서 "키 로테이션 + git 히스토리 정제" 같은 비상 조치는 **불필요**하다. (단, 로컬 복사본 정리는 위생 차원에서 수행 — Phase 0)
2. **"router.py 33,848줄, it_trend_agent 62,676줄" → 바이트 수를 줄 수로 오인.** 실측: router.py 898줄, it_trend 1,508줄. 단 briefing_generation 7,028줄·strategic_insight 6,071줄·PeerOverviewTableService 2,223줄·AxisPlanningViews 2,980줄은 실측 확인.

### 2.6 2차 검증(2026-06-10, 본 문서 발행 후 비판 검토)에서 정정·확정된 항목

| 항목 | 1차 기재 | 2차 검증 결과 |
|---|---|---|
| backend Fixture 사용처 | 161곳 | **97곳** (grep 실측) |
| infra placeholder 잔존 | "발표 전 치환 필요" | **기각** — `kubectl kustomize overlays/skala` 렌더에 REPLACE 0건, overlay가 전부 치환 |
| failure-notifier 네이밍 | "파일명 vs 리소스명 불일치" | CronJob명은 파일명과 일치. 불일치는 보조 리소스(Role/SA 등 `axis-cron-notifier`)와의 사이 |
| 섹터 taxonomy 정본 | infra판 추정 | **확정** — 코드 `src/config/sectors.py` = `ax/security/infra/deal(+other)` |
| 노출도 산식 정본 | infra판 추정 | **확정(2026-06-12 팀 결정): 코드가 정본** — `0.70·cluster + 0.30·mention, high≥0.65` (`preprocessing/classification.py:92`). 1차 미팅 스펙(0.50/0.30/0.20 3항)은 폐기, 문서가 코드를 따른다 |
| backend Flyway | "V1~V43 연속" | V1~V43 + **V32_5**(분수 버전) 44개, 중복 없음 — 연속성 문제는 아니나 표기 정정 |
| frontend api.ts 신선도 | "재생성 필요 가능성" | **확정 필요** — openapi.yaml 6/9 변경(`GET /api/global/trends` 추가, #51)이 api.ts(5/18)에 미반영 |
| 검증 통과(이상 없음 재확인) | — | _deprecated import 0건, ingestion_graph.py 부재, api↔agents 순환 실재(2파일), 인라인 style 85건, untracked 47건, bin/ 38파일 추적, FE에 router/zustand/react-query/vitest 부재 — 전부 1차 기재와 일치 |

---

## 3. 목표 상태 — "현업 수준 구조 관리"의 정의

1. **단일 진실 원천(SSoT)이 모호하지 않다**: API는 openapi.yaml, DB는 Flyway(V41+), 컨벤션은 CONVENTION.md, 운영 컨텍스트는 각 레포 CLAUDE.md — 각각 "이 파일이 기준"이라고 한 줄로 답할 수 있는 상태.
2. **문서는 코드와 같은 PR에서 갱신된다**: 구조를 바꾸는 PR이 CLAUDE.md/관련 문서 갱신을 포함하지 않으면 리뷰에서 반려.
3. **모듈 경계가 강제된다**: 의존 방향 규칙(공용 타입 → 도메인 → 조립부)이 문서가 아니라 도구(린트/CI)로 강제.
4. **파일 위생이 자동화된다**: untracked 장기 방치·복사본 파일·빌드 산출물 커밋이 사람 눈이 아니라 가드에 걸린다.
5. **모든 변경이 작은 PR로 흐른다**: 거대 파일은 "한 사람의 영지"가 되어 병렬 작업을 막는다 — 분해의 목적은 미학이 아니라 **충돌 표면적 축소**다.

---

## 4. 실행 계획

> **대원칙**: 발표(6/23) 전에는 *런타임 동작이 바뀌지 않는 변경*만 한다. 모든 서비스 레포 머지는 곧 운영 배포이기 때문이다. 구조 리팩토링은 전부 Phase 2(발표 후)로 격리한다.

### Phase 0 — 위생 (즉시 ~ 6/12, 무위험·동작 불변)

| 항목 | 레포 | 작업 | 담당 제안 |
|---|---|---|---|
| 0-1 | axis-ai | untracked 11건 처분 결정: 작업 중인 것(`fast_filter.py`+`urgent.py`, `test_parser_agents.py`)은 WIP 브랜치로 커밋해 백업, skeleton 4종(bigkinds/consensus/kipris/rss)은 커밋 or 삭제 결정, `tmp-cards/`·`egg-info/`는 .gitignore 추가 후 삭제 | 박진·심유정 |
| 0-2 | axis-ai | `src/agents/_deprecated/` 3파일 삭제 (import 0건 확인됨 — git 히스토리가 보존하므로 폴더 보관 불필요) | 김가은 |
| 0-3 | axis-backend | `.gitignore`에 `bin/` 추가 + `git rm -r --cached bin/` (소스 영향 0) | 박지원 |
| 0-4 | axis-infra | `api/openapi copy.yaml` 삭제, 로컬 `secret.skala 2.yaml`·`.env.skala.tmp.bak` 삭제, `.gitignore`에 macOS 복사본 패턴(`* [0-9].yaml`) 보강 | 본인 |
| 0-5 | axis-infra | untracked 문서(_archived/AI_AGENT_DESIGN.md 등) 커밋 or docs/_archived 이동 결정 | 본인 |
| 0-6 | axis-frontend | untracked 47건 — **팀원에게 목록 전달만** (처분은 그들 결정) | 안가은·최종민 |

**완료 기준**: 4개 레포 모두 `git status` 가 깨끗하거나, 남은 untracked가 "왜 남겼는지" 한 줄 설명 가능.

### Phase 1 — 문서 동기화 + 거버넌스 (발표 전, ~6/20, 동작 불변)

| 항목 | 작업 | 비고 |
|---|---|---|
| 1-1 | **4개 레포 CLAUDE.md 현행화** — ai: analysis_flow 7노드·신규 에이전트·디렉토리 실제 구조 반영. frontend: 이중 구조/커스텀 라우팅/Repository 패턴이라는 *실제*를 기술 (이상향 말고). backend: fixture-fallback 패턴 명문화. infra: 노출도 산식·섹터 taxonomy 정본 통일 — **완료 (2026-06-12)**: 산식은 코드 정본(`0.70/0.30, high≥0.65`)으로 팀 확정, 양 레포 CLAUDE.md 반영 | 문서 PR, 레포별 1건 |
| 1-2 | **문서 단일 소스 선언**: CONVENTION.md = 컨벤션 SSoT. `AXIS_개발표준정의서_infra_v1.0.md`·개발계획 v2/v3 → `docs/conventions/_archived/`. AGENTS.md는 "CLAUDE.md를 봐라" 3줄 포인터로 축소(Codex 호환용 잔존). README에 문서 지도 1절 추가 | infra docs-only |
| 1-3 | **schema.sql ↔ Flyway 관계 문서화**: "V40까지는 schema.sql 스냅샷 = 진실, V41+는 backend Flyway가 진실, 스냅샷은 마일스톤마다 재덤프" 프로세스를 docs/DB_METADATA.md에 명시 | 박지원과 합의 |
| 1-4 | **frontend 타입 신선도 확인**: openapi.yaml(6/9) 대비 api.ts(5/18) — 팀원에게 `openapi-typescript` 재생성 요청, diff 없으면 무변경 확인만 | 충돌 위험 0 |
| 1-5 | **발표 전 placeholder 체크리스트 실행 준비**: ingress ACM ARN, cronjob-profile-refresh 태그, BRIEFING_RECIPIENTS, delivery cron suspend 해제 — 기존 CLAUDE.md 체크리스트에 본 계획서 링크 | 발표 직전 |
| 1-6 | **PR 템플릿에 문서 갱신 체크박스** 추가 (4개 레포): "이 변경으로 CLAUDE.md/문서가 낡아지는가?" | .github/PULL_REQUEST_TEMPLATE.md |

### Phase 2 — 구조 리팩토링 (발표 후, 6/24~, 동작 변경 허용)

> 발표 후는 인수인계 기간이다. 리팩토링은 "인수자가 읽을 수 있는 코드"를 목표로 우선순위를 자른다. 전부 못 해도 위에서부터.

**axis-ai (효과 최대)**

| 순서 | 작업 | 방법 | 충돌 방지 |
|---|---|---|---|
| 2-A1 | 공용 타입 중앙화로 순환 의존 절단 | `src/types/`(또는 `src/contracts/`) 신설 → State/스키마/공용 모델 이동, 의존 방향: types ← {agents, pipeline, api, services} 단방향. import-linter로 CI 강제 | **이동만, 로직 무변경.** 한 PR = 한 모듈군 |
| 2-A2 | `briefing_generation_agent.py` 7,028줄 분해 | `agents/briefing/` 패키지로: generation / context / display_copy / synthesis. 공개 인터페이스(클래스명·메서드 시그니처) 불변 | 분해 전 스냅샷 테스트 — **LLM 호출은 mock 고정 필수**(실 LLM은 비결정적), 검증 대상은 프롬프트 조립·분기·출력 구조 |
| 2-A3 | `strategic_insight_agent.py` 6,071줄 동일 분해 | 〃 | 〃 |
| 2-A4 | 크롤러 BaseCrawler 템플릿 메서드 통일 | fetch/parse/post_process 추상화 | 소스 1개씩 이행 |
| 2-A5 | api/router.py 엔드포인트 테스트 (mock agent) | 우선 happy-path 전수 | — |

**axis-backend**

| 순서 | 작업 | 방법 |
|---|---|---|
| 2-B1 | `PeerOverviewTableService` 3분할: Query(JDBC) / Formatter / Cache | 분해 전 통합 테스트 1개로 현 응답 고정 |
| 2-B2 | `ApiContractFixtureService` → 도메인별 Fixture 클래스 (AuthFixture, CardFixture...) — 또는 contract-fixtures.json 로더 일반화 | 컨트롤러 의존 161곳을 도메인별로 좁힘 |
| 2-B3 | peer 목록 DB(`peer_companies`) 로드 전환, IP 대역·기간값 설정 외부화 | Flyway 불필요 (테이블 기존재) |
| 2-B4 | 거대 서비스 단위 테스트 (CardNews, GlobalSearch) | — |

**axis-frontend (팀원 주도, 우리는 의제만 제공)**

| 의제 | 내용 |
|---|---|
| 2-F1 | `app/` vs `features/` 단일화 로드맵: 미사용 features/ 중복 컴포넌트 삭제 또는 app/ 뷰의 features/ 이행 — **둘 중 하나로 선언** |
| 2-F2 | AxisPlanningViews.tsx 2,980줄 분해 |
| 2-F3 | 컴포넌트의 httpClient 직접 호출 → Repository 일원화 (현재 2건) |
| 2-F4 | 최소 테스트: 스모크 1개라도 — `"No tests yet"` 스크립트 제거 |
| 2-F5 | CLAUDE.md를 실구조로 재작성 (1-1과 동일하나 구조 확정 후 최종판) |

### Phase 3 — 지속 가드 (Phase 2와 병행)

| 가드 | 구현 | 레포 |
|---|---|---|
| 의존 방향 강제 | `import-linter` (ai) — layers 계약을 CI에 | axis-ai |
| 파일 비대화 경고 | CI에서 `wc -l` 상한(soft 1,500줄) 초과 신규/증가 파일에 PR 코멘트 (차단 아님) | 서비스 3레포 |
| 위생 자동화 | pre-commit: 복사본 패턴(` [0-9].`)·`bin/`·`egg-info` 차단 | 전 레포 |
| 계약 신선도 | infra openapi.yaml 변경 PR에 이미 자동 코멘트 존재(validate.yml) — frontend에 "api.ts 재생성 SHA 기록" 관행 추가 | frontend |
| cron 야간 창 | `validate-cron-window.py` (PR #59) — **머지 필요** | infra |
| 보안 스캔 | gitleaks(기존) + Trivy report-only(PR: backend#64/ai#124/frontend#77) → 노이즈 파악 후 CRITICAL 게이트 승격 | 서비스 3레포 |

---

## 5. 충돌·사고 방지 규칙 (작업 순서 의존성)

1. **리팩토링 PR과 기능 PR을 같은 파일에 동시에 열지 않는다.** 특히 거대 파일 분해(2-A2, 2-A3, 2-B1)는 해당 파일을 건드리는 다른 브랜치가 모두 머지된 "조용한 창"에서 시작하고, 시작을 팀 채널에 선언한다.
2. **이동(move)과 수정(modify)을 한 커밋에 섞지 않는다.** 파일 분해는 ①그대로 옮기기 ②리네임 ③수정의 3단계 커밋으로 — 리뷰와 git blame 보존.
3. **openapi.yaml을 건드리는 변경은 3-레포 동시 PR 세트로**: infra(spec) + frontend(api.ts regen) + backend/ai(구현) — 기존 validate.yml 자동 코멘트가 안내하는 절차를 강제 관행화.
4. **서비스 레포 develop 머지 = 운영 배포**임을 매 PR에서 의식한다. 리팩토링 PR은 "동작 불변" 증거(스냅샷/스모크 테스트 통과)를 PR 본문에 첨부.
5. **infra deploy 커밋(auto)과의 rebase 충돌**: infra에서 작업 브랜치가 오래 살면 `deploy:` 커밋들과 충돌한다. infra 브랜치는 수명 1~2일로 짧게.
6. **frontend는 팀원 소유**: 본 계획서의 frontend 항목은 전부 "의제"이며, 실행 여부·순서는 안가은·최종민이 결정한다.
7. **CronJob 신설 시** 07:00–22:59 KST 창 준수 (CI가 차단하지만, 설계 단계에서 인지).
8. **이미지/레지스트리**: ~~원인 미상 삭제 대비 스팟 체크~~ → **종결(6/11)**: 6/10 삭제는 Harbor 용량 포화로 인한 수동 정리였음. retention(최근 10개, 매일) 설정으로 용량 관리가 자동화돼 재발 조건 소멸. 옛 태그 404는 정상이며, 롤백 창(최근 ~10배포) 밖 롤백만 재빌드 선행.

---

## 6. 일정 요약

```
6/10 (오늘)   계획서 공유 + 팀 합의
6/11–6/12    Phase 0 위생 (레포별 30분 내외, 무위험)
6/13–6/20    Phase 1 문서 동기화 (CLAUDE.md 4건, 거버넌스, 타입 regen)
6/21–6/22    발표 직전 체크리스트 (placeholder, recipients, cron suspend)
6/23         발표
6/24–7/4     Phase 2 리팩토링 (ai 우선 → backend → frontend 협의)
             + Phase 3 가드 병행
```

## 7. 리스크 및 미결

| 리스크 | 완화 |
|---|---|
| 발표 준비와 Phase 1 병행 부담 | Phase 1은 전부 문서 작업 — 코드 프리즈와 무관, 분담 가능 |
| Phase 2 중 인수인계 시작 | "분해 완료"보다 "분해 방법 문서화"를 우선 — 못 끝내면 HANDOVER.md에 로드맵으로 남김 |
| Harbor 삭제 원인 미상 | 매니저 회신 대기. 자동 정리 정책이면 cleanup 워크플로 설계를 그에 맞춤 (작업 #2 보류 중) |
| 노출도 산식·섹터 taxonomy 정본 | **2차 검증으로 해소/구체화**: 섹터는 코드(`src/config/sectors.py`) = infra판(`ax/security/infra/deal/other`) 확정 → ai CLAUDE.md만 수정. 산식은 **코드 구현이 제3의 값** — `0.70·cluster_size + 0.30·company_mention, high≥0.65` (`src/preprocessing/classification.py:92`), 문서의 cluster_size_norm/tier1_diversity 산식은 미구현. "코드가 맞고 문서 갱신"인지 "코드가 확정 스펙에서 이탈"인지 **팀 의사결정 필요** |
| frontend 이중 구조 장기화 | 팀원 일정상 발표 후로 미뤄질 수 있음 — 최소한 "어느 쪽이 정본인지" 선언만 발표 전에 |

---

*본 문서는 docs-only 변경으로 develop에 직접 커밋됨. 갱신 시 이 헤더의 작성일을 수정할 것.*
