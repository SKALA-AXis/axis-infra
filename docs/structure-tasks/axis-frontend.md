# axis-frontend 구조 작업 목록 (의제)

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 소유: 안가은 · 최종민
> ⚠️ **이 문서는 "의제 목록"이다.** 이 레포는 두 분이 주도 중이므로 실행 여부·순서·방식은 두 분이 결정한다. 인프라 측 분석에서 나온 사실 전달 + 협의 요청이 목적.

## 전달 사항 (사실)

- `src/app/`(레거시, 90 TSX) + `src/features/`(신 구조, 27개 feature) **이중 구조**이며, 동일 이름 컴포넌트가 양쪽에 존재 (HomeDashboardView, BriefingsView, KeywordGraphView, HomeCardNewsView 등). DashboardShell은 `app/` 쪽을 import — `features/` 쪽 다수는 미사용으로 보임
- CLAUDE.md는 React Router v6 / Zustand / React Query / `src/pages` 구조를 서술하지만 **현재 코드는 셋 다 사용하지 않음** (커스텀 `useViewRouting` + 로컬 상태 + Repository 패턴)
- `src/types/api.ts` — ✅ **드리프트 해소(2026-06-14, PR #109)**: openapi 102경로 ↔ api.ts 101경로 동기화(이전 73경로). 자동생성 규칙 정상
- 테스트 0개 (`"test": "echo 'No tests yet' && exit 0"`), 인라인 `style={{}}` 11파일. (untracked 다수는 로컬 작업트리 — 레포 무관)
- 거대 컴포넌트 실측 (tracked, 2026-06-15 `git ls-files` 기준): `MixerView.tsx` 2,039 / `HomeDashboardView.tsx` 1,175 / `KeywordGraphView.tsx` 1,150 / `PeerPlusView.tsx` 947 / `BriefingsView.tsx` 938 / `AdminView.tsx` 906 / `AuthScreen.tsx` 747 (※ AxisPlanningViews 는 레포 미추적 — 실재 아님)
- Repository 패턴(HTTP+mock 듀얼) 설계는 우수, **20 Repository 채택(95%)**. 단 컴포넌트 httpClient 직접 호출 2건(KeywordGraphView·FloatingAiChat)이 패턴 우회
- **번들 최적화 여지**: `vite.config.ts` manualChunks 아직 object형(react-vendor만). vite 8(rolldown) function형 전환 **PR #115 미머지** — 머지 후 recharts/three/radix 확대 시 캐시 적중·LCP 개선 (저위험·발표 전 가능)

> **진행 현황 검증 (2026-06-15):** api.ts 드리프트 ✅해소(#109). 번들 #115 미머지 상태. README는 실측 동기화 완료(#97).

## 발표 전 요청 (동작 불변, 부담 최소)

- [x] ✅ **api.ts 재생성 — 완료 (2026-06-14, PR #109)**: openapi 102 ↔ api.ts 101 동기화(73→101). 단독 PR로 처리
- [ ] **#115 머지 → manualChunks 함수형 + recharts/three/radix 확대** (발표 전 가능, 동작 불변·번들만)
- [~] **"정본 선언"**: README 실측 동기화(#97)에서 이중구조 경고 + "신규 API는 Repository 경유" 규칙은 명시. **단 `app`/`features` 수렴 방향 자체는 여전히 팀 결정 대기**(2-F1)

## 발표 후 의제 (협의용) — 전체 미착수(팀 소유, 발표 후) → 구조 제안: [refactoring-architecture §4](refactoring-architecture.md)

> **2026-06-14 전수 분석 추가 발견** (인프라 측, 검증 완료):
> - ⚠️ **(2026-06-14 정정) "dead code" 판정은 오류였음**: `AxisPlanningViews.tsx`·`app/shell/` 5파일은 **develop 레포에 추적되지 않는 로컬 untracked 파일**(아래 47건 중 일부)이었음. `git ls-files` 로 확인 결과 `app/shell/`·`app/components/*.tsx` 직속 추적 파일 0. 라이브 셸은 `app/components/layout/DashboardShell`(tracked). 즉 **레포에서 지울 dead code 아님** — 로컬 작업트리 오염으로 인한 오판. 거대 컴포넌트(아래)는 tracked 실측치로 갱신.
> - 동일 이름 뷰 **6쌍 중복** — 렌더되는 건 전부 `app/components/pages/`, `features/` 동명본은 미사용 추정.
> - Repository 패턴: **20 Repository(95%) 채택**. 단 컴포넌트 `httpClient` 직접 호출 2건(KeywordGraphView·FloatingAiChat). hooks·utils 의 httpClient 사용은 별개 계층(정책상 회색).

- [x] ~~**2-F0. dead code 제거**~~ — **취소 (2026-06-14)**: 대상 파일들이 develop 미추적(로컬 untracked)로 판명 → 레포에 지울 것 없음. 대신 **로컬 untracked 점검**(작업자 백업/정리)이 실제 액션
- [ ] **2-F1. 이중 구조 단일화 로드맵**: app↔features 수렴 방향 1개 선언(권장: features/) 후 동명 중복 정리
- [ ] **2-F2. 거대 컴포넌트 분해**: MixerView(2,039) / HomeDashboardView(1,175) / KeywordGraphView(1,150) — container(데이터·상태) + presentational(렌더) 분리, Three.js 는 `useKeywordGraph3D` 훅으로
- [ ] **2-F3. httpClient 직접 호출 2건(KeywordGraphView·FloatingAiChat) → Repository 경유** + ESLint `no-restricted-imports` 로 직접 호출 차단
- [ ] **2-F4. 최소 테스트**: 스모크 1개라도 추가하고 `"No tests yet"` 스크립트 제거
- [ ] **2-F5. CLAUDE.md 실구조로 재작성** (구조 확정 후) — README는 #97에서 실측 동기화 완료, CLAUDE.md는 미반영
- [ ] (선택) 인라인 style 11파일 → Tailwind/CSS var 치환 — 디자인 작업과 겹치므로 두 분 일정에 맞춰
