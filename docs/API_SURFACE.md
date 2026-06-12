# API Surface — Frontend ↔ Backend ↔ axis-ai 매핑

> **버전**: v2 (2026-06-11)
> **목적**: 각 frontend view 가 호출하는 BE endpoint, BE 가 다시 호출해야 할 axis-ai endpoint, 담당 agent 의 일관 매핑. 디자인 디렉토리 의 agent 들이 *어디서 어떻게 노출되는지* 명시.
> **상태 기준**: 코드 기준 운영 가능 범위와 stub/degraded 범위를 분리한다. 화면 이름만으로 완료 상태를 판단하지 않는다.

## 1. 현재 통합 상태 요약

| 영역 | BE 컨트롤러 | axis-ai 위임 | 상태 |
|---|---|---|---|
| Pipeline trigger | `PipelineController.trigger` | ✅ `POST /pipeline/run` | 실 동작 |
| Daily briefing email | `BriefingService.generateAndSend` | ✅ `POST /pipeline/delivery` | 실 동작 (W6 SES 검증 완료) |
| Card list / today / detail | `CardController` | BE-only DB read model | ✅ 실 DB 조회 |
| Search | `SearchController` | BE-only `GlobalSearchService`; axis-ai `POST /search`도 RAG 검색 가능 | ✅ BE 검색 실동작 / ✅ AI 내부 검색 실동작 |
| Generative search | public BE endpoint 없음 | ✅ `POST /gen-search` | 🟡 RAG + LLM optional, LLM 실패 시 deterministic fallback + `sc_passed=false` |
| Chat (assistant) | `AssistantController` | ✅ `POST /chat`, `POST /chat/pdf` | ✅ 위임. axis-ai 장애 시 `result_kind=assistant_unavailable` degraded payload |
| Today Insight | `DashboardController` | ✅ `POST /today-insight/generate` | ✅ 위임. fallback result는 guard에서 실패로 취급 |
| Insight | `InsightController` | ✅ `POST /insight/generate` | ✅ 위임 |
| Mixer | `MixerController` | ✅ `POST /mixer/analyze`, `POST /mixer/analyze/stream` | ✅ 분석 위임. share는 payload-only |
| Briefing (user-triggered) | `BriefingController` | ✅ `POST /briefing/generate` | ✅ 생성 위임. share store는 미구현 |
| Global Trends | `GlobalTrendsController` | ✅ `POST /global/trends/run` | ✅ 위임 |
| Monitoring strategy | `MonitoringController.getPeerStrategy` | ✅ `POST /peer/compare` | ✅ 위임 |
| Card verify-link | `CardController.verifyCardLinks` | ✅ `POST /link/verify` | ✅ 위임 |
| Weak signal | BE public trigger 없음 | `POST /weak-signal/run` | 🔴 미구현. axis-ai는 501 `WEAK_SIGNAL_NOT_IMPLEMENTED` 반환 |
| Dashboard summary | `DashboardController.getDashboardSummary` | 없음 | 🟡 부분 구현. stock chart 중심 + `dataStatus.result_kind=partial_dashboard_summary` |
| Keyword graph | `KeywordGraphController` | BE-only read model | 🟡 저장 데이터 기반 |
| Alert / Bookmark / Auth / Settings / Admin | 각 controller | 대부분 axis-ai 불필요 | 🟡 영역별 DB 구현/스텁 혼재 |

**결론**: 현재 운영 가능 경로는 ingestion/delivery/card/search/chat/insight/mixer/briefing/global/link/peer 일부까지 넓어졌다. 다만 weak signal, share token 발급, dashboard summary 전체 위젯, 일부 admin/alert 영역은 아직 prototype 또는 stub/degraded 상태이므로 발표·인수인계 시 별도 구분해야 한다.

## 2. Frontend View → BE → axis-ai → Agent 매핑표

> 표 기호: ✅ 실 동작 / 🟡 부분 구현·degraded·저장 결과 의존 / 🔴 미구현·stub / ⬜ AI 불필요 (BE-only)

### 2.1 Home / Today

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/` (TodayView 카드 carousel) | `GET /api/cards/today` | 없음 | BE `card_news` read model | ✅ 실 DB 조회 |
| `/` (TodayView 요약 배지) | `GET /api/dashboard/summary` | 없음 | BE read model | 🟡 partial — stock chart 중심, `dataStatus` 포함 |
| `/` (recent_cards 영역) | `GET /api/monitoring/overview` | `GET /metrics/monitoring-overview` (신규) | DerivedMetricsAgent (mode=monitoring_overview) | 🔴 |

### 2.2 Monitoring (peer 모니터링)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/monitoring` (peer 리스트) | `GET /api/monitoring` | (BE-only — peers 테이블 SELECT) | — | ⬜ |
| `/monitoring/{peerId}` (상세) | `GET /api/monitoring/{peerId}` | `GET /monitoring/{peer}/profile` (신규) | PeerComparisonAgent | 🔴 |
| `/monitoring/{peerId}` (전략 패널) | `GET /api/monitoring/{peerId}/strategy` | `GET /monitoring/{peer}/strategy` (신규) | PeerComparisonAgent | 🔴 |
| `/monitoring/{peerId}` (카드 타임라인) | `GET /api/monitoring/{peerId}/cards` | (BE-only — card_news SELECT WHERE company=...) | — | ⬜ |
| `/monitoring/{peerId}` (재무 차트) | `GET /api/monitoring/{peerId}/financials` | (BE-only — `peer_companies.financial_history` SELECT) | — | ⬜ |
| `/monitoring/comparison` (멀티 peer 비교) | `GET /api/monitoring/comparison` | (BE-only — 집계 쿼리) | — | ⬜ |
| `/monitoring/cards/search` | `GET /api/monitoring/cards/search` | (BE-only — card_news facet 쿼리) | — | ⬜ |
| `/monitoring` (overview header) | `GET /api/monitoring/overview` | `GET /metrics/monitoring-overview` (신규) | DerivedMetricsAgent | 🔴 |

### 2.3 Search

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/search` 결과 list | `POST /api/search` | 없음 (BE DB 검색) / 내부 `POST /search` 별도 | `GlobalSearchService`, HybridSearchAgent + RerankAgent | ✅ BE 검색 실동작, AI 내부 RAG 검색 실동작 |
| `/search` (LLM 답변 모드) | public BE endpoint 없음 | `POST /gen-search` | HybridSearch + Rerank + AnswerAgent | 🟡 AI 내부 API만 존재. LLM optional, fallback은 `sc_passed=false` |
| `/search` (자동완성) | `GET /api/search/suggestions` | `GET /enrichment/keywords/suggest` (신규) | SearchSuggestAgent | 🔴 |

### 2.4 Briefings (user-triggered)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/briefings` 리스트 | `GET /api/briefings` | (BE-only — briefing_reports SELECT) | — | ⬜ |
| `/briefings/today` | `GET /api/briefings/today` | (BE-only — 가장 최근 briefing 조회) | — | ⬜ |
| `/briefings/new` (생성) | `POST /api/briefings/generate` | `POST /briefing/generate` | **BriefingGenerationAgent** | ✅ 위임 |
| `/briefings/new` polling | `GET /api/briefings/{id}/status` | 없음 | `briefing_reports` read model | 🟡 저장된 결과만 조회 |
| `/briefings/{id}` | `GET /api/briefings/{id}` | 없음 | `briefing_reports` read model | 🟡 저장된 결과만 조회 |
| `/briefings/{id}/share` | `POST /api/briefings/{id}/share` | 없음 | — | 🔴 `briefing_share_store_unavailable` |

### 2.5 Cards

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/cards` 리스트 | `GET /api/cards` | (BE-only — card_news SELECT + filter) | — | ✅ 실 DB 조회 |
| `/cards/{id}` | `GET /api/cards/{id}` | (BE-only — card_news WHERE id=) | — | ✅ 실 DB 조회, 미존재 시 `no_saved_card` |
| `/cards/{id}/verify-link` | `POST /api/cards/{id}/verify-link` | `POST /link/verify` | **LinkVerificationAgent** | ✅ 위임 |
| `/cards/{id}/share` | `POST /api/cards/{id}/share` | 없음 | — | 🔴 `card_share_store_unavailable` |

### 2.6 Mixer (synthesis)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/mixer` (options) | `GET /api/mixer/options` | (BE-only — meta sectors / event_types) | — | ⬜ |
| `/mixer` (run) | `POST /api/mixer` / `POST /api/mixer/stream` | `POST /mixer/analyze` / `/mixer/analyze/stream` | **MixerAnalysisAgent** | ✅ 위임 |
| `/mixer/{id}/share` | `POST /api/mixer/{id}/share` | 없음 | `mixer_results` read model | 🟡 저장 결과 payload 반환. 별도 token store 없음 |

### 2.7 Insight

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/insights/latest` | `GET /api/insights/latest` | (BE-only — insight_results SELECT 가장 최근) | — | 🟡 저장 read model 미구현, `no_saved_insight` |
| `/insights/generate` | `POST /api/insights/generate` | `POST /insight/generate` | **InsightCascadeAgent** | ✅ 위임 |

### 2.8 Chat (FloatingAiChat)

| Frontend widget | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| FloatingAiChat 메시지 | `POST /api/assistant/chat` | `POST /chat` | **ChatOrchestratorAgent** (routes to Search/Insight/Mixer/Peer) | ✅ 위임. 장애 시 degraded system response |

### 2.9 Alerts (Weak Signal + 사용자 rule)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/alerts` 리스트 | `GET /api/alerts` | (BE-only — alerts SELECT) | — | 🟡 |
| `/alerts/{id}/read` | `POST /api/alerts/{id}/read` | (BE-only — UPDATE) | — | ⬜ |
| `/alerts/rules` CRUD | `GET/POST/PUT/DELETE /api/alerts/rules` | (BE-only — alert_rules CRUD) | — | ⬜ |
| `/alerts/settings` | `GET/PUT /api/alerts/settings` | (BE-only — notification_settings) | — | ⬜ |
| (background) | BE public trigger 없음 | `POST /weak-signal/run` | **WeakSignalAgent** | 🔴 미구현. axis-ai 501 반환 |
| `/alerts/dispatched/weak-signals` | `GET /api/weak-signals?since=&peer=` | (BE-only — active table 없음, V30 archive는 `legacy_records`) | — | 🔴 |

### 2.10 Enrichment (Keyword graph / WordCloud)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/keyword-graph` | `GET /api/keyword-graph` | `GET /enrichment/keyword-graph` (신규) | **KeywordGraphBuilderAgent** | 🔴 |
| `/keyword-graph/{nodeId}/cards` | `GET /api/keyword-graph/{nodeId}/cards` | (BE-only — card_news WHERE keyword=) | — | ⬜ |
| (Monitoring 화면 내부) Word cloud | (`/api/monitoring/{peerId}` 응답에 nested) | `GET /enrichment/wordcloud?peer=` (신규) | **PeerWordCloudAgent** | 🔴 |

### 2.11 Admin

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/admin/peers` CRUD | `GET/POST/PUT/DELETE /api/admin/peers` | (BE-only — peer_companies CRUD) | — | ⬜ |
| `/admin/sources` | `GET/PUT /api/admin/sources` | (BE-only — data_sources, axis-ai 의 source 설정과 sync 필요 — 환경변수 또는 별도 sync API) | — | ⬜ (sync 메커니즘 TBD) |
| `/admin/prompts` | `GET/PUT /api/admin/prompts` | **READ-ONLY** at axis-ai (각 agent 파일의 `PROMPT_VERSION` 상수 노출 — 변경은 git PR) | — | 🟡 (prompt 수정 UI 는 위험성 高, 디자인상 read-only 권장) |
| `/admin/scheduler` | `GET/PUT /api/admin/scheduler` | (BE-only — Spring @Scheduled 메타) | — | ⬜ |
| `/admin/usage` | `GET /api/admin/usage` | `GET /admin/usage?from=&to=` (신규) | **TokenBudgetMiddleware** | 🔴 (V13 usage_logs 필요) |
| `/admin/usage/limits` | `PUT /api/admin/usage/limits` | `PUT /admin/usage/limits` (신규) | TokenBudgetMiddleware | 🔴 |
| `/admin/audit-logs` | `GET /api/admin/audit-logs` | (BE-only — audit_logs SELECT) | **AuditLogMiddleware** (write 측) | 🔴 (V14 audit_logs 필요) |
| `/admin/trace/{trace_id}` (외부 redirect) | `GET /api/admin/trace/{trace_id}` (302) | (BE-only — Langfuse URL composer) | **observability-langfuse** | 🔴 (Langfuse self-host 후 활성). UI 의 "trace 보기" 버튼이 `langfuse.skala-ai.com/traces/{trace_id}` 로 이동 — admin 만 접근 |

### 2.12 Pipeline ops

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/admin/pipeline/status` | `GET /api/pipeline/status` | (BE-only — V30 이후 active table 없음. 필요 시 `legacy_records` archive 또는 신규 ops store) | — | 🟡 |
| `/admin/pipeline/trigger` | `POST /api/pipeline/trigger` | `POST /pipeline/run` | (각 supervisor) | ✅ |
| (background) | `BriefingService` (Spring @Scheduled) | `POST /pipeline/delivery` | EmailAgent 등 | ✅ |

### 2.13 Auth / Bookmark / Settings (전부 BE-only)

| Frontend | BE endpoint | axis-ai | 상태 |
|---|---|---|---|
| Signup / Login / Logout / Refresh / Me / Verify-email | `/api/auth/*` | ⬜ N/A | ⬜ |
| Bookmark CRUD | `/api/bookmarks*` | ⬜ N/A | ⬜ |
| Settings (alert rules / notifications / profile / password / view prefs / access logs) | `/api/settings/*` | ⬜ N/A | ⬜ |
| Notification list | `/api/notifications` | ⬜ N/A | ⬜ |

### 2.14 Admin Observability (admin_page.md 정합 — 신규 P9)

| Frontend | BE endpoint | axis-ai | 담당 | 상태 |
|---|---|---|---|---|
| (모든 FE 화면) frontend SDK 자동 push | `POST /api/events` (batch) | ⬜ (BE 직 INSERT to `user_events`) | **admin/user_events.md** | 🔴 (V15 user_events 필요) |
| 카드 detail 👍/👎 | `POST /api/cards/{id}/feedback` | ⬜ (BE INSERT + Langfuse score push) | **admin/feedback.md** | 🔴 (V16 feedback) |
| 브리핑 detail 👍/👎 | `POST /api/briefings/{id}/feedback` | ⬜ | admin/feedback.md | 🔴 |
| 인사이트 detail 👍/👎 | `POST /api/insights/{id}/feedback` | ⬜ | admin/feedback.md | 🔴 |
| 믹서 result 👍/👎 | `POST /api/mixer/{id}/feedback` | ⬜ | admin/feedback.md | 🔴 |
| 챗 turn 👍/👎 | `POST /api/chat/turns/{turn_id}/feedback` | ⬜ | admin/feedback.md | 🔴 |
| 환각 신고 alert | `POST /api/cards/{id}/feedback` (reported_issue=hallucination) | ⬜ (BE → email ops) | admin/feedback.md | 🔴 |
| 비용 정산 (FinOps view) | `GET /api/admin/usage/billed-vs-estimated?from=&to=` | (BE-only — Spring @Scheduled cron 결과 SELECT) | **admin/cost_reconciliation.md** | 🔴 (V17/V18 + IRSA SA) |
| 인프라 비용 | (`/api/admin/usage` 응답에 nested) | (BE-only — AWS Cost Explorer ETL) | admin/cost_reconciliation.md | 🔴 |
| Grafana iframe URL | `GET /api/admin/dashboards` | ⬜ (BE — admin role 인증 후 5 폴더 URL list 반환) | **admin/metrics_exporter.md** (본 레포) | ⏸ **P10+ 보류** |
| Prometheus scrape | (annotation auto-discover) | `GET /metrics` (신규) | admin/metrics_exporter.md | ⏸ **P10+ 보류** |
| BE 메트릭 scrape | (annotation auto-discover) | (BE-only — Spring Actuator `/actuator/prometheus`) | admin/metrics_exporter.md | ⏸ **P10+ 보류** |
| Trace drill-down (admin) | `GET /api/admin/trace/{trace_id}` (302) | (BE-only — Langfuse URL 합성) | OBSERVABILITY_LANGFUSE.md (본 레포) | 🔴 |

## 3. axis-ai endpoint 카탈로그 (현재 vs 신규 필요)

### 3.1 현재 (router.py)

| Endpoint | 상태 | 호출자 |
|---|---|---|
| `GET /health` | ✅ 실 (DB + Qdrant 헬스체크) | BE liveness / readiness probe |
| `POST /pipeline/run` | ✅ 실 | `PipelineController.trigger`, Spring @Scheduled |
| `POST /pipeline/delivery` | ✅ 실 | `BriefingService.generateAndSend` |
| `GET /api/cards` | ✅ 실 (Classification + Summary + Analysis + CardNews chain) | (frontend 우회 직접 호출 — BE bypass) |
| `GET /api/cards/today` | ✅ 실 | (frontend 우회) |
| `POST /search` | ✅ 실 (BGE-M3 dense+sparse RRF + rerank, 장애 시 502) | 내부 API / diagnostics |
| `POST /gen-search` | 🟡 실험적 (검색 근거 + LLM optional, fallback 시 `sc_passed=false`) | 내부 API |
| `POST /chat` | ✅ 실 | `AssistantController` |
| `POST /chat/pdf` | ✅ 실 | `AssistantController` |
| `POST /today-insight/generate` | ✅ 실 | `DashboardController` |
| `POST /insight/generate` | ✅ 실 | `InsightController` |
| `POST /mixer/analyze` | ✅ 실 | `MixerController` |
| `POST /mixer/analyze/stream` | ✅ 실 | `MixerController` |
| `POST /briefing/generate` | ✅ 실 | `BriefingController` |
| `POST /global/trends/run` | ✅ 실 | `GlobalTrendsController` |
| `POST /peer/compare` | ✅ 실 | `MonitoringController.getPeerStrategy` |
| `POST /link/verify` | ✅ 실 | `CardController.verifyCardLinks` |
| `POST /weak-signal/run` | 🔴 501 `WEAK_SIGNAL_NOT_IMPLEMENTED` | diagnostics only |

### 3.2 남은 후보 endpoint (디자인 기반)

| Endpoint | 담당 agent | 우선순위 | BE 호출자 |
|---|---|---|---|
| `POST /chat` | ChatOrchestratorAgent | 완료 | `AssistantController.sendAssistantChatMessage` |
| `POST /insight/generate` | InsightCascadeAgent | 완료 | `InsightController.generateInsight` |
| `POST /mixer/analyze` | MixerAnalysisAgent | 완료 | `MixerController.runMixer` |
| `GET /monitoring/{peer}/strategy` | PeerComparisonAgent | P7 | `MonitoringController.getPeerStrategy` |
| `GET /monitoring/{peer}/profile` | PeerComparisonAgent (profile mode) | P7 | `MonitoringController.getPeerDetail` (현재 fixture) |
| `POST /link/verify` | LinkVerificationAgent | 완료 | `CardController.verifyCardLinks` |
| `POST /briefing/generate` | **BriefingGenerationAgent** | 완료 | `BriefingController.generateBriefing` |
| `GET /briefings/{id}/status` | BE read model | 완료(저장 결과 조회) | `BriefingController.getBriefingGenerationStatus` |
| `GET /briefings/{id}` | BE read model | 완료(저장 결과 조회) | `BriefingController.getBriefingById` |
| `GET /enrichment/keyword-graph` | KeywordGraphBuilderAgent | P6 | `KeywordGraphController.getKeywordGraph` |
| `GET /enrichment/wordcloud` | PeerWordCloudAgent | P6 | `MonitoringController` (nested 응답) |
| `GET /enrichment/keywords/suggest` | SearchSuggestAgent | P6 | `SearchController.suggestions` |
| `GET /metrics/top-insights` | DerivedMetricsAgent (top_insight) | P6 | `DashboardController.getDashboardSummary` |
| `GET /metrics/monitoring-overview` | DerivedMetricsAgent (monitoring_overview) | P6 | `MonitoringController.getMonitoringOverview` |
| `GET /metrics/trends` | DerivedMetricsAgent (trend) | P6 | (TBD — frontend 가 별도 트렌드 패널 추가 시) |
| `GET /admin/usage` | TokenBudgetMiddleware | P9 | `AdminController.adminGetUsage` |
| `PUT /admin/usage/limits` | TokenBudgetMiddleware | P9 | `AdminController.adminSetUsageLimits` |

남은 신규 후보 endpoint는 profile/wordcloud/metrics/admin usage 계열이다. 분석·대화·브리핑·링크검증 핵심 위임은 이미 `AiClientService`에 존재한다.

## 4. 위임 패턴 — Backend 의 `AiClientService` 현황

현재 구현된 axis-ai 위임 method:

```java
public Mono<SearchResponse> search(SearchRequest request);       // POST /search (내부/레거시 DTO)
public Mono<Void> triggerPipeline(String track, List<String> peerIds);
public Mono<BriefingContent> buildBriefing(List<CardNewsResponse> cards);
public Mono<Map<String, Object>> generateInsight(List<String> cardIds, Map<String, Object> context);
public Mono<Map<String, Object>> runMixer(List<String> cardIds, Map<String, Object> ratios, String userContext, String analysisMode);
public Flux<String> runMixerStream(List<String> cardIds, Map<String, Object> ratios, String userContext, String analysisMode);
public Mono<Map<String, Object>> generateTodayInsight(Map<String, Object> request);
public Mono<Map<String, Object>> generateBriefing(Map<String, Object> request);
public Mono<Map<String, Object>> comparePeer(String peerId, Integer windowDays, String focusSector);
public Mono<Map<String, Object>> runGlobalTrends(List<String> companyIds, List<String> focusThemes, Integer windowDays, List<String> skAxBusinessLines);
public Mono<Map<String, Object>> verifyLink(String cardId);
public Mono<Map<String, Object>> chat(Map<String, Object> request);
public Mono<Map<String, Object>> chatPdf(Map<String, Object> request, MultipartFile file);
public Mono<Void> triggerWeakSignal();                           // axis-ai 501, 운영 미활성
```

## 5. DB 마이그레이션 현황

최신 migration 기준은 `axis-backend/src/main/resources/db/migration`의 V44이다. V30에서 legacy 테이블을 `legacy_records`로 보존 archive했고, 이후 V31~V44에서 crawler/parser fact schema, card anchor FK, context engine, auth/personalization, notification, global search index, today insight, assistant conversation, peer LLM snapshot, baseline seed가 추가됐다.

| 버전 | 파일명 | 역할 |
|---|---|---|
| V28 | `V28__consolidate_raw_article_metadata_and_stock_prices.sql` | source별 raw article metadata를 `raw_article_source_metadata`로 통합 |
| V29 | `V29__front_product_read_models_and_analysis_tables.sql` | Peer+ 컬럼, 카드 키워드 컬럼, Mixer/Insight/Global read model 추가 |
| V30 | `V30__collapse_legacy_tables_into_minimal_product_schema.sql` | 레거시 테이블 row archive 후 12개 앱 테이블 중심으로 축소 |
| V36 | `V36__global_search_indexes.sql` | DB 기반 `/api/search`용 global search text/index |
| V41 | `V41__add_today_insight_reports.sql` | Today Insight 저장 read model |
| V42 | `V42__assistant_conversations.sql` | Assistant conversation 저장 |
| V43 | `V43__add_peer_llm_analysis_snapshots.sql` | Peer LLM analysis snapshot |
| V44 | `V44__seed_2026_06_11_baseline_reports.sql` | 2026-06-11 baseline reports seed |

V30 이후 active 앱 테이블:

```text
peer_companies
crawl_cursors
raw_articles
raw_article_source_metadata
raw_article_parse_results
card_news
market_price_ohlcv
briefing_reports
mixer_results
insight_reports
global_industry_trends
legacy_records
```

## 6. 보안 / 권한 매핑

| Endpoint | 누가 호출 | 인증 | 비고 |
|---|---|---|---|
| BE `/api/*` (전부) | frontend (사용자 JWT) | JWT required (auth 제외) | |
| BE → axis-ai (전부) | `AiClientService` (서버 측) | mTLS or in-cluster only | 8001 포트 외부 노출 금지 (k8s NetworkPolicy) |
| axis-ai `GET /health` | k8s liveness probe | 인증 없음 | |
| axis-ai 기타 | BE only | (in-cluster network 격리) | |
| frontend → axis-ai 직접 | **불허** — 단 임시로 `/api/cards*` 는 우회 중. 정리 필요 | — | 정리 후 BE 위임 표준 |

## 7. 개선 우선순위 (정리 PR plan)

> 2026-05-13 결정: Grafana / metrics-exporter 통합은 보류, **Langfuse + DB schema** 먼저.

1. **P9 (W8) — 지금 진행** — Langfuse v2 self-host helm (team13 namespace, PG 5Gi only) → ingress `langfuse.skala25a.project.skala-ai.com`
2. **P9 (W8) — 지금 진행** — Flyway 마이그 V10~V18 (chat / weak_signal / briefing / usage / audit / events / feedback / cost ×2 = 9개)
3. **P9 (W8)** — axis-ai LangChain CallbackHandler + tiktoken + provenance.langfuse_trace_id 적재
4. **P9 (W8)** — axis-backend: UsageService / AuditAspect / FeedbackController / EventController 실 구현 (관련 fixture 교체)
5. **P6 / P7 / P7+ / P8** (기존 plan, Langfuse + DB 완료 후) — Search → Analysis → Briefing → Chat → Weak signal endpoint 활성
6. **P10+** — Frontend `/api/cards*` 우회 정리 → BE 위임
7. **⏸ P10+ 보류** — 공용 Prometheus / Grafana / Loki / Tempo 통합 (admin/metrics_exporter.md). 공용 인프라 활용 spec 재작성 + 매니저 협의 후 진행

## 8. Open Questions

- **Prompt versioning UI** — `/admin/prompts` 는 LLM prompt 를 사용자가 수정할 수 있게 하는 것이 위험. 디자인은 read-only 권장 (변경은 git PR). UX 미팅 필요.
- **axis-ai `/admin/usage` 인증** — BE 가 호출하더라도 admin role 확인은 BE 측 책임으로 충분. axis-ai 가 추가 인증 안 함.
- **Insight / Mixer 결과 영속화** (V15) — 매번 LLM 재생성 vs 저장? 비용 vs UX 트레이드오프. 현재 디자인은 매번 재생성.
- **Frontend 직접 axis-ai 호출 (cards)** — 정리할 PR 우선순위 → P9 권장 (지금은 동작하니까 후순위).
