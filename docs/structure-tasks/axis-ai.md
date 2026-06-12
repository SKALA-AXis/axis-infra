# axis-ai 구조 작업 목록

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 담당 제안: 김가은(리드) / 박진 / 심유정
> 규칙: Phase 0·1은 **동작 불변**. Phase 2는 발표(6/23) 후. 모든 PR은 작게 (이동과 수정 커밋 분리).

## Phase 0 — 위생 (즉시, ~6/12)

- [ ] **untracked 11건 처분** — 현재 로컬에만 존재 = 백업 없음. 각 파일 결정:
  - [ ] `src/crawler/fast_filter.py` + `src/crawler/monitors/urgent.py` — 작업 중이면 WIP 브랜치로 커밋해 백업, 폐기면 삭제 (urgent.py가 fast_filter import 중 — 세트로 처리)
  - [ ] `src/crawler/sources/{bigkinds,consensus,kipris,rss}.py` — skeleton 4종: 커밋(향후 구현 의사 있으면) or 삭제
  - [ ] `tests/test_parser_agents.py` — 내용 확인 후 커밋 or 삭제
  - [ ] `data/peer_financials/sk_ax.json` — 커밋 (다른 peer json은 tracked)
  - [ ] `docs/AGENT_ARCHITECTURE_VERIFICATION.md` — 커밋
  - [ ] `tmp-cards/` — 삭제, `src/axis_ai.egg-info/` — `.gitignore`에 `*.egg-info/` 추가 후 삭제
- [ ] **`src/agents/_deprecated/` 3파일 삭제** (implication_agent, validation_agent_sc, weak_signal_agent — import 0건 확인됨, 히스토리가 보존)
- [ ] 완료 기준: `git status` 깨끗, 또는 남은 항목에 사유 한 줄

## Phase 1 — 문서 동기화 (~6/20, 동작 불변)

- [x] **CLAUDE.md 현행화** (PR #142, 6/11 — 구조·그래프·엔드포인트·산식 실측 교체):
  - [ ] `ingestion_graph.py` 5노드 서술 → 실제 `pipeline/analysis_flow_graph.py`(966줄, issue_integrate→…→card_writer 7노드)로 교체
  - [ ] 미기재 주요 모듈 추가: `today_insight_agent`, `it_trend_agent`, `integration_agent`, `mixer_analysis_agent`, `chat_orchestrator_agent`, `analysis_pipeline.py`
  - [ ] 트렌드 섹터: 코드 정본 확정됨 (`src/config/sectors.py` = `ax/security/infra/deal/other`) → ai CLAUDE.md의 `security/ai_tech/large_deal/sk_ax_biz/other` 서술을 코드값으로 교체
  - [ ] 노출도 산식: **구현(`src/preprocessing/classification.py:92`)은 `0.70·cluster_size + 0.30·company_mention, high≥0.65`로, ai·infra CLAUDE.md 양쪽 산식과 모두 다름.** "코드가 맞다(문서 갱신)" vs "코드가 1차 미팅 확정 스펙에서 이탈했다(코드 수정)"를 팀이 결정한 뒤 문서/코드 일치시킬 것
  - [ ] LangGraph 버전 표기 통일 (ai CLAUDE.md 1.1.x vs infra 0.2.x vs pyproject `langgraph>=0.1`)
- [ ] PR 템플릿에 "문서 갱신 필요 여부" 체크박스 추가

## Phase 2 — 리팩토링 (발표 후 6/24~, 우선순위순)

- [ ] **2-A1. 공용 타입 중앙화로 순환 의존 절단** — api↔agents↔services↔pipeline 순환 해소
  - `src/types/`(or `contracts/`) 신설 → State·공용 Pydantic 모델 이동 (이동만, 로직 무변경)
  - 의존 방향 규칙: `types ← {agents, pipeline, api, services}` 단방향
  - [ ] `import-linter` 도입, CI에 layers 계약 추가
- [x] **2-A2. `briefing_generation_agent.py` 분해 — 1·2단계 완료 (2026-06-12, PR #152/#154)**
  - `agents/briefing/` 패키지: support(185) / prompts(641) / data_layer(969) / basis_builder(889) / display_copy(938) — 본체 7,300→4,154줄(-43%), re-export 호환 유지
- [x] **2-A3. `strategic_insight_agent.py` 분해 — 1·2단계 완료 (2026-06-12, PR #151/#155)**
  - `agents/strategic_insight/` 패키지: prompts(468) / utils(110) / profile_linkage(2,127) — 본체 9,215→6,658줄(-28%). fallback만 잔여(렌더 텍스트 빌더와 결합)
- [ ] **2-A4. 크롤러 BaseCrawler 템플릿 메서드 통일** — fetch/parse/post_process 중복 제거, 소스 1개씩 이행
- [ ] **2-A5. `api/router.py`(898줄) 엔드포인트 테스트** — mock agent로 happy-path 전수

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
