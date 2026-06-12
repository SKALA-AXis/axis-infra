# 거대 에이전트 분해 설계서 (Phase 2-A2/A3 실행안)

> 2026-06-11 실측 분석 기반 · **2026-06-12 1단계 완료** — strategic_insight PR #151 머지(9,215→8,675줄), briefing PR #152 오픈(7,300→5,651줄). 상위: [axis-ai.md](axis-ai.md) · [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md)
> 대상: `briefing_generation_agent.py` **7,292줄**(~310 정의) / `strategic_insight_agent.py` **9,215줄**(~298 정의) — 후자는 6/10 측정(6,071줄) 후 하루 만에 +3,000줄. **분해 전까지 계속 자란다.**

## 원칙

1. **공개 인터페이스 불변** — 외부 호출은 단 3곳 (`api/router.py:316`, `pipeline/analysis_flow_graph.py:42`, `agents/analysis_graph_runner.py:26`)이 클래스만 import → 클래스는 원파일에 유지, 내부 함수만 이동.
2. **이동만, 수정 없음** — 커밋 단위: ①그대로 이동 ②import 갱신 ③(별도) 정리. git blame 보존.
3. **선행 테스트** — 분해 전 mock-LLM 스냅샷 테스트로 현 동작 고정 (프롬프트 조립 결과·출력 dict 구조).
4. **팀 선언 후 조용한 창에서** — 두 파일 모두 핫함 (이번 주 매일 커밋됨).

## 1단계 — 저결합 분리 (즉시 가능, 낮은 위험)

| 신규 모듈 | 출처 | 실측 결과 | 결합도 |
|---|---|---|---|
| ✅ `agents/briefing/support.py` | **설계에 없던 신규 (2026-06-12)** — prompts/data_layer 양쪽이 의존하는 공유 leaf 18종 (`_json_dict`, `_analysis_package*`, `KST` 등). 순환 의존 없이 양쪽을 분리하려면 공유 계층이 선행돼야 함 | 185줄 (PR #152) | ⭐ leaf |
| ✅ `agents/briefing/prompts.py` | 프롬프트·스키마 빌더 9개 | 641줄 (PR #152) | ⭐ 독립 |
| ✅ `agents/briefing/data_layer.py` | DB 페칭·정규화 30 정의 (자체 `log` 로거) | 969줄 (PR #152) | ⭐⭐ |
| ✅ `agents/strategic_insight/prompts.py` | LLM 프롬프트 상수 12개 | 468줄 (PR #151 머지) | ⭐ 독립 |
| ~~`agents/strategic_insight/fallback.py`~~ | **1단계에서 제외 (2026-06-12 실측)** — AST 의존 분석 결과 폴백 17함수가 본체 정의 34개(event_based/profile_linked 텍스트 빌더 등)를 참조, "거의 독립" 평가는 코드 성장으로 무효화됨. 도메인 텍스트 빌더 군과 함께 2단계로 | ~650줄 | ⭐⭐⭐⭐ (재평가) |
| ✅ `agents/strategic_insight/utils.py` | 텍스트/JSON/한글 유틸 | 110줄 (PR #151 머지) | ⭐ |

→ 1단계 결과: strategic_insight 9,215→8,675줄(#151), briefing 7,300→**5,651줄**(#152) — 합계 **~2,200줄 감량**, 충돌 표면적 즉시 축소.
→ 교훈: 두 그룹이 공유하는 leaf 심볼은 별도 `support.py`를 먼저 추출해야 함 (briefing에서 `_json_dict` 등 3종이 양쪽 의존에 겹침). 테스트 monkeypatch는 re-export가 아닌 **실호출자 모듈**을 패치해야 효과 있음.

## 2단계 — 고수익·중난이도 ✅ 완료 (2026-06-12, PR #154/#155 머지)

| 신규 모듈 | 출처 | 실측 결과 | 비고 |
|---|---|---|---|
| ✅ `agents/strategic_insight/profile_linkage.py` | 연계 평가 엔진(스코어 4종)+프로파일 압축+**신호 기반층**(토큰 정규화·역할 판별·노이즈 필터) | 2,127줄·75정의 (PR #155) | 설계 추정 ~1,100줄보다 큰 것은 신호 기반층이 설계 후 성장했기 때문 — AST 폐쇄로 경계 닫음. 본체 8,675→6,658줄 |
| ✅ `agents/briefing/basis_builder.py` | 기초 합성→LLM 정제→synthesis 병합 + LLM 게터·프롬프트 버전 상수·공유 텍스트 유틸 | 889줄·36정의 (PR #154) | |
| ✅ `agents/briefing/display_copy.py` | **설계에 없던 신규** — 화면 문구 검증·병합·수리 계층 (`_repair_sk_ax_view_descriptions` 폐쇄 21심볼 포함) | 938줄·44정의 (PR #154) | 본체 5,651→4,154줄 |

→ 2단계 경계 판단 기록: `_refine_display_copy_with_llm`·`_display_copy_context`·`_refresh_contract_payload`·`_merge_display_copy`는 본체 유지 — `_display_copy_context`가 `_front_*` 렌더링 웹 105심볼을 통째로 끌고 옴 (아래 분리 금지 영역).
→ 최종: 두 에이전트 합계 16,515줄(분해 전) → 본체 10,812줄 + 분리 모듈 9개. 남은 후보는 렌더링 웹의 `briefing/render/` 패키지화(검토만)와 strategic_insight fallback(2단계 이관분)뿐.

## 분리 금지 영역 (강결합 — 억지로 쪼개면 악화)

- briefing의 `_front_*` 렌더링 50함수 (줄 5525-6750): 도메인 로직 섬세 결합 ⭐⭐⭐⭐⭐ — 분해 대신 향후 `briefing/render/` 패키지화만 검토
- strategic_insight의 오케스트레이션+3-tier 품질게이트+수리 루프 (줄 598-1639): 상태 공유가 본질 — 클래스에 유지

## 실행 체크리스트 (모듈 1개당 1 PR)

- [ ] 팀 채널 선언 + 해당 파일 건드는 열린 브랜치 0 확인
- [ ] mock-LLM 스냅샷 테스트 작성·통과 (선행 1회)
- [ ] 이동 커밋 → import 갱신 커밋 → 게이트 4종(ruff/format/mypy/pytest) + lint-imports
- [ ] PR 본문에 "동작 불변" 증거(스냅샷 테스트 결과) 첨부
