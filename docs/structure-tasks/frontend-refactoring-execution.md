# axis-frontend 리팩토링 실행 계획서 (현업 수준 구조화)

> 작성 2026-06-17 · 소유: 안가은·최종민 (인프라/AX 측 협업)
> **참고(상위)**: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · [axis-frontend.md(의제)](axis-frontend.md) · [refactoring-architecture.md §4(설계)](refactoring-architecture.md)
> **목적**: 기능 단위 구조화·재사용 추출·거대 컴포넌트 분해를 **단계별로, 세션이 바뀌어도 맥락이 끊기지 않게** 실행한다. 위 3문서는 "무엇을/왜"의 분석·설계, 이 문서는 "어떻게/순서/인계"의 **실행본**이다.

---

## 0. 진행 현황 (Progress Ledger — ⚠️ 매 PR 후 갱신 · 세션 시작 시 여기부터 읽기)

> 이 표가 **맥락 유지의 핵심**이다. 작업 한 단위 끝낼 때마다 메트릭·상태·"다음 작업"을 갱신한다.

**단계 상태**

| 단계 | 내용 | 상태 | PR |
|---|---|---|---|
| P0 안전망·강제 | characterization 스모크 + ESLint httpClient 차단 + 크기 메트릭 | ⬜ 미착수 | — |
| P1 빠른 승리·재사용 1차 | httpClient 우회 1건 Repository화 · 재사용 추출(차트/라벨/날짜) | ⬜ 미착수 | — |
| P2 이중구조 단일화 | features/ 수렴 선언 + 동명 중복 정리 | ⬜ 미착수 | — |
| P3 거대 컴포넌트 분해 | 컴포넌트별 container/presentational (1 PR=1 컴포넌트) | ⬜ 미착수 | — |
| P4 테스트·계약 강제 | 추출 단위 단위테스트 + CI 게이트 | ⬜ 미착수 | — |

**메트릭 (실측 — 날짜별 기록)**

| 메트릭 | 2026-06-17(기준) | 목표 |
|---|---|---|
| 컴포넌트 >600줄 | 10 | 0 |
| 컴포넌트 >1,000줄 | 4 (Mixer·Home·Settings·KeywordGraph) | 0 |
| Repository httpClient 직접 우회 | 1 (KeywordGraphView) | 0 |
| 테스트 파일 | 0 | 스모크+핵심 단위 |
| ESLint/vitest 설치·게이트 | ❌ 둘 다 **미설치**(orphan .eslintrc) | ✅ 설치 + `lint`/`test` 연결 |
| app↔features 동명 중복 | 다수(이중구조) | 0 (features/ 단일) |
| manualChunks 함수형(#115) | ✅ 완료 | — |

**🔖 마지막 작업**: (없음 — 계획 수립) · **▶ 다음 작업**: P0-1 characterization 스모크 골격 · **열린 PR**: —

---

## 1. 현재 진단 (2026-06-17 git-tracked 실측)

- **이중 구조**: `src/app/components/pages/`(14 tsx, 실사용 — DashboardShell이 분기) ↔ `src/features/`(18 디렉토리). 동명 뷰 중복, 렌더되는 건 `app/` 쪽. *(06-15 시점 features 25 → 18 로 일부 수렴됨.)*
- **거대 컴포넌트** (줄수, 책임 혼재 = fetch+상태+비즈로직+렌더):
  | 파일 | 줄 | | 파일 | 줄 |
  |---|---|---|---|---|
  | `mixer/MixerView.tsx` | 2,042 | | `peer-plus/PeerPlusView.tsx` | 947 |
  | `home/dashboard/HomeDashboardView.tsx` | 1,224 | | `briefings/BriefingsView.tsx` | 938 |
  | `settings/SettingsView.tsx` | 1,166 | | `admin/AdminView.tsx` | 906 |
  | `keyword-graph/KeywordGraphView.tsx` | 1,150 | | `auth/AuthScreen.tsx` | 761 |
  > `ui/sidebar.tsx`(726)·shadcn 래퍼류는 **vendored** — 분해 대상 아님(원본 유지).
- **Repository 패턴 정착(95%)**, 단 컴포넌트 `httpClient` 직접 호출 **1건**(`KeywordGraphView`). *(FloatingAiChat 우회는 해소됨.)*
- **테스트 0** (`"test": "echo 'No tests yet'"`) — **vitest 미설치**. `lint` 스크립트 = `tsc --noEmit`만(=type-check 와 동일). ⚠️ **ESLint 미설치**: `.eslintrc.cjs` 는 있으나 참조 패키지(`eslint`·`@typescript-eslint/parser`·`eslint-plugin-react-refresh`)가 devDeps 에 **전무 → orphan config, 실행 불가**. 인라인 `style={{}}` 다수.
- 양호: TS strict · `any` 0 · `src/types/api.ts` 자동생성 규칙 준수(#109 드리프트 해소) · `manualChunks` 함수형(#115 머지).

---

## 2. 타깃 구조 & 원칙

**타깃 구조** (refactoring-architecture §4.2):
```
features/<도메인>/
  api/        ← Repository (HTTP + mock Hybrid). 컴포넌트는 여기로만 호출
  hooks/      ← 데이터·상태 (container 가 사용)
  model/      ← 타입·도메인 모델 (api.ts 자동생성 타입 매핑)
  mappers/    ← 응답 → 모델 변환
  components/ ← container(데이터·상태 주입) + presentational(순수 렌더) + sub-components
```
- **화면 = container + presentational 분리**: 거대 뷰는 `useXxx` 훅(데이터/상태) + `XxxView`(조립) + `Xxx{Section}` presentational 로 쪼갠다.
- **API 100% Repository**: 컴포넌트의 `httpClient` 직접 호출 금지 — ESLint `no-restricted-imports` 로 강제.
- **app/ ↔ features/ 수렴 1개 방향**(권장: `features/`) 선언 후 일괄 이행.

**원칙** (refactoring-architecture §1·§6, 절대 준수):
1. **동작 불변** — 모든 PR 은 런타임 동작을 바꾸지 않는다(순수 구조 변경). 증빙(characterization 결과/스크린샷) 첨부.
2. **안전망 먼저** — 테스트 0 상태에서 분해는 위험. **P0 에서 characterization 스모크 + ESLint 강제부터** 깐다.
3. **만들고 → 1곳 적용 → 검증 → 점진 이행** — 새 추상화(훅·shared util)는 만들어 **한 곳에 먼저 적용·검증**하고 나머지는 점진. **한 PR 에 전 사이트 일괄 변경 금지.**
4. **커밋 분리** — "파일 이동(rename)" 커밋과 "내용 수정" 커밋을 분리(diff 리뷰 가능하게).
5. **1 PR = 1 단위** — 컴포넌트 1개 분해 = PR 1개. 작게.
6. **레포 규칙 준수** — service repo 라 **브랜치+PR 필수**, push 전 게이트(type-check·lint·build, `vite build`는 로컬 esbuild minify 행 회피 위해 `--minify false`로 검증·CI가 풀빌드), `git add` 명시 파일만(untracked WIP 휩쓸림 방지), 격리 워크트리 권장.

---

## 3. 단계 (각 단계 = 진입/종료 조건 명시)

### Phase 0 — 안전망·강제 (선결, 동작 불변) 🪤
> 분해의 그물. 이게 없으면 거대 컴포넌트 분해가 회귀를 부른다.
- **P0-1 vitest 설치 + characterization 스모크**: `vitest`+`@testing-library/react`+`jsdom` 설치(현재 미설치), `"test"` 더미 제거. 핵심 뷰(Home·Mixer·KeywordGraph) 렌더 스모크 + 주요 Repository 매퍼 단위 테스트.
- **P0-2 ESLint 설치 + 게이트 연결**: `eslint`·`@typescript-eslint/*`·플러그인 설치(현재 **미설치** — orphan `.eslintrc.cjs` 정비), `lint` 스크립트를 `eslint + tsc` 로, `no-restricted-imports`로 컴포넌트의 `httpClient`/`features↔app` 역참조 차단(현재 우회 1건은 allowlist 후 P1 에서 해소).
- **P0-3 크기 메트릭 스크립트**: 컴포넌트 줄수 리포트(>600 경고) — CI 비차단 리포트로 시작.
- **종료 조건**: `npm run test` 실통과(더미 아님) · ESLint 가 `lint` 에 포함 · §0 메트릭 갱신.

### Phase 1 — 빠른 승리 + 재사용 추출 1차 (leaf·저위험)
- **P1-1** `KeywordGraphView` 의 `httpClient` 직접 호출 → `keywordGraphRepository` 경유 (우회 1→0). ESLint allowlist 제거.
- **P1-2 재사용 추출(이득 큰 것 1~2개, "만들고→1곳 적용")**: §5 카탈로그 상위(차트 설정 wrapper, AI 생성 콘텐츠 라벨, 날짜 포맷 util). **각 추출은 1곳에 적용·검증까지만**, 나머지 사이트는 후속.
- **P1-3** 인라인 `style={{}}` → Tailwind/CSS var (디자인 작업과 겹치면 일정 조율).
- **종료 조건**: Repository 우회 0 · 추출 util 1개 이상 1곳 적용·테스트 · §0 갱신.

### Phase 2 — 이중구조 단일화
- **P2-1 수렴 방향 선언**: `app/` ↔ `features/` 중 **features/ 단일화** 결정 문서화(팀 합의). DashboardShell 이 features/ 를 바라보게 할지, 점진 이행 경로 명시.
- **P2-2 동명 중복 정리**: 미사용 `features/` 동명본 식별(import 그래프) → 삭제 또는 실사용본으로 통합. **이동 커밋/수정 커밋 분리.**
- **종료 조건**: 동명 중복 0 · 죽은 동명본 제거 · 빌드/타입 green · §0 갱신.

### Phase 3 — 거대 컴포넌트 분해 (컴포넌트별 1 PR, §4 맵)
> 순서: **작고 독립적인 것부터**(AuthScreen·Admin) → 큰 것(Mixer·Home). 각 PR 동작 불변 증빙 필수.
- 컴포넌트별로 §4 분해 맵 따라 container/hooks/presentational 분리. Three.js 는 `useKeywordGraph3D` 훅으로.
- **종료 조건**: 대상 컴포넌트 ≤600줄 · 동작 불변 증빙 · §0 메트릭(>1000, >600) 감소 기록.

### Phase 4 — 테스트·계약 강제
- **P4-1** 추출된 훅/매퍼/presentational 단위 테스트 확대.
- **P4-2 CI 계약 게이트**: ESLint 계층 규칙 CI 차단화 + 컴포넌트 크기 게이트(≥600 신규 차단).
- **종료 조건**: 핵심 단위 커버리지 확보 · CI 가 계층/크기 위반 차단 · §0 최종 갱신.

---

## 4. 거대 컴포넌트 분해 맵 (컴포넌트별 — Phase 3)

> 패턴 공통: `useXxx`(fetch·상태·SSE) ⟶ `XxxView`(조립=container) ⟶ `Xxx{Section}`(순수 렌더) + 서브컴포넌트. 비즈로직은 `model/`·`utils` 로.

| 컴포넌트(줄) | 분해 타깃 |
|---|---|
| **MixerView 2,042** | `useMixer`(input/ratios/SSE 스트림 상태) + `MixerView`(container) + `MixerInputsPanel`·`MixerRadar`·`MixerConnections`·`MixerResult` presentational + `mixer/model` 계산 분리 |
| **HomeDashboardView 1,224** | `useHomeDashboard` + **today-insight 3상태 렌더 분리**: `TodayInsightHeader`·`TodayInsightSignals`·`TodayInsightStrip`·`TodayInsightQuiet`(3상태 로직은 PR #132 머지 후 기준) + `HomeCardNewsRail` + `HomeGlobalTrends`(embed) |
| **KeywordGraphView 1,150** | `useKeywordGraph`(데이터) + **`useKeywordGraph3D`(Three.js 캡슐화)** + `KeywordGraphCanvas`(렌더) + `KeywordGraphControls` |
| **SettingsView 1,166** | 섹션별 분리: `Settings{Profile,Notifications,Keywords,Account}` + `useSettings` (섹션별 폼 상태) |
| **PeerPlusView 947 / BriefingsView 938 / AdminView 906 / AuthScreen 761** | 동일 패턴(container+섹션 presentational). 작은 것(Auth·Admin)부터 착수해 패턴 검증 |

---

## 5. 재사용 추출 카탈로그 (이득 큰 순 — "만들고→1곳→점진")

1. **차트 설정 wrapper** — recharts/three 반복 설정을 `shared/charts/` 래퍼로(테마·축·툴팁 공통).
2. **AI 생성 콘텐츠 라벨** — `✨ AI 초안` / `⚠️ 근거 불충분(confidence<0.6)`을 공용 `shared/ui/AiContentBadge` 로 **표준화**. ⚠️ CLAUDE.md 의무지만 **현재 표준 라벨 미구현**(코드에 "AI 초안" 배지 없음, confidence 표시 ad-hoc) — 재사용 + **컴플라이언스 갭** 동시 해소.
3. **날짜/시각 포맷 util** — `toDateInputValue`·상대시각·KST 표기 분산 → `shared/lib/date` 통합.
4. **테이블/리스트 패턴** — peer/admin/briefings 의 반복 테이블 헤더·정렬·페이지네이션 → 공용 `DataTable`.
5. **Repository Hybrid 베이스** — HTTP+mock 듀얼 보일러플레이트를 `createHybridRepository` 팩토리로(20 Repository 중복 축소).
6. **Executive 디자인 토큰** — 인라인 style 11파일의 색/간격을 `executive/` 토큰·클래스로.

> 각 항목: 추출 → **가장 반복 많은 1곳 적용·테스트** → 나머지 점진. 한 번에 전 사이트 금지(원칙 §3-3).

---

## 6. 품질 게이트 (PR 머지 기준 — refactoring-architecture §5)

- 컴포넌트 **≤600줄 지향** · `httpClient` 직접 호출 **0**(ESLint) · `type-check` green · `vite build` green
- **동작 불변 증빙** 첨부(characterization 결과/before-after 스크린샷)
- **커밋 분리**(이동 vs 수정) · **1 PR = 1 단위**
- (P4 이후) ESLint 계층 규칙·컴포넌트 크기 CI 차단

---

## 7. 실행 순서 & 세션 인계 규칙

- **순서**: P0(안전망) → P1(빠른승리·재사용) → P2(단일화) → P3(분해: 작은 컴포넌트→큰 컴포넌트) → P4(테스트·강제). P1 일부는 P0 와 병행 가능, 분해(P3)는 **반드시 P0 안전망 이후**.
- **세션 인계(맥락 유지 핵심)**: 매 PR 종료 시 **§0 Progress Ledger 를 갱신**한다 — 단계 상태·메트릭(날짜 행 추가)·"마지막/다음 작업"·열린 PR. 새 세션/작업자는 **§0 부터 읽고** 다음 작업을 집어 든다.
- **소유**: 안가은·최종민 주도. 인프라/AX 측은 분석·게이트·리뷰 지원. 수렴 방향(P2-1)은 **팀 합의 선행**.
