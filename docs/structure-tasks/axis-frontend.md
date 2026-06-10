# axis-frontend 구조 작업 목록 (의제)

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 소유: 안가은 · 최종민
> ⚠️ **이 문서는 "의제 목록"이다.** 이 레포는 두 분이 주도 중이므로 실행 여부·순서·방식은 두 분이 결정한다. 인프라 측 분석에서 나온 사실 전달 + 협의 요청이 목적.

## 전달 사항 (사실)

- `src/app/`(레거시, 90 TSX) + `src/features/`(신 구조, 27개 feature) **이중 구조**이며, 동일 이름 컴포넌트가 양쪽에 존재 (HomeDashboardView, BriefingsView, KeywordGraphView, HomeCardNewsView 등). DashboardShell은 `app/` 쪽을 import — `features/` 쪽 다수는 미사용으로 보임
- CLAUDE.md는 React Router v6 / Zustand / React Query / `src/pages` 구조를 서술하지만 **현재 코드는 셋 다 사용하지 않음** (커스텀 `useViewRouting` + 로컬 상태 + Repository 패턴)
- `src/types/api.ts` 마지막 재생성 5/18, infra `openapi.yaml`은 6/9 갱신 → **재생성 필요 가능성**
- 테스트 0개 (`"test": "echo 'No tests yet' && exit 0"`), 인라인 `style={{}}` 85건, untracked 47건
- 거대 컴포넌트 실측: `AxisPlanningViews.tsx` 2,980줄, `MixerView.tsx` 1,218줄, `KeywordGraphView.tsx` 1,143줄, `HomeDashboardView.tsx` 1,074줄
- Repository 패턴(HTTP+mock 듀얼) 설계는 우수. 단 KeywordGraphView 등에서 httpClient 직접 호출 2건이 패턴 우회

## 발표 전 요청 (동작 불변, 부담 최소)

- [ ] **api.ts 재생성 1회**: `npx openapi-typescript ../axis-infra/api/openapi.yaml -o src/types/api.ts` — diff 없으면 그대로 종료
- [ ] **untracked 47건 점검**: 작업 중인 것은 WIP 브랜치로 백업 커밋 (로컬 유실 방지)
- [ ] **"정본 선언" 1줄**: `app/`과 `features/` 중 어느 쪽으로 수렴할지 README 또는 CLAUDE.md에 한 줄이라도 — 신규 코드가 어디로 가야 하는지만 정해지면 충돌 대부분 예방됨

## 발표 후 의제 (협의용)

- [ ] **2-F1. 이중 구조 단일화 로드맵**: 미사용 `features/` 중복 컴포넌트 삭제 or `app/` 뷰의 `features/` 이행 — 둘 중 하나로
- [ ] **2-F2. `AxisPlanningViews.tsx`(2,980줄) 분해**
- [ ] **2-F3. httpClient 직접 호출 2건 → Repository 일원화**
- [ ] **2-F4. 최소 테스트**: 스모크 1개라도 추가하고 `"No tests yet"` 스크립트 제거
- [ ] **2-F5. CLAUDE.md 실구조로 재작성** (구조 확정 후)
- [ ] (선택) 인라인 style 85건 → Tailwind 치환 — 디자인 작업과 겹치므로 두 분 일정에 맞춰
