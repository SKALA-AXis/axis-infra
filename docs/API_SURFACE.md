# API Surface — Frontend ↔ Backend ↔ axis-ai 매핑

> **버전**: v1 (2026-05-13)
> **목적**: 각 frontend view 가 호출하는 BE endpoint, BE 가 다시 호출해야 할 axis-ai endpoint, 담당 agent 의 일관 매핑. 디자인 디렉토리 의 agent 들이 *어디서 어떻게 노출되는지* 명시.

## 1. 현재 통합 상태 요약

| 영역 | BE 컨트롤러 | axis-ai 위임 | 상태 |
|---|---|---|---|
| Pipeline trigger | `PipelineController.trigger` | ✅ `POST /pipeline/run` | 실 동작 |
| Daily briefing email | `BriefingService.generateAndSend` | ✅ `POST /pipeline/delivery` | 실 동작 (W6 SES 검증 완료) |
| Card list / today / detail | `CardController` | ❌ (fixture) — 실은 axis-ai `GET /api/cards` 가 동작 중 | BE 우회 — frontend 가 직접 axis-ai 호출 안 함 |
| Search | `SearchController` | ❌ (fixture) — axis-ai `POST /search` 는 stub | 양쪽 stub |
| Generative search | `SearchController` | ❌ (fixture) — axis-ai `POST /gen-search` 는 stub | 양쪽 stub |
| Chat (assistant) | `AssistantController` | ❌ (fixture) — axis-ai endpoint 자체 미존재 | 미연결 |
| Insight | `InsightController` | ❌ (fixture) — axis-ai endpoint 미존재 | 미연결 |
| Mixer | `MixerController` | ❌ (fixture) — axis-ai endpoint 미존재 | 미연결 |
| Briefing (user-triggered) | `BriefingController` | ❌ (fixture) — axis-ai endpoint 미존재 | 미연결 |
| Monitoring strategy | `MonitoringController.getPeerStrategy` | ❌ (fixture) — axis-ai endpoint 미존재 | 미연결 |
| Card verify-link | `CardController.verifyCardLinks` | ❌ (fixture) — axis-ai endpoint 미존재 | 미연결 |
| Weak signal | (BE 호출 없음) | axis-ai `POST /weak-signal/run` — orphan stub | 양쪽 미연결 |
| Keyword graph | `KeywordGraphController` | ❌ (fixture) — axis-ai endpoint 미존재 | 미연결 |
| Alert / Bookmark / Auth / Settings / Admin | 각 controller | ❌ (전부 fixture, 대부분 axis-ai 불필요 — pure BE/DB) | BE-only TBD |

**결론**: 디자인된 35개 agent 중 *실제로 production 경로로 호출되는 것은* CardComposer / Crawler / Parser / Credibility / Relevance / Dedup / Classification / Evidence (Ingestion 8개) + EmbedIndex + EmailAgent (Delivery 2개) = **10개**. 나머지 25개는 endpoint 가 미존재하거나 양쪽 (BE+axis-ai) stub.

## 2. Frontend View → BE → axis-ai → Agent 매핑표

> 표 기호: ✅ 실 동작 / 🟡 BE 만 fixture, axis-ai 미연결 / 🔴 양쪽 미존재 / ⬜ AI 불필요 (BE-only)

### 2.1 Home / Today

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/` (TodayView 카드 carousel) | `GET /api/cards/today` | `GET /api/cards/today` (axis-ai 직접 — 실 동작) | CardComposerAgent chain | 🟡 (BE 는 fixture, FE 가 직접 axis-ai 호출하는 임시 경로) |
| `/` (TodayView 요약 배지) | `GET /api/dashboard/summary` | `GET /metrics/top-insights` (신규) | DerivedMetricsAgent (mode=top_insight) | 🔴 |
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
| `/search` 결과 list | `POST /api/search` | `POST /search` (HybridSearch RRF) | HybridSearchAgent + RerankAgent | 🟡 (양쪽 stub) |
| `/search` (LLM 답변 모드) | `POST /api/search?gen=true` (or 별도) | `POST /gen-search` | HybridSearch + Rerank + AnswerAgent | 🟡 (양쪽 stub) |
| `/search` (자동완성) | `GET /api/search/suggestions` | `GET /enrichment/keywords/suggest` (신규) | SearchSuggestAgent | 🔴 |

### 2.4 Briefings (user-triggered)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/briefings` 리스트 | `GET /api/briefings` | (BE-only — briefing_reports SELECT) | — | ⬜ |
| `/briefings/today` | `GET /api/briefings/today` | (BE-only — 가장 최근 briefing 조회) | — | ⬜ |
| `/briefings/new` (생성) | `POST /api/briefings/generate` | `POST /briefings/generate` (신규) | **BriefingGenerationAgent** (V12) | 🔴 (양쪽 fixture) |
| `/briefings/new` polling | `GET /api/briefings/{id}/status` | `GET /briefings/{id}/status` (신규) | BriefingGenerationAgent | 🔴 |
| `/briefings/{id}` | `GET /api/briefings/{id}` | `GET /briefings/{id}` (신규) | BriefingGenerationAgent | 🔴 |
| `/briefings/{id}/share` | `POST /api/briefings/{id}/share` | (BE-only — share token 발급) | — | ⬜ |

### 2.5 Cards

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/cards` 리스트 | `GET /api/cards` | (BE-only — card_news SELECT + filter) | — | 🟡 (BE 가 fixture, axis-ai `/api/cards` 가 실 동작 중) |
| `/cards/{id}` | `GET /api/cards/{id}` | (BE-only — card_news WHERE id=) | — | 🟡 |
| `/cards/{id}/verify-link` | `POST /api/cards/{id}/verify-link` | `POST /cards/{id}/verify-link` (신규) | **LinkVerificationAgent** | 🔴 |
| `/cards/{id}/share` | `POST /api/cards/{id}/share` | (BE-only — share token) | — | ⬜ |

### 2.6 Mixer (synthesis)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/mixer` (options) | `GET /api/mixer/options` | (BE-only — meta sectors / event_types) | — | ⬜ |
| `/mixer` (run) | `POST /api/mixer` | `POST /mixer` (신규) | **MixerAnalysisAgent** | 🔴 (양쪽 fixture) |
| `/mixer/{id}/share` | `POST /api/mixer/{id}/share` | (BE-only — share token) | — | ⬜ |

### 2.7 Insight

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/insights/latest` | `GET /api/insights/latest` | (BE-only — insight_results SELECT 가장 최근) | — | 🟡 (storage 자체 없음, fixture만) |
| `/insights/generate` | `POST /api/insights/generate` | `POST /insights/generate` (신규) | **InsightCascadeAgent** | 🔴 |

### 2.8 Chat (FloatingAiChat)

| Frontend widget | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| FloatingAiChat 메시지 | `POST /api/assistant/chat` | `POST /chat` (신규) | **ChatOrchestratorAgent** (routes to Search/Insight/Mixer/Peer) | 🔴 (BE fixture, axis-ai 미존재) |

### 2.9 Alerts (Weak Signal + 사용자 rule)

| Frontend route | BE endpoint | axis-ai endpoint | 담당 agent | 상태 |
|---|---|---|---|---|
| `/alerts` 리스트 | `GET /api/alerts` | (BE-only — alerts SELECT) | — | 🟡 |
| `/alerts/{id}/read` | `POST /api/alerts/{id}/read` | (BE-only — UPDATE) | — | ⬜ |
| `/alerts/rules` CRUD | `GET/POST/PUT/DELETE /api/alerts/rules` | (BE-only — alert_rules CRUD) | — | ⬜ |
| `/alerts/settings` | `GET/PUT /api/alerts/settings` | (BE-only — notification_settings) | — | ⬜ |
| (background) | (Spring @Scheduled Mon 09:00) | `POST /weak-signal/run` | **WeakSignalAgent** (legacy table 제거, 새 read model 필요 시 `card_news` 기반) | 🔴 (axis-ai stub, BE 호출 미연결) |
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
| `POST /search` | 🟡 stub | (없음 — BE SearchController 도 fixture) |
| `POST /gen-search` | 🟡 stub | (없음) |
| `POST /weak-signal/run` | 🟡 stub | (orphan — BE 가 호출 안 함) |

### 3.2 신규 추가 필요 endpoint (디자인 기반)

| Endpoint | 담당 agent | 우선순위 | BE 호출자 |
|---|---|---|---|
| `POST /chat` | ChatOrchestratorAgent | P8 | `AssistantController.sendAssistantChatMessage` |
| `POST /insights/generate` | InsightCascadeAgent | P7 | `InsightController.generateInsight` |
| `POST /mixer` | MixerAnalysisAgent | P7 | `MixerController.runMixer` |
| `GET /monitoring/{peer}/strategy` | PeerComparisonAgent | P7 | `MonitoringController.getPeerStrategy` |
| `GET /monitoring/{peer}/profile` | PeerComparisonAgent (profile mode) | P7 | `MonitoringController.getPeerDetail` (현재 fixture) |
| `POST /cards/{id}/verify-link` | LinkVerificationAgent | P7 | `CardController.verifyCardLinks` |
| `POST /briefings/generate` | **BriefingGenerationAgent** | P7+ | `BriefingController.generateBriefing` |
| `GET /briefings/{id}/status` | BriefingGenerationAgent | P7+ | `BriefingController.getBriefingGenerationStatus` |
| `GET /briefings/{id}` | BriefingGenerationAgent | P7+ | `BriefingController.getBriefingById` |
| `GET /enrichment/keyword-graph` | KeywordGraphBuilderAgent | P6 | `KeywordGraphController.getKeywordGraph` |
| `GET /enrichment/wordcloud` | PeerWordCloudAgent | P6 | `MonitoringController` (nested 응답) |
| `GET /enrichment/keywords/suggest` | SearchSuggestAgent | P6 | `SearchController.suggestions` |
| `GET /metrics/top-insights` | DerivedMetricsAgent (top_insight) | P6 | `DashboardController.getDashboardSummary` |
| `GET /metrics/monitoring-overview` | DerivedMetricsAgent (monitoring_overview) | P6 | `MonitoringController.getMonitoringOverview` |
| `GET /metrics/trends` | DerivedMetricsAgent (trend) | P6 | (TBD — frontend 가 별도 트렌드 패널 추가 시) |
| `GET /admin/usage` | TokenBudgetMiddleware | P9 | `AdminController.adminGetUsage` |
| `PUT /admin/usage/limits` | TokenBudgetMiddleware | P9 | `AdminController.adminSetUsageLimits` |

총 신규 **17 endpoint** (모두 backend 가 호출 — frontend 가 axis-ai 직접 호출하는 것은 보안상 금지).

## 4. 위임 패턴 — Backend 의 `AiClientService` 확장

현재 (`AiClientService.java`):

```java
public Map<String, Object> triggerPipeline(String track, List<String> peerIds);
public Map<String, Object> buildBriefing(List<Map<String, Object>> cards);
```

위 §3.2 의 신규 endpoint 마다 method 추가 필요:

```java
// Analysis supervisor
public InsightCascadeResult generateInsight(InsightRequest req);
public MixerResult runMixer(List<String> cardIds);
public PeerStrategy getPeerStrategy(String peerId);
public LinkVerifyResult verifyCardLinks(String cardId);

// UserQuery supervisor
public SearchResult search(SearchRequest req);                  // POST /search
public GenSearchResult genSearch(SearchRequest req);            // POST /gen-search
public ChatResponse chat(ChatRequest req);                      // POST /chat

// Briefing supervisor
public BriefingAccepted generateBriefingAsync(BriefingRequest req);
public BriefingStatus getBriefingStatus(String briefingId);
public BriefingReport getBriefing(String briefingId);

// Enrichment supervisor
public KeywordGraph getKeywordGraph();
public WordCloudResult getWordCloud(String peerId);
public List<String> suggestKeywords(String prefix);

// Metrics
public TopInsight getTopInsight();
public MonitoringOverview getMonitoringOverview();

// Admin
public UsageStats getUsageStats(LocalDate from, LocalDate to);
public ApiResponse updateUsageLimits(UsageLimits limits);
```

## 5. DB 마이그레이션 현황

최신 기준은 V30이다. V10~V28에서 늘어난 운영/관계/로그 테이블은 V30에서 `legacy_records`로 보존 archive되고, 프론트 화면에 필요한 값만 최소 read model로 흡수된다.

| 버전 | 파일명 | 역할 |
|---|---|---|
| V28 | `V28__consolidate_raw_article_metadata_and_stock_prices.sql` | source별 raw article metadata를 `raw_article_source_metadata`로 통합 |
| V29 | `V29__front_product_read_models_and_analysis_tables.sql` | Peer+ 컬럼, 카드 키워드 컬럼, Mixer/Insight/Global read model 추가 |
| V30 | `V30__collapse_legacy_tables_into_minimal_product_schema.sql` | 레거시 테이블 row archive 후 12개 앱 테이블 중심으로 축소 |

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
