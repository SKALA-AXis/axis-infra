# axis-backend 구조 작업 목록

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 담당 제안: 박지원
> 현 상태가 4개 레포 중 가장 견고 (레이어 위반 0건, Flyway V1~V43 연속, OpenAPI 일치 90%+). 작업량 가장 적음.

## Phase 0 — 위생 (즉시, ~6/12)

- [x] **`bin/` 추적 해제** (PR #72, 6/11) — 빌드 산출물 38개가 커밋돼 있음 (소스 영향 0):
  ```bash
  echo "bin/" >> .gitignore
  git rm -r --cached bin/
  git commit -m "chore: stop tracking build output bin/"
  ```
- [ ] 완료 기준: `git ls-files bin/` 결과 0건

## Phase 1 — 문서 동기화 (~6/20, 동작 불변)

- [ ] **CLAUDE.md 현행화**:
  - [ ] "AI 호출 실패 시 fixture fallback" 패턴 명문화 (DashboardController 등에서 실사용 중인 핵심 패턴인데 미기재)
  - [ ] 컨트롤러 목록 갱신 (현 25개 — Dashboard/KeywordGraph/RawArticle/AssistantConversation 등 누락분)
  - [ ] dev/internal 전용 경로(`/api/dev/agents/**`, cron-generate 등)가 OpenAPI 비대상임을 명시
- [ ] **schema.sql ↔ Flyway 관계 문서화** (infra `docs/DB_METADATA.md`와 합의): "V40까지 스냅샷 = schema.sql, V41+ 진실은 Flyway, 마일스톤마다 재덤프" — infra 측과 공동 작업

## Phase 2 — 리팩토링 (발표 후 6/24~, 우선순위순)

- [ ] **2-B1. `PeerOverviewTableService` 분해** (2,223줄 — 조회+변환+캐싱+계산 혼재)
  - [ ] 선행: 현 응답 고정하는 통합 테스트 1개
  - [ ] 3분할: `PeerOverviewTableQuery`(JDBC) / `PeerOverviewTableFormatter` / `PeerOverviewTableCache`
- [x] ~~2-B2. ApiContractFixtureService 도메인 분리~~ — **자연 해소(6/11)**: 팀이 fixture 체계 자체를 제거 (CLAUDE.md 정책도 '임시 데이터 반환 금지'로 개정됨)
  - [ ] 도메인별 Fixture 클래스(AuthFixture, CardFixture, DashboardFixture…) 또는 `contract-fixtures.json` 로더 일반화
  - [ ] 컨트롤러 의존을 도메인별로 좁힘 — 한 PR에 도메인 1~2개씩
- [ ] **2-B3. 하드코딩 제거**
  - [ ] peer 5사 목록 → `peer_companies` 테이블 로드 (테이블 기존재, Flyway 불필요)
  - [ ] RequestMetadata IP 대역, fixture 기본 기간값("2026Q2") → 설정 외부화
- [ ] **2-B4. 거대 서비스 단위 테스트** — CardNewsService(539줄), GlobalSearchService(676줄대) 우선

## 참고 실측치

| 항목 | 값 |
|---|---|
| PeerOverviewTableService | 2,223줄 |
| ApiContractFixtureService | 778줄 / 사용처 97 (실측) |
| 테스트 | 10개 (스모크·통합 위주, 단위 4개) |
| Flyway | V1~V43 + V32_5, 총 44개·중복 없음, validate-on-migrate 정상 |
