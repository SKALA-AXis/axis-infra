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
  - 🔥 **(2026-06-15) 재증식 6,658→11,705** — 3일간 팀원 활성 커밋(industry-action·evidence·frontend-ready gate)으로 분해 전보다 커짐. **재분해는 발표 후 + 코딩 프리즈 합의 후 최우선** (교훈: 핫 파일 분해 ROI 는 동결 없이는 며칠 만에 소멸 — [refactoring-architecture §2.4](refactoring-architecture.md))
- [ ] **2-A4. 크롤러 BaseCrawler 템플릿 메서드 통일** — fetch/parse/post_process 중복 제거, 소스 1개씩 이행. **미착수(2026-06-14)** — base_crawler.py는 추상 베이스만, 구현체 패턴 통일 전. crawler-jw/yj 팀원 활성 영역이라 잠잠해진 후 진행 (설계: [refactoring-architecture §2.3 R4](refactoring-architecture.md))
- [x] **2-A5. `api/router.py` 엔드포인트 테스트 — 완료 (2026-06-12, PR #157)**
  - `tests/test_router_endpoints.py` 21종 (17개 엔드포인트 happy-path + 에러 매핑). SSE 스트림만 범위 제외

## Phase 2+ — 계층화·재사용 (2026-06-14 전수 분석, 발표 후) → 상세: [refactoring-architecture.md](refactoring-architecture.md)

- [x] **2-A6. 공용 LLM 클라이언트 팩토리 — 완료 (2026-06-14, PR #177~#183, 7배치)**
  - `src/llm/`(leaf) `LLMSpec`+`build_chat_llm` 신설. gpt-5 `reasoning_effort`(옵셔널 None)·json_object 래핑·토큰캡 분기·timeout/max_retries 를 단일 출처화. import-linter `llm is a leaf` 계약 추가
  - **LLM 생성 사이트 21곳 중 20곳 이행** (각 배치 라이브 ChatOpenAI 가로채기로 kwargs 동등성 검증 + env gpt-5 강제 케이스 reasoning 미전달 보존). summarizer 1곳은 base+bind 패턴이라 의도적 예외(주석), `_deprecated/` 3곳 폐기 제외
  - 부가 수확: peer_swot 모듈레벨 ChatOpenAI import(무거운 임포트 규칙 위반) 해소, 1차 조사 누락 사이트(peer_swot·router gen-search) 발견·이행
  - (선택 잔여) 캡 resolver 중복(`_llm_max_completion_tokens` 3곳)을 `LLMSpec(max_tokens_reasoning=)`로 흡수 — 가치 낮아 보류
- [x] **2-A7. JSON 헬퍼 `src/shared/` — 완료 (2026-06-14, PR #184)**
  - `json_dict`(동일 4곳)·`json_dumps`(동일 2곳)만 흡수. `_json_list`(3곳 구현 갈라짐)·`_parse_json_loose`(2곳)·today_insight `_json_dumps`·`_safe_json_*` 는 회귀 위험으로 의도적 제외(docstring 명시). import-linter `shared is a leaf` 계약 추가
- [ ] **2-A8. ~~preprocessing ↔ analysis 순환 절단~~ → 순환 없음 확인(2026-06-14)**. 대신 **import-linter allowlist 계약**으로 `services→db`(25)·`agents→db`(10) 신규 직접 호출 차단(기존 묵인)
- [ ] **2-A9. 거대 파일 분해** (발표 후·동결 후, characterization test 선행): strategic_insight(11,705) **최우선** · briefing(4,761) 잔여 · summarizer(3,636) · card_news_composer(3,763, LLM호출→llm/ 이관 후 format/render) · article_store(3,071) raw/card/evidence store 분리
- [ ] **2-A10. 발표 전 저위험 최적화**: to_thread 누락 3곳(router gen-search·classification·peer_swot) · article_store 건당→배치 upsert · LLM 응답 추출 헬퍼(R2 연장)

## 참고 실측치

| 파일 | 줄 수(2026-06-15, git-tracked) |
|---|---|
| src/agents/strategic_insight_agent.py | **11,705** 🔥 (6/12 분해 6,658 → 재증식) |
| src/agents/briefing_generation_agent.py | 4,761 |
| src/parsers/ir_parser.py | 3,835 |
| src/composers/card_news_composer.py | 3,763 |
| src/analysis/summarizer.py | 3,636 |
| src/db/article_store.py | 3,071 |
| src/agents/today_insight_agent.py | 3,037 |
| src/agents/mixer_analysis_agent.py | 2,955 |
| src/agents/peer_swot_llm_preview.py | 2,561 |
| src/api/router.py | ~900 (엔드포인트 테스트 완료, PR #157) |

테스트: 44개 파일. 잘 지켜지는 것: ingestion/delivery 그래프 분리, config 외부화, uv+lock, cron 의존성 그룹, R1 LLM 팩토리·R2 JSON 헬퍼.
