# AXIS 리팩토링 아키텍처 설계서 (Phase 2+)

> **작성**: 2026-06-14 · **기반**: 4개 레포 전수 코드 분석(줄 수·import 방향·중복 정의 실측)
> **상위**: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · **레포별 작업**: [axis-ai](axis-ai.md) · [axis-backend](axis-backend.md) · [axis-frontend](axis-frontend.md)
> **목표**: 체크리스트형 "분해"를 넘어 **계층화(layering)·재사용성(reuse)·테스트 가능성(testability)** 을 코드 품질 지표로 삼는 현업 수준 리팩토링. 발표(6/23) 후 착수.

---

## 1. 설계 원칙 (4레포 공통)

리팩토링은 "큰 파일을 쪼갠다"가 아니라 **책임을 계층에 정렬하고, 반복을 단일 출처로 모으고, 그 결과를 테스트로 잠그는** 작업이다. 다음 5원칙을 모든 항목에 적용한다.

1. **동작 불변 + characterization test 선작성** — 리팩토링 전, 현 동작을 고정하는 테스트를 먼저 만든다. LLM 호출은 mock 으로 고정하고 **결정적 부분(프롬프트 조립·응답 파싱·검증·DTO 변환)만** 검증한다. 테스트 없는 거대 모듈은 분해 전에 안전망부터.
2. **Strangler-fig + re-export shim** — 이동 → 본체에 re-export 남김 → 호출처 점진 이행. briefing/strategic_insight 분해(#151/#152/#154/#155)에서 검증된 패턴. 한 번에 갈아엎지 않는다.
3. **단방향 의존 + 자동 강제** — 계층 의존은 한 방향만. ai 는 `import-linter`, backend 는 ArchUnit(또는 패키지 의존 테스트), frontend 는 ESLint `no-restricted-imports`/의존 규칙으로 **CI 에서 강제**한다. 사람 리뷰에 의존하지 않는다.
4. **작은 PR, 커밋 분리** — "이동" 커밋과 "수정" 커밋을 분리해 git blame·리뷰 가능성 보존. 모듈 1개당 1 PR.
5. **정량 게이트로 완료 판정** — "깔끔해졌다"가 아니라 측정값으로(파일 최대 줄 수, 계층 위반 0, 중복 정의 수, 커버리지). §5 참조.

---

## 2. axis-ai — 타깃 계층 모델

### 2.1 현황 진단 (2026-06-14 실측)

- 거대 파일 30개가 전체 LOC 의 ~68% 차지. 상위: strategic_insight 6,653 / briefing_generation 4,154 / **card_news_composer 4,096** / ir_parser 3,835 / **summarizer 3,632** / **article_store 3,028** / today_insight 2,990 / mixer 2,727 / **peer_swot_llm_preview 2,558** / chat_orchestrator 2,438.
- **`_get_llm` 정의가 19개 파일에 중복** (agents 11 · services·preprocessing·extractors·composers 8). LLM 모델·temperature·max_tokens·`response_format`·`reasoning_effort`(gpt-5 분기)·`to_thread` 격리가 제각각. gpt-5 분기는 mixer·today_insight·briefing **3곳에 복붙**(2026-06-13 briefing 추가가 3번째 — 중복이 계속 자란다는 증거).
- JSON 헬퍼(`_json_dict`/`_json_list`/`_json_dumps`/`_safe_json_*`)가 ~10개 파일에 중복.
- 순환 의존: `preprocessing/` ↔ `analysis/`. agents·services → db 직접 호출 산재.

### 2.2 타깃 계층 (의존은 위 → 아래 단방향)

```
api/ (FastAPI router)
  ↓
agents/ ── 오케스트레이션만: 그래프 조립, 단계 호출, 흐름 제어
  ↓        (LLM 호출은 llm/ 위임, 파싱은 shared/ 위임, 도메인 계산은 services/ 위임)
services/ analysis/ preprocessing/ composers/ ── 도메인 로직 (검증·정규화·요약·변환)
  ↓        (preprocessing↔analysis 순환 제거)
llm/  shared/  crawler/base/ ── 공용 인프라·유틸 (신설)
  ↓
db/ rag/ config/ contracts/ ── 리프 (부작용 격리)
```

### 2.3 재사용 추출 카탈로그 (이득 큰 순)

| # | 추출물 | 신규 위치 | 흡수 대상 | 효과 | 위험 |
|---|---|---|---|---|---|
| ✅ **R1** | **공용 LLM 클라이언트 팩토리 — 완료(2026-06-14, PR #177~#183)** | `src/llm/`(LLMSpec+build_chat_llm, leaf) | LLM 생성 21곳 중 20곳 | gpt-5 reasoning_effort(옵셔널)·json_object·토큰캡·timeout/retries 단일 출처화. import-linter `llm is a leaf` 계약. summarizer 1곳은 base+bind 패턴 의도적 예외 | 낮음 (각 배치 라이브 kwargs 동등성 검증, 동작 불변) |
| ✅ **R2** | **JSON 헬퍼 단일 출처화 — 완료(2026-06-14, PR #184)** | `src/shared/json_helpers.py`(leaf) | `_json_dict` 4곳 + `_json_dumps` 2곳 (구현 동일분만) | 통합. import-linter `shared is a leaf` 계약 | 낮음 |
| ⚠️ **R3 (보류·재평가)** | ~~LLM 호출 격리 래퍼~~ | — | — | **2026-06-14 조사: 깨끗한 통합 아님.** `.invoke()` 가 전부 sync 헬퍼 내부에 박혀 있고(messages/prompt/config/override 제각각) `to_thread` 격리는 이미 에이전트 메서드 레벨에 구조적으로 적용됨. 공용화하려면 sync 헬퍼를 async 재구조화 → 동작 변경. 이득 대비 위험 높아 보류 | (제외) |

> **R2 통합 제외분(구현 갈라짐)**: `_json_list` 3곳(non-list 파싱 결과 `[]`/`[parsed]`/`[value]` 상이), `_parse_json_loose` 2곳(any-type vs dict-only), today_insight `_json_dumps`(`_json_ready` 전처리), it_trend `_safe_json_object`, summarizer `_safe_json_loads` — 통합 시 회귀라 의도적 제외(json_helpers docstring 명시).
| **R4** | **크롤러 fetch/parse 베이스** | `src/crawler/base/{fetchers,parsers}.py` | sources/* 의 httpx/Playwright/requests·날짜파싱 중복 | 신규 크롤러 보일러플레이트 ~50%↓ | 중간 (소스 1개씩 이행) |

> R1 은 **이번 세션 briefing gpt-5 작업이 만든 중복**을 정리하는 것이기도 하다. 가장 먼저, 가장 안전하게(leaf) 착수 가능.

### 2.4 거대 파일 분해 로드맵 (책임 분리)

| 파일 | 줄 수 | 분해 방향 (책임별) | 선행 |
|---|---|---|---|
| `analysis/summarizer.py` | 3,632 | fact_extractor(LLM) / summary_generator(LLM) / validator / selector | characterization test |
| `composers/card_news_composer.py` | 4,096 | classify·summary(LLM 호출→llm/) / format / render 분리 | R1 선행 시 자연 축소 |
| `db/article_store.py` | 3,028 | raw_store / card_store / evidence_store / metadata_normalizer (CQRS 성격 분리) | 통합 테스트 |
| `parsers/ir_parser.py` | 3,835 | 책임은 단일(정규식 추출)이나 섹션별 모듈 분할로 가독성·테스트 | 회귀 fixture |
| strategic_insight / briefing | (분해 완료) | fallback·render 잔여만 향후 검토 | — |

### 2.5 ai 실행 순서

1. ✅ **R1 공용 LLM 팩토리** (완료) → 2. ✅ **R2 JSON 헬퍼** (완료) → 3. ~~R3 격리 래퍼~~ (보류·재평가, 위 표) → 4. ~~preprocessing↔analysis 순환 절단~~ → **2026-06-14 실측: 순환 없음**(preprocessing→analysis 단방향 1건, 역방향 0건. 계획 시점 진단은 무효 — 이미 단방향) → 5. **(다음) summarizer/card_news_composer/article_store 분해** — characterization test 선행, 분리는 briefing/strategic_insight 와 동일한 AST 추출+re-export 패턴 → 6. R4 크롤러 베이스(2-A4, 크롤러 팀 잠잠해진 후).

---

## 3. axis-backend — 타깃 계층 모델

### 3.1 현황 진단 (2026-06-14 실측)

- 거대 서비스: **PeerOverviewTableService 2,656줄**(JDBC ~850 + DTO변환 ~800 + 캐싱 ~200 + 계산 ~600 혼재), DashboardKeywordTrendChartService 906, KeywordGraphService 793, CardNewsService 761(변환 680), GlobalSearchService 592.
- 계층 침범: service 안에 복잡 SQL 직접 작성(`query/` 패키지 있으나 미활용), DTO↔Entity 변환이 3개 서비스에 분산 중복.
- peer 5사 하드코딩 4곳. AI fallback try-catch 가 컨트롤러 4곳 중복.
- `ApiResponse.success()` 188회 — 래퍼 자체는 표준화 양호.

### 3.2 타깃 계층

```
controller/ ── HTTP 경계만 (service 1개 주입 원칙)
  ↓
service/ ── 비즈니스 오케스트레이션 (SQL·변환 직접 보유 금지)
  ↓
query/(JDBC 조회)   formatter/(DTO 변환, 신설)   repository/(JPA)
  ↓
domain/
```

### 3.3 재사용·계층화 항목

| # | 항목 | 효과 |
|---|---|---|
| **B-R1** | `PeerCompanyProvider` 신설 → `peer_companies` 테이블 로드 | peer 하드코딩 4곳 → 1곳. 5사 변경 시 코드 무수정 |
| **B-R2** | `formatter/` 패키지 신설 (CardNewsFormatter·PeerOverviewFormatter·KeywordGraphFormatter) | DTO 변환 중복 중앙화, 단위 테스트 용이 |
| **B-R3** | `query/` 패키지로 service 내 SQL 이관 (PeerOverviewQuery·GlobalSearchQuery 등) | service 의 SQL ~1,800줄 → ~200줄. 쿼리 재사용·테스트 |
| **B-R4** | AI fallback AOP/공통 래퍼 | 컨트롤러 4곳 중복 → 1곳 |

### 3.4 대표 분해 — PeerOverviewTableService (2,656 → 3계층)

`PeerOverviewQuery`(JDBC ~600) + `PeerOverviewFormatter`(변환 ~700) + `PeerOverviewTableService`(오케스트레이션·캐싱 ~400). **선행: 현 응답 고정 통합 테스트 1개.**

### 3.5 backend 실행 순서

1. **B-R1 PeerCompanyProvider**(2~3일, 빠른 승리) → 2. PeerOverviewTableService 통합테스트 → 3. **B-R3+B-R2 로 3분할** → 4. CardNewsService 변환 분리 → 5. 거대 서비스 단위 테스트(2-B4) → 6. B-R4 fallback AOP → 7. ArchUnit 계층 테스트 CI 추가.

---

## 4. axis-frontend — 타깃 구조 (의제: 안가은·최종민 주도)

### 4.1 현황 진단 (2026-06-14 실측)

- **이중 구조**: app/(28,753줄/106 TSX, 실사용) vs features/(10,759줄/25 feature). 동일 이름 뷰 6쌍 중복 — 렌더되는 건 전부 app/, features/ 동명본은 dead.
- ⚠️ **(2026-06-14 정정) dead code 판정 오류**: AxisPlanningViews·app/shell 은 develop **미추적 로컬 파일**(git ls-files 0). 레포 dead code 아님 — 작업트리 오염 오판.
- 거대 컴포넌트(tracked 실측): MixerView 1,993 / KeywordGraphView 1,169 / HomeDashboardView 1,103 / PeerPlusView 935 / BriefingsView 884 (fetch+상태+렌더+비즈로직 혼재).
- Repository 패턴: 10 feature 우수 채택, 그러나 keyword-graph 는 `httpClient` 직접 호출 2건(우회), home·admin·keyword-graph feature 구조 미완.
- 테스트 0개, 인라인 style ~120건. (any 타입 0 · 자동생성 api.ts 규칙 준수 — 양호)

### 4.2 타깃 구조 제안

```
feature 표준: features/<도메인>/{api(Repository)/hooks/model/components/mappers}
  · 화면 = container(데이터·상태) + presentational(렌더) 분리
  · 모든 API 는 Repository 경유 (httpClient 직접 호출 금지 — ESLint 강제)
  · app/ ↔ features/ 수렴 방향 1개 선언 후 일괄 이행
```

### 4.3 frontend 의제 (우선순위)

| 우선 | 항목 | 근거 |
|---|---|---|
| ~~P0~~ | ~~dead code 제거~~ — **취소(2026-06-14): 대상이 develop 미추적 로컬 파일, 레포에 없음** | git ls-files 0 |
| P0 | **app↔features 수렴 방향 결정** (권장: features/ 로 통일) | 6쌍 중복의 근원 |
| P1 | keyword-graph Repository 신설 → httpClient 직접 호출 2건 제거 | 패턴 일관성 |
| P1 | home·admin feature 구조 정규화 | 표준 미완 3곳 |
| P2 | MixerView·HomeDashboardView container/presentational 분해 | 1,000줄+ 책임 혼재 |
| P2 | 차트 설정 wrapper 추출, 인라인 style → CSS var/class | 반복 감소 |
| P3 | 테스트 도입(스모크→단위), `"No tests yet"` 제거 | 커버리지 0 |

---

## 5. 품질 게이트 (완료 판정 기준)

리팩토링 PR 은 아래 정량 기준을 충족해야 머지한다.

| 레포 | 게이트 |
|---|---|
| **공통** | 동작 불변 증빙(characterization test 결과 첨부) · 계층 위반 0(자동 검사) · 커밋 분리(이동/수정) |
| **axis-ai** | 신규 파일 soft 1,500줄 / hard 2,500줄 · `lint-imports` green(순환 0) · ruff+mypy+pytest · `_get_llm` 중복 19→1 |
| **axis-backend** | 클래스 500줄 이하 지향 · ArchUnit 계층 테스트 green · 거대 서비스 단위 커버리지 ≥70% · peer 하드코딩 4→1 |
| **axis-frontend** | 컴포넌트 600줄 이하 지향 · `httpClient` 직접 호출 0(ESLint) · type-check green · dead code 0 |

### 추적 메트릭 (분기별 기록)

| 메트릭 | 현재(2026-06-14) | 목표 |
|---|---|---|
| ai `_get_llm` 중복 정의 | 19 | 1 |
| ai 거대 파일(>2,500줄) | 9 | ≤4 |
| backend 거대 서비스(>500줄) | 5 | 0 |
| backend service 내 SQL 라인 | ~1,800 | ~200 |
| frontend dead code | (해당 없음 — 오판 정정) | — |
| frontend 컴포넌트(>1,000줄) | 5 | 0 |
| frontend 테스트 | 0 | 스모크+핵심 단위 |

---

## 6. 마스터 실행 순서 (발표 후, 6/24~)

병렬 가능하되 레포 내부는 순서 의존. **각 레포 "빠른 승리(leaf·저위험)" 먼저** → 동기 확보 후 대형 분해.

1. **Week 1 (저위험 재사용 추출)**: ai R1 LLM 팩토리 + R2 JSON 헬퍼 · backend B-R1 PeerCompanyProvider · frontend: 로컬 untracked 47건 점검(작업자)
2. **Week 2~3 (계층 분리)**: ai summarizer/article_store 분해 · backend PeerOverviewTableService 3분할 · frontend keyword-graph Repository + 수렴 방향 결정
3. **Week 3~4 (테스트·강제)**: 거대 모듈 characterization/단위 테스트 · import-linter/ArchUnit/ESLint 계층 계약 CI 추가
4. **지속**: ai 크롤러 베이스(2-A4) · frontend 거대 컴포넌트 분해 · backend fallback AOP

> 원칙: 새 추상화(llm/·shared/·formatter/)는 **만들고 → 1곳 적용·검증 → 나머지 점진 이행**. 19곳을 한 PR 에 바꾸지 않는다.
