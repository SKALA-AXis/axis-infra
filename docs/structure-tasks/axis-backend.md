# axis-backend 구조 작업 목록

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 담당 제안: 박지원
> 현 상태가 4개 레포 중 가장 견고 (레이어 위반 0건, Flyway V1~V43 연속, OpenAPI 일치 90%+). 작업량 가장 적음.

> **진행 현황 검증 (2026-06-14):** Phase 0·1 완료. Phase 2는 의도대로 발표 후 격리(미착수). 계획 외 추가 완료: V44/V45 마이그레이션 + 운영 DB migrate 가드(PR #79, 유령 V44 사고 후속). 2-B2는 fixture 체계 제거로 무효화 확정.

## Phase 0 — 위생 (즉시, ~6/12)

- [x] **`bin/` 추적 해제** (PR #72, 6/11) — 빌드 산출물 38개 추적 해제 (소스 영향 0)
- [x] 완료 기준: `git ls-files bin/` 결과 **0건 확인 (2026-06-14)**

## Phase 1 — 문서 동기화 (~6/20, 동작 불변)

- [x] **CLAUDE.md 현행화 — 완료 (PR #72/#81, 6/11~12)**:
  - [x] "AI 호출 실패 시 fallback" 패턴 명문화 (Dashboard stock live/fallback, Mixer 비동기 fallback — CLAUDE.md 구현기준 8조)
  - [x] 컨트롤러 목록 25개 갱신 (Dashboard/KeywordGraph/RawArticle/Assistant 포함)
  - [x] dev/internal 전용 경로(AgentDiagnostics·FrontendCompatibility·cron-generate)가 OpenAPI 비대상임 명시
- [x] **schema.sql ↔ Flyway 관계 문서화 — 완료**: infra `docs/DB_METADATA.md`(V40 스냅샷 / V41+ Flyway 진실, V45 현행) + backend CLAUDE.md 마이그레이션 안전 규칙 5조 + CONVENTION §15 (PR #79/#81)

## 계획 외 추가 완료 (2026-06-12, V44 유령 마이그레이션 사고 후속)

- [x] **V44/V45 마이그레이션 정식 수록 + 운영 DB migrate 가드** (PR #79): `beforeMigrate__prod_guard.sql` — `axis.environment='prod'` 마커 DB에 배포 경로 밖 migrate 차단. V45 append-only 스냅샷 멱등 수록. 운영 DB 라이브 적용·가드 작동 검증 완료

## Phase 2 — 리팩토링 (발표 후 6/24~, 우선순위순) — 전체 미착수(의도대로 격리) → 계층 설계: [refactoring-architecture §3](refactoring-architecture.md)

> **타깃 계층**: controller(HTTP 경계) → service(오케스트레이션) → query(JDBC)/formatter(변환, 신설)/repository(JPA) → domain. service 안의 SQL·변환 직접 보유를 query/·formatter/ 로 이관. 계층은 ArchUnit 테스트로 CI 강제.

- [ ] **2-B0a. `@Transactional(readOnly=true)` 명시 (발표 전 가능한 저위험·고가치)** — JdbcTemplate 주입 13서비스 중 **12개가 트랜잭션 경계 무**(AgentDiagnostics·ArticleImage·AssistantConversation·BriefingReport·DashboardKeywordTrendChart·DashboardStockChart·GlobalTrends·KeywordGraph·MixerResult·PeerOverviewTable·RawArticleQuery·TodayInsightReport). 다중 쿼리 읽기 일관성·커넥션 최적화. 어노테이션만 = 동작 영향 최소. ⚠️ 로컬 JDK 17 부재 → CI 검증 의존
- [ ] **2-B1. `PeerOverviewTableService` 분해** (2026-06-15 재실측 **2,663줄** — JDBC ~850 + DTO변환 ~800 + 캐싱 ~200 + 계산 ~600 혼재)
  - [ ] 선행: 현 응답 고정하는 통합 테스트 1개
  - [ ] 3계층 분할: `query/PeerOverviewQuery`(JDBC ~600) / `formatter/PeerOverviewFormatter`(변환 ~700) / `PeerOverviewTableService`(오케스트레이션·캐싱 ~400)
- [ ] **2-B0. `PeerCompanyProvider` 신설** (빠른 승리, 2~3일) — peer 5사 하드코딩 **8파일**(컨트롤러 3: AgentDiagnostics·FrontendCompatibility·IssueCard + 서비스 5: Briefing·DashboardStockChart·KeywordGraph·PeerOverviewTable·UserNotification) → `peer_companies` 테이블 로드 1곳. 다른 거대 분해의 선행 정리
- [ ] **2-B5. `formatter/` 패키지 신설** — CardNews(변환 680줄)·KeywordGraph·PeerOverview 등에 분산된 DTO↔Entity 변환 중앙화, 단위 테스트
- [ ] **2-B6. `query/` 패키지로 service 내 SQL 이관** — DashboardKeywordTrendChartService(924)·KeywordGraphService(793)·GlobalSearchService(601)의 직접 SQL → query/ (service SQL ~1,800줄 → ~200줄)
- [ ] **2-B9. 캐싱 `@Cacheable` 통일** — volatile/AtomicReference/ConcurrentMap 혼재 → Spring Cache 추상화로 TTL 중앙 관리
- [ ] **2-B7. AI fallback 공통화** — 컨트롤러 4곳(Dashboard·Assistant·Mixer + GlobalSearchService) try-catch 중복 → AOP/공통 래퍼
- [ ] **2-B8. ArchUnit 계층 테스트 CI 추가** — controller→service→query/repository 단방향 강제
- [x] ~~2-B2. ApiContractFixtureService 도메인 분리~~ — **자연 해소 확정(2026-06-14)**: `ApiContractFixtureService.java` 부재 = fixture 체계 제거 완료. 하위 항목(도메인별 Fixture 클래스 등) 전부 무효
- [ ] **2-B3. 하드코딩 제거** — 부분
  - [ ] peer 5사 목록: 코드 상수 + 테이블 JOIN **혼합 상태** — 상수 제거 미완
  - [x] RequestMetadata IP 대역: 동적 파싱(CF/Vercel/AppEngine 헤더)으로 외부화됨
- [ ] **2-B4. 거대 서비스 단위 테스트** — CardNewsService·GlobalSearchService 단위 테스트 **미존재(2026-06-15)**. 현 테스트 14파일

## 참고 실측치 (2026-06-15, git-tracked)

| 항목 | 값 |
|---|---|
| PeerOverviewTableService | 2,663줄 |
| DashboardKeywordTrendChartService | 924줄 |
| CardNewsService / KeywordGraphService / GlobalSearchService | 838 / 793 / 601줄 |
| 거대 서비스(>500줄) | 8개 (위 + BriefingReport 553·AuthService 536·AssistantConversation 517) |
| JdbcTemplate 주입 / 그중 @Transactional 무 | 13 / **12** |
| peer 하드코딩 파일 | 8 |
| 테스트 | 14개 |
| Flyway | V1~V45 (+V32_5), validate-on-migrate 정상, prod-guard 작동 |
