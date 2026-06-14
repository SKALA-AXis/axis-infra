# axis-frontend 구조 작업 목록 (의제)

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 소유: 안가은 · 최종민
> ⚠️ **이 문서는 "의제 목록"이다.** 이 레포는 두 분이 주도 중이므로 실행 여부·순서·방식은 두 분이 결정한다. 인프라 측 분석에서 나온 사실 전달 + 협의 요청이 목적.

## 전달 사항 (사실)

- `src/app/`(레거시, 90 TSX) + `src/features/`(신 구조, 27개 feature) **이중 구조**이며, 동일 이름 컴포넌트가 양쪽에 존재 (HomeDashboardView, BriefingsView, KeywordGraphView, HomeCardNewsView 등). DashboardShell은 `app/` 쪽을 import — `features/` 쪽 다수는 미사용으로 보임
- CLAUDE.md는 React Router v6 / Zustand / React Query / `src/pages` 구조를 서술하지만 **현재 코드는 셋 다 사용하지 않음** (커스텀 `useViewRouting` + 로컬 상태 + Repository 패턴)
- `src/types/api.ts` 마지막 재생성 5/18, infra `openapi.yaml`은 6/9 갱신 — **재생성 필요 확정**: 6/9 커밋(#51)이 `GET /api/global/trends` 계약을 추가했고 api.ts에 미반영
- 테스트 0개 (`"test": "echo 'No tests yet' && exit 0"`), 인라인 `style={{}}` 85건, untracked 47건
- 거대 컴포넌트 실측: `AxisPlanningViews.tsx` 2,980줄, `MixerView.tsx` 1,218줄, `KeywordGraphView.tsx` 1,143줄, `HomeDashboardView.tsx` 1,074줄
- Repository 패턴(HTTP+mock 듀얼) 설계는 우수. 단 KeywordGraphView 등에서 httpClient 직접 호출 2건이 패턴 우회

> **진행 현황 검증 (2026-06-14):** ⚠️ **api.ts 드리프트 재발생** — develop openapi 101경로 vs api.ts 73경로. 브리핑 계약(infra #76, +28경로)은 머지됐으나 FE api.ts 재생성이 develop에 반영 안 됨(6/12 재생성 커밋이 #105 머지에 유실). **재생성 시급.** README는 실측 동기화 완료(#97).

## 발표 전 요청 (동작 불변, 부담 최소)

- [ ] ⚠️ **api.ts 재생성 — 미완·시급 (2026-06-14)**: develop openapi=101 / api.ts=73 으로 **28경로 어긋남**(admin/notifications/dashboard/briefing 등). `npx openapi-typescript ../axis-infra/api/openapi.yaml -o src/types/api.ts` 후 커밋 필요. (6/12 재생성분이 briefing 브랜치 머지 과정에서 유실됨)
- [ ] **untracked 47건 점검**: 작업 중인 것은 WIP 브랜치로 백업 커밋 (로컬 유실 방지)
- [~] **"정본 선언"**: README 실측 동기화(#97)에서 이중구조 경고 + "신규 API는 Repository 경유" 규칙은 명시. **단 `app`/`features` 수렴 방향 자체는 여전히 팀 결정 대기**(2-F1)

## 발표 후 의제 (협의용) — 전체 미착수(팀 소유, 발표 후) → 구조 제안: [refactoring-architecture §4](refactoring-architecture.md)

> **2026-06-14 전수 분석 추가 발견** (인프라 측, 검증 완료):
> - **검증된 dead code**: `app/components/AxisPlanningViews.tsx` **2,980줄 — import 0건**(실측), `app/shell/` 5파일(DashboardShell·Sidebar·TopNav·Footer·InAppGuideOverlay — FloatingAiChat만 features/peers/MonitoringView가 사용). 라이브 셸은 `app/components/layout/DashboardShell`.
> - 동일 이름 뷰 **6쌍 중복** — 렌더되는 건 전부 `app/components/pages/`, `features/` 동명본은 미사용 추정.
> - Repository 패턴: 10 feature 우수 채택. 단 keyword-graph `httpClient` 직접 호출 2건(KeywordGraphView.tsx:233,716), home·admin·keyword-graph feature 구조 미완.

- [ ] **2-F0. dead code 제거 (P0, 빠른 승리)**: AxisPlanningViews.tsx(2,980, import 0) + app/shell 5파일 — **삭제 전 import 재확인** 후 제거 (~6,000줄)
- [ ] **2-F1. 이중 구조 단일화 로드맵**: app↔features 수렴 방향 1개 선언(권장: features/) 후 중복 6쌍 정리
- [ ] **2-F2. 거대 컴포넌트 분해**: AxisPlanningViews(2,980·dead라면 삭제로 갈음) / MixerView(1,993) / HomeDashboardView(1,103) — container(데이터·상태) + presentational(렌더) 분리
- [ ] **2-F3. keyword-graph Repository 신설 → httpClient 직접 호출 2건 제거** + ESLint `no-restricted-imports` 로 직접 호출 차단
- [ ] **2-F4. 최소 테스트**: 스모크 1개라도 추가하고 `"No tests yet"` 스크립트 제거
- [ ] **2-F5. CLAUDE.md 실구조로 재작성** (구조 확정 후) — README는 #97에서 실측 동기화 완료, CLAUDE.md는 미반영
- [ ] (선택) 인라인 style ~120건 → Tailwind/CSS var 치환 — 디자인 작업과 겹치므로 두 분 일정에 맞춰
