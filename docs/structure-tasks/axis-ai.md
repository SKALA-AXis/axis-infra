# axis-ai 구조 작업 목록

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 담당 제안: 김가은(리드) / 박진 / 심유정
> 규칙: Phase 0·1은 **동작 불변**. Phase 2는 발표(6/23) 후. 모든 PR은 작게 (이동과 수정 커밋 분리).

> **진행 현황 검증 (2026-06-14):** Phase 1 거의 완료, Phase 2 5개 중 4개(2-A1~A3, A5) 완료 — 발표 후로 미뤘던 분해를 선제 완료. 미완: Phase 0 위생(팀 WIP 처분), 2-A4(크롤러), CLAUDE.md 섹터 예시 1건.

## Phase 0 — 위생 (즉시, ~6/12)

- [~] **untracked 처분** — 부분(2026-06-14 실측): `*.egg-info/`는 `.gitignore` 추가됨 ✅. 나머지는 여전히 untracked = **팀원 WIP(심유정 크롤러 계열 등)** 이라 본인 백업/처분 결정 대기:
  - [ ] `src/crawler/fast_filter.py` + `src/crawler/monitors/urgent.py` (세트), `src/crawler/sources/{bigkinds,consensus,kipris,rss}.py` (skeleton 4종) — 작업자 결정
  - [ ] `tests/test_parser_agents.py`, `data/peer_financials/sk_ax.json`, `docs/AGENT_ARCHITECTURE_VERIFICATION.md`, `tmp-cards/` — 커밋 or 삭제 결정
  - [x] `src/axis_ai.egg-info/` — `.gitignore`에 `*.egg-info/` 추가 완료
- [ ] **`src/agents/_deprecated/` 3파일 삭제** (implication_agent, validation_agent_sc, weak_signal_agent — import 0건 확인됨) — **여전히 존재(2026-06-14)**. 삭제 PR 미수행
- [ ] 완료 기준: `git status` 깨끗, 또는 남은 항목에 사유 한 줄

## Phase 1 — 문서 동기화 (~6/20, 동작 불변)

- [x] **CLAUDE.md 현행화** (PR #142/#162, 6/11~12 — 구조·그래프·엔드포인트·산식 실측 교체):
  - [x] `ingestion_graph.py` 5노드 서술 → `analysis_flow_graph` 실측으로 교체 (CLAUDE.md "해당 파일 존재하지 않음" 명시)
  - [x] 미기재 주요 모듈 추가: today_insight / it_trend / integration / mixer / chat_orchestrator 기재 완료
  - [~] 트렌드 섹터: 정본 `ax/security/infra/deal/other` 반영됨. **단 IssueCard 예시 JSON의 `"sector": "ai_tech"` 1건 잔존** — 코드값으로 교체 필요 (axis-ai CLAUDE.md)
  - [x] 노출도 산식: **2026-06-12 팀 결정 = 코드 정본** (`0.70·cluster + 0.30·mention, high≥0.65`). ai·infra CLAUDE.md·PROJECT_STRUCTURE_PLAN §2.6 모두 확정 반영
  - [ ] LangGraph 버전 표기: CLAUDE.md "1.2.x" vs pyproject `langgraph>=0.1` — lock 실측값으로 통일 필요
- [ ] PR 템플릿에 "문서 갱신 필요 여부" 체크박스 추가

## Phase 2 — 리팩토링 (발표 후 6/24~, 우선순위순)

- [x] **2-A1. 공용 타입 중앙화로 순환 의존 절단 — 완료 (2026-06-12, PR #158)**
  - `src/contracts/` 신설 → chat_schemas·today_insight_schemas 이동, `src/api/`에 re-export shim 유지
  - [x] `import-linter` 도입 완료 — `agents must not import api`(allowlist 0건) + `contracts is a leaf layer` 계약, CI lint-imports 가동
- [x] **2-A2. `briefing_generation_agent.py` 분해 — 1·2단계 완료 (2026-06-12, PR #152/#154)**
  - `agents/briefing/` 패키지: support(185) / prompts(641) / data_layer(969) / basis_builder(889) / display_copy(938) — 본체 7,300→4,154줄(-43%), re-export 호환 유지
- [x] **2-A3. `strategic_insight_agent.py` 분해 — 1·2단계 완료 (2026-06-12, PR #151/#155)**
  - `agents/strategic_insight/` 패키지: prompts(468) / utils(110) / profile_linkage(2,127) — 본체 9,215→6,658줄(-28%). fallback만 잔여(렌더 텍스트 빌더와 결합)
- [ ] **2-A4. 크롤러 BaseCrawler 템플릿 메서드 통일** — fetch/parse/post_process 중복 제거, 소스 1개씩 이행. **미착수(2026-06-14)** — base_crawler.py는 추상 베이스만, 구현체 패턴 통일 전. crawler-jw/yj 팀원 활성 영역이라 잠잠해진 후 진행 (설계: [refactoring-architecture §2.3 R4](refactoring-architecture.md))
- [x] **2-A5. `api/router.py` 엔드포인트 테스트 — 완료 (2026-06-12, PR #157)**
  - `tests/test_router_endpoints.py` 21종 (17개 엔드포인트 happy-path + 에러 매핑). SSE 스트림만 범위 제외

## Phase 2+ — 계층화·재사용 (2026-06-14 전수 분석, 발표 후) → 상세: [refactoring-architecture.md](refactoring-architecture.md)

- [ ] **2-A6. 공용 LLM 클라이언트 팩토리** `src/llm/` 신설 — `_get_llm` **19곳 중복** 흡수 (모델·temperature·토큰캡·`response_format`·gpt-5 `reasoning_effort`·`to_thread` 격리 1곳에). **최고 ROI·최저 위험(leaf)**. gpt-5 분기는 이미 mixer·today_insight·briefing 3곳 복붙 상태 — 더 자라기 전 정리
- [ ] **2-A7. JSON/텍스트 헬퍼** `src/shared/` 신설 — `_json_dict`/`_json_list`/`_safe_json_*` ~10곳 중복 흡수
- [ ] **2-A8. preprocessing ↔ analysis 순환 의존 절단** + import-linter 계약 추가 (현재 relevance↔summarizer 등 순환)
- [ ] **2-A9. 거대 파일 분해** (characterization test 선행): `analysis/summarizer.py`(3,632) fact/summary/validator 분리 · `composers/card_news_composer.py`(4,096) LLM호출→llm/ 이관 후 format/render 분리 · `db/article_store.py`(3,028) raw/card/evidence store 분리
- [ ] **2-A10. 거대 파일 추가 식별**: card_news_composer 4,096 · summarizer 3,632 · article_store 3,028 · today_insight 2,990 · peer_swot_llm_preview 2,558 — 1차 계획서엔 없던 실측 거대 파일들

## 참고 실측치

| 파일 | 줄 수 |
|---|---|
| src/agents/briefing_generation_agent.py | 7,028 |
| src/agents/strategic_insight_agent.py | 6,071 |
| src/parsers/ir_parser.py | ~3,836 |
| src/analysis/summarizer.py | ~3,040 |
| src/db/article_store.py | ~2,749 |
| src/api/router.py | 898 (테스트 0) |

테스트: 36개 파일, 모듈 커버 추정 ~47%. 잘 지켜지는 것: ingestion/delivery 그래프 분리, config 외부화, uv+lock, cron 의존성 그룹.
