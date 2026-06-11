# 거대 에이전트 분해 설계서 (Phase 2-A2/A3 실행안)

> 2026-06-11 실측 분석 기반. 상위: [axis-ai.md](axis-ai.md) · [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md)
> 대상: `briefing_generation_agent.py` **7,292줄**(~310 정의) / `strategic_insight_agent.py` **9,215줄**(~298 정의) — 후자는 6/10 측정(6,071줄) 후 하루 만에 +3,000줄. **분해 전까지 계속 자란다.**

## 원칙

1. **공개 인터페이스 불변** — 외부 호출은 단 3곳 (`api/router.py:316`, `pipeline/analysis_flow_graph.py:42`, `agents/analysis_graph_runner.py:26`)이 클래스만 import → 클래스는 원파일에 유지, 내부 함수만 이동.
2. **이동만, 수정 없음** — 커밋 단위: ①그대로 이동 ②import 갱신 ③(별도) 정리. git blame 보존.
3. **선행 테스트** — 분해 전 mock-LLM 스냅샷 테스트로 현 동작 고정 (프롬프트 조립 결과·출력 dict 구조).
4. **팀 선언 후 조용한 창에서** — 두 파일 모두 핫함 (이번 주 매일 커밋됨).

## 1단계 — 저결합 분리 (즉시 가능, 낮은 위험)

| 신규 모듈 | 출처 | 규모 | 결합도 |
|---|---|---|---|
| `agents/briefing/prompts.py` | 프롬프트·스키마 상수/빌더 12개 | ~700줄 | ⭐ 독립 |
| `agents/briefing/data_layer.py` | DB 페칭 10 + 정규화 11 함수 | ~700줄 | ⭐⭐ |
| `agents/strategic_insight/prompts.py` | LLM 프롬프트 상수 12개 (줄 128-591) | ~450줄 | ⭐ 독립 |
| `agents/strategic_insight/fallback.py` | 폴백 15함수 (줄 8424-9050, 상호 호출 거의 없음) | ~650줄 | ⭐⭐ |
| `agents/strategic_insight/utils.py` | 텍스트/JSON/한글 유틸 19함수 | ~400줄 | ⭐ |

→ 1단계만으로 두 파일에서 **~2,900줄 감량**, 충돌 표면적 즉시 축소.

## 2단계 — 고수익·중난이도 (1단계 안정화 후)

| 신규 모듈 | 출처 | 규모 | 비고 |
|---|---|---|---|
| `agents/strategic_insight/profile_linkage.py` | 스코어링 엔진+컨텍스트 압축 (줄 3159-4345 등) | ~1,100줄 | 선형 파이프라인이라 절단 깔끔, **타 에이전트 재사용 가치** |
| `agents/briefing/basis_builder.py` | 기초→병합→LLM 정제 (줄 1219-2849) | ~900줄 | 프롬프트 분리(1단계) 후에 진행해야 추적 가능 |

## 분리 금지 영역 (강결합 — 억지로 쪼개면 악화)

- briefing의 `_front_*` 렌더링 50함수 (줄 5525-6750): 도메인 로직 섬세 결합 ⭐⭐⭐⭐⭐ — 분해 대신 향후 `briefing/render/` 패키지화만 검토
- strategic_insight의 오케스트레이션+3-tier 품질게이트+수리 루프 (줄 598-1639): 상태 공유가 본질 — 클래스에 유지

## 실행 체크리스트 (모듈 1개당 1 PR)

- [ ] 팀 채널 선언 + 해당 파일 건드는 열린 브랜치 0 확인
- [ ] mock-LLM 스냅샷 테스트 작성·통과 (선행 1회)
- [ ] 이동 커밋 → import 갱신 커밋 → 게이트 4종(ruff/format/mypy/pytest) + lint-imports
- [ ] PR 본문에 "동작 불변" 증거(스냅샷 테스트 결과) 첨부
