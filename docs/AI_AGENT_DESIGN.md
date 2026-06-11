# AXIS AI Agent 설계서 v1.1

> **작성**: 2026-05-12 · **검증·정정**: 2026-05-13 (v1 → v1.1) · **상태**: Proposed · **범위**: axis-ai 전 영역 + axis-backend 의 분석 위임 endpoint
>
> **분석 기반 (정정 후)**:
> 1. 운영 배포된 frontend (`http://skala3-team13-axis-alb-1349892737...`) 의 routing key 10개 + 실 `*View.tsx` 9개 인벤토리
> 2. `axis-frontend/src/` 컴포넌트 + mock 데이터 + `httpClient` 호출 경로
> 3. **`axis-infra/api/openapi.yaml` 의 71개 `/api/*` endpoint 전수**
> 4. **`axis-backend/src/main/java/com/skala/axis/controller/` 의 22개 controller (현재 22 controllers 가 `ApiContractFixtureService` 의 fixture 만 리턴 — axis-ai 위임 미구현 상태)**
> 5. 기존 LangGraph 그래프 — `ingestion_graph.py` 의 **8-node 흐름** + `delivery_graph.py` (현재 dead 1-node)
> 6. `axis-ai/src/agents/*.py` 의 **실 16개 agent** (+ `_deprecated/` 의 3개 폐기 agent)
>
> **v1 → v1.1 핵심 차이**: §1 매트릭스 endpoint path 정정 (`/api/mixer/analyze` → `POST /api/mixer` 등), §3 IngestionSupervisor 8-node 로 확장 (preprocess_route + vector_index 추가), §3.5 DialogueSupervisor 의 backend 상태 정정 (`/api/assistant/chat` 이미 fixture 존재), §3.7 WeakSignal "신규" → "재구축" (구 `_deprecated/weak_signal_agent.py`), §3.9 **specialized parser agents** 7개 신규 카탈로그, frontend §1 매트릭스에 **MonitoringView · AlertsView · NotificationView** 추가, Bookmark/Share/Verify-link 기능 누락 보완. 자세한 changelog 는 §11 참조.
>
> **설계 원칙**:
> 1. **OPTIMIZED** — agent 수 최소화. 같은 기능을 두 곳에서 부르지 말고 cross-supervisor 재사용
> 2. **Function-named** — agent 명은 *무엇을 만드는지* 기준 (table 명 아님)
> 3. **Deterministic-first, LLM-last** — 산식으로 가능한 건 산식. LLM 은 자연어 생성 + 분류만
> 4. **State 일방향** — agent 간 직접 호출 X, supervisor state 만 공유
> 5. **Provenance 필수** — 모든 AI 출력에 `evidence_chain.provenance` (llm_model, prompt_version, run_at, raw_article_ids) 부착
> 6. **Confidence 표면화** — `confidence < 0.6` 은 UI 에 경고 (FE 가 이미 그렇게 구현됨)

---

## §1. Frontend feature → AI capability 매핑 매트릭스

> **읽는 법**: ✨ = axis-ai 에 실 구현 + backend 가 위임 호출 / 🟡 = backend endpoint + fixture 존재, axis-ai 위임 미연결 (P6~P8 작업) / 🔴 = backend endpoint 도 없음 (신규 spec + 구현 필요) / ⚙️ = 산식 only (LLM 없음).
>
> **frontend "view"** 는 **App.tsx 의 `activeView` routing key (10개)** 와 **실 `*View.tsx` 파일 (9개)** 두 개념 공존. 다음 매트릭스는 routing key 기준 + 실 파일명 매핑.

| Frontend view (routing key) | 실 *View.tsx 파일 | UI 요소 | AI capability | 책임 agent | API endpoint (실 path) |
|---|---|---|---|---|---|
| **home** | HomeCardNewsView | Top Insight Card 자동 순환 | 카드 ranking + Top-N 선정 | ⚙️ ExposureScoreAgent (산식, 내장) + 🟡 TopInsightSelectorAgent | `GET /api/dashboard/summary` |
| home | HomeCardNewsView | Summary Carousel (Top 5) | 카드 요약 (3줄) | ✨ CardNewsAgent (class) | `GET /api/cards/today` |
| home | HomeCardNewsView | Today's Key Changes (트렌드/증감/키워드) | 트렌드 집계 + 키워드 빈도 | 🟡 TrendAggregatorAgent + KeywordExtractionAgent | `GET /api/dashboard/summary` |
| home | HomeCardNewsView | Interest Chart (관심도) | Peer 별 관심도 추이 | ⚙️ InterestTrendAgent (산식, exposure_score 시계열) | `GET /api/dashboard/summary` |
| home | HomeCardNewsView | DART Summary Radar | 재무 비율 산출 | ✨ FinancialLinkerAgent (구현) | `GET /api/monitoring/{peerId}/financials` |
| home | HomeCardNewsView | AI Context Panel | why_important / potential_impact / actions | ✨ CardNewsAgent → implication JSONB | (카드 응답에 포함) |
| **briefings** | BriefingsView | Daily/Weekly/Monthly 종합 | 기간별 카드 묶음 → 보고서급 산문 | ✨ (BE Java) BriefingService 직빌드 — sector-grouped builder | `GET /api/briefings`, `POST /api/briefings/generate`, `GET /api/briefings/today`, `GET /api/briefings/summary`, `GET /api/briefings/{id}`, `GET /api/briefings/{id}/status` |
| briefings | BriefingsView | 카드 검색 (브리핑 안에서) | filter + full-text | 재사용: BE JPA + HybridSearchAgent | `GET /api/briefings/cards/search` |
| briefings | BriefingsView | 공유 (Share) | URL 토큰 발급 | (BE-only) | `POST /api/briefings/{id}/share` |
| **insight** | (Briefings 내부 또는 별도 컴포넌트) | 4단계 분석 (Cause→Change→Impact→Response) | 복수 카드 → 인과/영향 구조 추출 | 🟡 InsightCascadeAgent (axis-ai 신규, backend fixture 존재) | `POST /api/insights/generate`, `GET /api/insights/latest` |
| insight | — | Confidence 표시 (<0.6 warning) | 분석 신뢰도 | Cross-cutting: ConfidenceScoreAgent | (응답 필드) |
| **peerPlus / monitoring** | MonitoringView | Peer 4사 모니터링 overview | 비교 표 + 트렌드 | 🟡 MonitoringOverviewAgent (집계 산식 + 메타) | `GET /api/monitoring`, `GET /api/monitoring/overview`, `GET /api/monitoring/comparison` |
| peerPlus | MonitoringView | Peer 상세 | 카드 + 재무 + 전략 | 재사용 | `GET /api/monitoring/{peerId}`, `GET /api/monitoring/{peerId}/cards` |
| peerPlus | MonitoringView | Peer IR Numeric Pack | 재무 지표 segment matching | ✨ FinancialLinkerAgent | `GET /api/monitoring/{peerId}/financials` |
| peerPlus | MonitoringView | 차별 시사점 (SK AX vs Peer 전략 비교) | 경쟁사 비교 분석 | 🟡 PeerComparisonAgent → `/strategy` endpoint | `GET /api/monitoring/{peerId}/strategy` |
| peerPlus | MonitoringView | 워드클라우드 (기술/사업/MOU) | Peer 별 키워드 클러스터링 + 카테고리화 | 🟡 PeerWordCloudAgent | (현재 spec 없음 — `GET /api/peers/{peerId}/wordcloud` 신규 추가 후보) |
| peerPlus | — | Peer 프로필 (basic info) | (AI 비관여, 메타데이터) | — | `GET /api/peers`, `GET /api/peers/{peerId}/profile` |
| **issues** | IssuesView | 카드 필터/검색 (peer/sector/date/keyword) | full-text + 메타 필터 | 재사용: BE JPA + HybridSearchAgent (자연어 시) | `GET /api/cards`, `GET /api/cards/{id}`, `GET /api/monitoring/cards/search` |
| issues | IssuesView | 검색 자동완성 | suggest top-K | 🟡 SearchSuggestAgent (산식 + 임베딩) | `GET /api/search/suggestions` |
| issues | CardNewsDetailView | 카드 상세 (implication, actions, sources) | 카드 메타 생성 | ✨ CardNewsAgent + EvidenceAgent | (카드 응답 자체) |
| issues | CardNewsDetailView | 카드 공유 | URL 토큰 발급 | (BE-only) | `POST /api/cards/{id}/share` |
| issues | CardNewsDetailView | 카드 링크 검증 (출처 living check) | URL liveness + 변경 감지 | 🟡 LinkVerificationAgent (HTTP check + diff) | `POST /api/cards/{id}/verify-link` |
| issues | IssuesView | 북마크 | (개인 메타) | — (장기적으로 → 추천 input) | `GET/POST /api/bookmarks`, `DELETE /api/bookmarks/{cardId}` |
| **mixer** | (별도 컴포넌트, BookmarkController + MixerController 사용) | 2~20 카드 조합 → 인사이트 | cross-card 신호 분석 | 🟡 MixerAnalysisAgent (axis-ai 신규) | `POST /api/mixer`, `GET /api/mixer/options`, `POST /api/mixer/{id}/share` |
| mixer | — | 신호 분포 레이더 (6축) | 6축 axes score | MixerAnalysisAgent (산식 + LLM 라벨링) | (`POST /api/mixer` 응답에 포함) |
| **keywordGraph** | (별도 컴포넌트) | 2D/3D 키워드 네트워크 | 노드/엣지 + 빈도/중요도 | 🟡 KeywordGraphBuilderAgent | `GET /api/keyword-graph` |
| keywordGraph | — | 노드 클릭 → 관련 카드 | filter by keyword | 재사용 (cards filter) | `GET /api/keyword-graph/{nodeId}/cards` |
| **alerts** | AlertsView | 알림 목록 + 읽음 처리 | (AI 비관여, BE-only) | — | `GET /api/alerts`, `POST /api/alerts/{id}/read` |
| alerts | AlertsView | Alert Rule 설정 (사용자 정의 임계값) | (AI 의 약신호 alert routing 과 연결) | 🟡 AlertRoutingAgent (W7+, WeakSignal → 매칭 사용자) | `GET/POST /api/alerts/rules`, `PUT/DELETE /api/alerts/rules/{ruleId}` |
| — | — | (frontend 페이지 없지만 endpoint 존재) Notification 목록 | (BE-only) | — | NotificationController endpoints |
| **settings** | SettingsView | 알림 설정 (이메일/in-app/Teams) | (AI 비관여 — config 만) | — | SettingsController endpoints |
| **admin** | AdminView | Peer/Source/Prompt/Scheduler/Usage/Audit 관리 | LLM token budget + prompt 버전 + audit | Cross-cutting: TokenBudgetAgent + AuditLogAgent | `/api/admin/*` (12개 path) |
| **rawArticles** | RawArticlesView | (내부용) raw_articles 직접 조회 | (debug · 비관여) | — | (RawArticleController endpoint) |
| **Floating AI Chat** | (FloatingAiChat 위젯) | 우측 하단 — 대화형 검색/명령 | intent 분기 + 대화 컨텍스트 | 🟡 DialogueSupervisor (3 agents — axis-ai 신규. BE AssistantController + `/api/assistant/chat` fixture 이미 존재) | `POST /api/assistant/chat` |
| **Top search box** | (TopNav 검색) | 자연어 검색 + 자동완성 | hybrid search + suggestions | ✨ SearchSupervisor (Embed/HybridSearch/Rerank/Answer 골격 + stub) | `POST /api/search`, `GET /api/search/suggestions` |
| **Auth** | (AuthScreen) | 로그인/회원가입/이메일 인증 | (AI 비관여) | — | `/api/auth/login`, `/signup`, `/verify-email`, `/refresh`, `/me`, `/logout` |
| **Email Briefing** | (Spring @Scheduled) | sector-grouped 본문 + SES 발송 | 발송용 본문 생성 | ✨ (BE Java) BriefingService 직빌드 + SesMailService (IRSA) | (Spring @Scheduled, 08:30 KST MON-FRI) |
| **Weak Signal Detection** (W7+) | (UI 미정) | 채용 급증 / 특허 패턴 / 이상 탐지 | 선행지표 패턴 매칭 | 🔴 WeakSignalSupervisor (`_deprecated/weak_signal_agent.py` 재구축) | (W7+ 신규 spec 필요) |

**미커버 영역** (frontend 에 표시되지 않거나 미구현):

- 사용자 개인화 (북마크 history 기반 selective interest learning) — v2 후순위
- Synthetic data (보고서용 가상 시나리오) — out of scope
- 자동 대응안 생성 (action recommendation) — InsightCascadeAgent 의 Response 단계로 흡수

**Spec 보완 필요** (P6~P9):

- `GET /api/peers/{peerId}/wordcloud` — PeerWordCloudAgent 결과 노출 (현재 openapi 없음)
- `POST /api/cards/{id}/verify-link` 의 실제 검증 로직 (현재 fixture)
- Weak Signal 결과 노출 endpoint (`GET /api/weak-signals` 등)

---

## §2. Supervisor 토폴로지 — 7 supervisors

```text
                    AxisRouterSupervisor (entry)
                              │
       ┌──────────┬───────────┼───────────┬──────────┐
       ▼          ▼           ▼           ▼          ▼
   Ingestion   Enrichment  Analysis    Search    Dialogue
       │          │           │           │          │
       ▼          ▼           ▼           ▼          ▼
   매시간 자동    매시간 후속    on-demand   user 검색  user chat
                                              ▲          │
                                              └──공유 ───┘
       ┌──────────┐                                     │
       │ Delivery │  ◀── @Scheduled 08:30 KST           │
       └──────────┘                                     │
                                                        │
       ┌──────────────┐                                 │
       │ WeakSignal   │ ◀── 주 1회 (W7+)                │
       └──────────────┘                                 │
                                                        │
       ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
       Cross-cutting (모든 supervisor 에 주입):
         Confidence · Provenance · TokenBudget · AuditLog
```

**Supervisor 분리 기준**:
1. **트리거 주기 다름** → 분리 (ADR-0004 파이프라인 분리 원칙)
2. **소비자 다름** → 분리 (Ingestion = 시스템 / Analysis = user request)
3. **상태 공유 필요** → 같은 supervisor (Dialogue 내부의 IntentRouter + Search 호출)
4. **재사용 가능한 비즈니스 책임** → cross-cutting

| Supervisor | 트리거 | 시간 예산 | LLM 호출 (cycle) | 핵심 책임 | Agent count |
|---|---|---|---|---|---|
| **Ingestion** | @Scheduled 매시간 | 30초 / cycle | ~80 calls (relevance + classify + card_news + summary) | 원문 → card_news 행 + evidence_chain (vector_index 까지) | 8 core nodes + 7 specialized sub |
| **Enrichment** | Ingestion 후 + nightly 02:00 | 60초 / cycle | ~20 calls (word cloud 카테고리 등) | 카드 → 키워드/그래프/Top 메타 + monitoring 집계 + 검색 추천 | 7 agents |
| **Analysis** | user request (POST API) | 10초 (timeout) | 3~10 per request | 깊은 분석 (Insight/Mixer/Peer 전략/Link verify) | 5 agents (BriefingComposer 는 BE Java) |
| **Search** | user request (Q&A) | 10초 | 1~3 (SC iter) | 하이브리드 검색 + 답변 | 3 agents (Embed 는 Ingestion 의 vector_index 와 공유) |
| **Dialogue** | user chat msg | 5~15초 | 2~5 per msg | FloatingAiChat 의 대화 turn | 2 신규 + Search 재사용 |
| **Delivery** | @Scheduled 08:30 KST MON-FRI | 5초 | 0 (LLM 미사용, 정적 sector 묶음) | 일일 브리핑 본문 + SES 발송 | 0 axis-ai · 1 BE Java (BriefingService) |
| **WeakSignal** | @Scheduled 월 09:00 | 60초 | ~5 | 선행지표 감지 + 사용자 rule 매칭 + alert | 3 신규 (재구축) |

---

## §3. Agent 카탈로그 (35 agents + 4 cross-cutting)

> **NOTE on numbering**: 본 §3 sub-section 의 # 칸은 v1 → v1.1 진화 과정에서 일부 sub-section 간 중복 (예: §3.3 #16 InsightCascade 와 §3.4 #16 EmbedAgent). 본문 # 는 **section 내부 reference** 용도이며, **canonical numbering 은 부록 A** (1~35 + 4 cross-cutting). 후속 PR 에서 본문 # 칸 제거 + 부록 A 만 유지 권장.

### §3.1 IngestionSupervisor — 8 nodes (실 LangGraph) ✅

**실 LangGraph node sequence (axis-ai/src/pipeline/ingestion_graph.py)**:

```text
crawl → credibility → preprocess_route → dedup → classify → card_news → evidence → vector_index
```

| # | Node | Agent (호출되는 class) | 입력 | 출력 | 산식/LLM |
|---|---|---|---|---|---|
| 1 | `crawl` | **CrawlerAgent** + sub: parser_agent · dart_parser_agent · ir_parser_agent · parser_quality_agent | peer ids + Track A/B/C | raw_articles rows + metadata | 산식 (외부 fetch + parse) |
| 2 | `credibility` | **CredibilityAgent** | raw_articles | credibility_grade (High/Medium/Low/Unverified) | 산식 (출처 화이트리스트 + 휴리스틱) |
| 3 | `preprocess_route` | **RelevanceAgent** | credible rows | relevance_score + relevance_label + matched_companies / matched_sectors | LLM (mini, zero-shot) + 키워드 매칭 |
| 4 | `dedup` | **DedupAgent** | relevant rows | cluster_id + is_representative | BGE-M3 코사인 ≥ 0.90 |
| 5 | `classify` | **ClassificationAgent** | dedup 클러스터 | event_type (6종) + sector (5종) + exposure_score + importance_score | **결정적 산식** (0.40·cluster_size + 0.30·credibility_max + 0.20·peer_mention + 0.10·tier1_diversity) + LLM 보조 (event/sector tagging) |
| 6 | `card_news` | **IssueCardAgent** (class 명 유지) + sub: **NewsSummaryAgent** · **NewsAnalysisAgent** | classified cluster + rep article + 클러스터 기사 | card_news row (title, summary_lines 3줄, implication, sources) | LLM (gpt-4o-mini) |
| 7 | `evidence` | **EvidenceAgent** + sub: **FinancialLinkerAgent** · **IRParserAgent** | card_news row + cluster article ids | evidence_chain 4종 (source_links / provenance / financial_refs / mbb_refs) | 산식 + sub-agent |
| 8 | `vector_index` | **(rag) EmbedAgent** + Qdrant upsert | passed card_news (evidence pass=true) | Qdrant axis_main 의 dense+sparse vector | 임베딩 only |

> **NOTE**:
> - `IssueCardAgent` (클래스) 는 function-named 라 코드상 유지. DB 테이블만 `card_news` 로 rename (V9). `card_news_agent.py` 파일은 frontend display dict 생성기 (별개 책임).
> - `NewsSummaryAgent` · `NewsAnalysisAgent` 는 axis-ai 의 별도 파일이며 card_news 노드 내부에서 호출.
> - `vector_index` 노드는 EmbedAgent + Qdrant write 를 단일 함수로 묶음 — agent 카탈로그상 EmbedAgent 로 표기.

### §3.2 EnrichmentSupervisor — 7 agents (신규 / 기존 일부 활용)

Ingestion 결과 위에 frontend 가 빠르게 표시할 수 있는 derived metadata 미리 계산. P6 핵심 영역.

| # | Agent | 입력 | 출력 | 산식/LLM | 트리거 | API endpoint |
|---|---|---|---|---|---|---|
| 9 | **KeywordExtractionAgent** | 최근 30일 card_news | keyword frequencies (peer × sector × keyword × count) | KR-TF-IDF (산식) | Ingestion 후 + nightly | `/api/dashboard/summary` 의 `keywordSeries` 필드 |
| 10 | **KeywordGraphBuilderAgent** | KeywordExtraction 결과 + co-occurrence | 그래프 nodes/edges + node importance | 산식 (PMI + force-directed pre-layout 옵션) | nightly 02:30 | `GET /api/keyword-graph`, `/keyword-graph/{nodeId}/cards` |
| 11 | **PeerWordCloudAgent** | Peer 별 최근 90일 card_news + event_type | category-tagged word cloud (기술/사업/MOU) | KeywordExtraction 재사용 + LLM 카테고리 라벨링 | nightly 03:00 | (신규 spec) `GET /api/peers/{peerId}/wordcloud` |
| 12 | **TopInsightSelectorAgent** | 오늘의 card_news | Home 캐러셀용 Top 5 (id 배열) | 산식 (exposure_score desc + recency boost) | 매시간 후속 | `/api/dashboard/summary` 의 `topInsightId` 필드 |
| 13 | **TrendAggregatorAgent** | 최근 7일 card_news | 트렌드 메트릭 (전주 대비 증감 %, 새 카드 수, 핫 키워드) | 산식 (count + delta) | 매시간 후속 | `/api/dashboard/summary` 의 `trends` 필드 |
| 14 | **MonitoringOverviewAgent** (v1.1 신규) | 모든 peer 의 최근 카드 + IR + 키워드 | 4사 비교 표 + peer 별 요약 메트릭 | 산식 (count + avg score + 비교 표 빌더) | nightly 04:00 | `GET /api/monitoring`, `/monitoring/overview`, `/monitoring/comparison` |
| 15 | **SearchSuggestAgent** (v1.1 신규) | 사용자 검색 prefix + 인기 키워드 + Embed | top-K 추천 (자동완성) | 산식 (trigram + popularity boost) + 옵션으로 EmbedAgent | on-demand (user 입력) | `GET /api/search/suggestions` |

> v1.1 변경: MonitoringOverviewAgent + SearchSuggestAgent 추가 (frontend `MonitoringView` / `SearchBox` 의 fixture 응답 → 실 데이터 교체용).

### §3.3 AnalysisSupervisor — 5 agents (axis-ai 신규, backend endpoint 다수 존재)

사용자 액션 (POST API) 트리거. 결과 caching (Redis 또는 DB) 권장. **backend controller + endpoint 는 이미 존재 + fixture 리턴 중** — axis-ai 위임 호출만 신규.

| # | Agent | 입력 | 출력 | 산식/LLM | API endpoint (실 path) | 현재 상태 |
|---|---|---|---|---|---|---|
| 16 | **InsightCascadeAgent** | Top 6 card_news ids + 컨텍스트 | 4단계 분석 (Cause / Change / Impact / Response) + confidence | LLM (gpt-4o) chain-of-thought | `POST /api/insights/generate` (생성), `GET /api/insights/latest` (조회) | backend = fixture · axis-ai 미구현 |
| 17 | **MixerAnalysisAgent** | 2~20 card_news ids + 입력 비율 (peer/industry/keyword) | 인사이트 요약 + 신호 분포 6축 레이더 + 연결 관계 | LLM (분류 + 라벨링) + 산식 (axes score) | `POST /api/mixer` (analyze), `GET /api/mixer/options`, `POST /api/mixer/{mixId}/share` | backend = fixture · axis-ai 미구현 |
| 18 | **PeerComparisonAgent** | peer_id + SK AX 컨텍스트 (피어 카드 + 자사 카드 + IR 데이터) | 차별 시사점 3~5건 + 키워드 비교 + 전략 라벨 | LLM (구조화 출력) | `GET /api/monitoring/{peerId}/strategy` (전략 분석), `GET /api/monitoring/comparison` (4사 비교) | backend = fixture · axis-ai 미구현 |
| 19 | **LinkVerificationAgent** (v1.1 신규) | 카드의 source URL | URL liveness + content diff (Levenshtein / hash) | 산식 (HTTP HEAD/GET + 해시) — LLM 없음 | `POST /api/cards/{id}/verify-link` | backend = fixture · axis-ai 미구현 |
| 20 | **BriefingComposerAgent** | 기간 (D/W/M) + card_news ids | 종합 보고서 산문 (3~5 문단) + 근거 card id list | **현재 axis-backend `BriefingService.java` 의 sector-grouped builder (LLM 없음)** · W7+ 에 LLM upgrade 옵션 | `POST /api/briefings/generate`, `GET /api/briefings/today`, `GET /api/briefings/{id}` | ✨ Java 직빌드 동작 중 (Spring @Scheduled + SES IRSA end-to-end 검증 완료 2026-05-12) |

> **NOTE**:
> - **BriefingComposerAgent 는 현재 axis-backend `BriefingService.java`** 가 sector-grouped builder 로 구현 (LLM 미사용). axis-ai 의 `delivery_graph.py` 는 dead code (호출자 없음). 일일 SES 메일 발송 (08:30 KST MON-FRI) 은 Java builder 를 그대로 사용. W7+ 에서 LLM 기반 builder 로 격상 옵션.
> - `POST /api/mixer` 는 path 가 `/api/mixer/analyze` 아님 — OpenAPI spec 직접 확인 결과.
> - `/api/monitoring/{peerId}/strategy` + `/api/monitoring/comparison` 가 PeerComparison 의 두 호출 경로. `/api/peers/{peerId}/profile` 은 별도 (Peer 메타데이터, AI 비관여).

### §3.4 SearchSupervisor — 4 agents (이미 구현 ✅, refactor 권장)

| # | Agent | 입력 | 출력 | 산식/LLM | API |
|---|---|---|---|---|---|
| 16 | **EmbedAgent** | query text | BGE-M3 Dense (1024d) + Sparse | 임베딩 only | (internal) |
| 17 | **HybridSearchAgent** | embed + filters (peer/sector/date) | top 50 articles (Dense+Sparse RRF) | Qdrant query, 산식 | `POST /api/search` |
| 18 | **RerankAgent** | top 50 + query | top 10 reranked | BGE-reranker-v2-m3 | (internal) |
| 19 | **AnswerAgent** | top 10 + query | answer + sources + SC pass/fail | LLM (SC ×3 자가 일관성) | `POST /api/gen-search` |

### §3.5 DialogueSupervisor — 3 agents (axis-ai 신규, backend endpoint 이미 존재)

frontend 우측 하단 FloatingAiChat 위젯의 대화 turn 처리. **backend `AssistantController` + `POST /api/assistant/chat` 가 이미 `ApiContractFixtureService.assistantChat()` 의 fixture 를 리턴 중** — axis-ai 위임만 신규.

| # | Agent | 입력 | 출력 | 산식/LLM | API endpoint |
|---|---|---|---|---|---|
| 20 | **IntentRouterAgent** | user msg + 대화 history (session_id) | intent (search/insight/action/smalltalk) + 추출 entity (peer/sector/date) | LLM (gpt-4o-mini, zero-shot classification) | `POST /api/assistant/chat` (single endpoint — frontend 와 BE 가 이 path 사용) |
| 21 | **ConversationAgent** | intent + entity + slots + history | 대화 메모리 업데이트 + sub-agent 호출 (Search/Analysis) + 응답 텍스트 | LLM (gpt-4o-mini, orchestration) | (internal) |
| **재사용** | HybridSearchAgent + AnswerAgent | — | 검색 결과 + answer + sources | — | (internal) |

> **NOTE**:
> - 실제 endpoint path 는 `POST /api/assistant/chat` (frontend `FloatingAiChat.tsx` → axios POST + Java `AssistantController` 기 spec). 이전 design 의 `POST /api/chat/turn` 은 부정확.
> - `chat_sessions` 테이블 신규 필요 (V13) — session_id 별 history 보존.
> - LLM context window 관리: 마지막 N turn (10개) 만 prompt 에 포함 + 그 이상은 요약하여 압축.

### §3.6 DeliverySupervisor — 1 agent (간소화)

기존 spec 의 CardSelector + Briefing + Email 3-agent 구조는 BE Java 직빌드로 단순화됨. W7+ 에 LLM 기반 보강 가능.

| # | Agent | 입력 | 출력 | 산식/LLM | 트리거 |
|---|---|---|---|---|---|
| 22 | **(BE 직빌드 — `BriefingService.java`)** | 오늘 card_news + recipients | sector-grouped HTML/text | 산식 (Java) | @Scheduled 08:30 KST |
| **재사용** | (BE) SesMailService — AWS SES V2 SDK + IRSA | — | messageId | — | (BE) |

> **OPTIMIZATION**: 별도 CardSelectorAgent / EmailAgent 분리 안 함. Java 직빌드가 동작 중 + LLM 비용 0 + 데이터 변환 없음.

### §3.7 WeakSignalSupervisor — 3 agents (W7+, 🔴 — 재구축)

선행지표 감지. 주 1회 (월 09:00 KST) 실행. **`axis-ai/src/agents/_deprecated/weak_signal_agent.py` 가 한 번 만들어졌다 폐기됨** — v1 구현 재활용 + 분리 가능.

| # | Agent | 입력 | 출력 | 산식/LLM | 비고 |
|---|---|---|---|---|---|
| 23 | **PatternDetectAgent** (재구축) | 채용공고 + 특허 + MOU 공시 (90일) | 패턴 매칭 (급증 / 신규 출현 / 부서 집중 / 직급 변동) | 산식 (이동평균 + 임계값) | LLM 없음 · 구 `_deprecated/weak_signal_agent.py` 의 일부 로직 재활용 |
| 24 | **AnomalyDetectionAgent** (신규) | 발표 톤/방향 시계열 | 이상치 score + 해석 | 산식 (z-score) + LLM (mini, 해석 생성) | 완전 신규 |
| **(cross)** | **AlertRoutingAgent** (신규, frontend Alert Rules 와 연동) | 감지된 signal + `/api/alerts/rules` 의 사용자 정의 임계값 | 매칭 사용자 list + alert payload | 산식 (rule matching) | `alerts/rules` 의 rule engine |
| **재사용** | (BE) SesMailService | — | alert email | — | — |

> **NOTE**:
> - v1 `_deprecated/weak_signal_agent.py` (8 issue_card refs · classification_agent 와 연동되던 ver) 는 폐기 처리. W7+ 재구축 시 패턴 매칭 부분 재활용 가능.
> - **AlertRoutingAgent** — frontend AlertsView 의 Alert Rule 설정 (`/api/alerts/rules`) 과 연결. 사용자가 정의한 keyword/peer/threshold 조건에 부합하는 weak signal 만 알림 발송. (지금은 missing — design 추가)
> - Weak signal 자체의 frontend 표시 endpoint (예: `GET /api/weak-signals`) 가 spec 에 없음 — W7+ 에 신규 추가 필요.

### §3.8 Cross-cutting Agents — 4 helpers (모든 supervisor 에 주입)

직접 노드 등록 없이 utility/middleware 로 동작.

| Agent | 책임 | 호출 시점 |
|---|---|---|
| **ConfidenceScoreAgent** | AI 출력 마다 confidence 0~1 계산 (trust_score + exposure_score + SC pass 등 가중) | 모든 LLM 생성 직후 |
| **ProvenanceTrackerAgent** | evidence_chain.provenance 자동 부착 (llm_model, prompt_version, raw_article_ids, run_at, git_sha) | 모든 LLM 호출 wrap |
| **TokenBudgetAgent** | 일일 LLM 비용 추적 + 임계값 초과 시 회로 차단 | 모든 LLM 호출 전 |
| **AuditLogAgent** | 모든 admin/user 액션을 pipeline_logs 또는 audit_logs 로 persist | 모든 supervisor entry |

### §3.9 Specialized Parser / Quality Agents — 7 agents (Ingestion sub-agents, 실 코드)

`axis-ai/src/agents/*.py` 에 별도 파일로 존재하는 sub-agent 들. 직접 LangGraph 노드는 아니고 Ingestion 노드들 (특히 `crawl`, `card_news`, `evidence`) 내부에서 호출됨. **v1 카탈로그 누락분 보강**.

| # | Agent | 호출 위치 | 입력 | 출력 | 산식/LLM |
|---|---|---|---|---|---|
| 25 | **ParserAgent** (`parser_agent.py`) | `crawl` 노드 내부 | raw HTML/PDF/JSON | 정규화된 text + sections | 산식 (BeautifulSoup + Playwright) |
| 26 | **ParserQualityAgent** (`parser_quality_agent.py`) | `crawl` 노드 직후 | parsed content | quality score (200자 미만 / 인코딩 깨짐 / 광고성 = SKIPPED_QUALITY) | 산식 (length + 한글 비율 + 광고 키워드) |
| 27 | **DartParserAgent** (`dart_parser_agent.py`) | DART Track B 크롤 | DART HTML | 표 마커 (`[표] ... [/표]`) + metadata (contains_tables, table_count) | 산식 (HTML table 파싱) — 본문 raw_articles.content + jsonb metadata |
| 28 | **IRParserAgent** (`ir_parser_agent.py`) | EvidenceAgent · `evidence` 노드 sub | IR PDF (네이버 금융 리서치 등) | PyMuPDF 텍스트 + 페이지 매핑 + 표/이미지 후보 | 산식 (PyMuPDF) — financial_refs 의 ir_page 필드 채움 |
| 29 | **NewsSummaryAgent** (`news_summary_agent.py`, class: `PeerNewsSummaryAgent`) | `card_news` 노드 sub | 클러스터 article ids + rep | 사실 요약 (is_valid_summary 플래그 포함) | LLM (gpt-4o-mini) |
| 30 | **NewsAnalysisAgent** (`news_analysis_agent.py`, class: `PeerNewsAnalysisAgent`) | `card_news` 노드 sub | summary + classification + cluster metadata | 분석 (가설 / 영향도 평가) → CardNewsAgent display 결과의 일부 | LLM (gpt-4o-mini) |
| 31 | **RelevanceAgent** (`relevance_agent.py`) | `preprocess_route` 노드 | raw_articles | relevance_label (relevant/irrelevant/edge) + relevance_score + relevance_reason | LLM (mini, zero-shot) |

> **NOTE**:
> - `axis-ai/src/agents/sector_keywords.py` 는 agent 가 아니라 키워드 사전 (ClassificationAgent 가 import). 카탈로그 제외.
> - `card_news_agent.py` (frontend display dict 생성기) 는 §3.1 IssueCardAgent 와 별개 — 본 카탈로그 #5 의 `CardNewsAgent (class)` 는 IssueCardAgent class 를 가리키며, `card_news_agent.py` 는 axis-ai 의 `/api/cards*` 응답 빌더용 (BE 의 frontend-compat layer).
> - 본 7 agents 는 Ingestion sub-agent 라 별도 supervisor 배정 불요. §3.1 IngestionSupervisor 의 노드 내부에서 호출.

---

## §4. 화면별 데이터 흐름

각 frontend view 가 호출하는 API + agent 활성화 순서.

### 4.1 Home Dashboard (`GET /api/dashboard/summary` + `/api/cards/today`)

```text
Home 로딩
  ├─ GET /api/cards/today
  │     → BE (CardNewsService.getTodayCards) → DB SELECT card_news WHERE created_at >= today
  │     → return [CardNewsResponse...]
  │     (Ingestion + Enrichment 가 미리 만들어둔 결과만 조회)
  │
  ├─ GET /api/dashboard/summary
  │     → BE proxy → axis-ai /dashboard/summary
  │     → TopInsightSelectorAgent (cached) + TrendAggregatorAgent + KeywordExtractionAgent (cached)
  │     → return { trends, keywordSeries, stockPoints, topInsightId }
  │
  └─ (조건부) FinancialLinkerAgent — DART radar 선택 시
```

### 4.2 Briefings (`GET /briefings`)

```text
Briefings 페이지 로딩 (Daily/Weekly/Monthly 선택)
  └─ GET /api/briefings?period=daily&date=2026-05-12
        → BE BriefingService.generateAndSend() 와 유사한 builder
        → 또는 BriefingComposerAgent (LLM mode) 호출
        → return { executive_summary, body_paragraphs[], source_card_ids[] }
```

### 4.3 Insight Result (`POST /api/insights/generate`)

```text
User: "Top 6 카드로 인사이트 만들어줘" 버튼
  └─ POST /api/insights/generate { card_ids: [...] }
        → AnalysisSupervisor.InsightCascadeAgent
        → LLM (Cause → Change → Impact → Response, 4-step CoT)
        → ConfidenceScoreAgent → confidence
        → ProvenanceTrackerAgent → evidence_chain.provenance
        → return { cause[], change[], impact[], response[], confidence, sources[] }
```

### 4.4 Peer+ / Monitoring

```text
User: Peer 칩 클릭 (samsung_sds → lg_cns)
  ├─ GET /api/monitoring/lg_cns                      → 기본 메타 + 카드 카운트
  ├─ GET /api/monitoring/lg_cns/cards                → Peer 카드 목록 (filter)
  ├─ GET /api/monitoring/lg_cns/financials          → FinancialLinkerAgent (IR pack)
  ├─ GET /api/monitoring/lg_cns/strategy            → PeerComparisonAgent (전략 비교)
  ├─ (신규 spec) GET /api/peers/lg_cns/wordcloud    → PeerWordCloudAgent (cached)
  └─ GET /api/monitoring/comparison                 → 4사 비교 표 (cross-peer)
```

### 4.5 Card News Workspace (`GET /api/cards`)

```text
User: 필터 변경 (peer=samsung_sds & sector=ax & keyword="AI")
  └─ GET /api/cards?peer=samsung_sds&sector=ax&q=AI
        → BE CardNewsService.getAll (JPA filter)
        → 또는 q 가 자연어면 HybridSearchAgent 위임 (BGE-M3 + RRF)
        → return [CardNewsResponse...]
```

### 4.6 Mixer (`POST /api/mixer`)

```text
User: Mixer 페이지 진입
  └─ GET /api/mixer/options                              → 후보 카드 리스트 (북마크 + 최근 + 추천)

User: 북마크 카드 5개 선택 + "Generate" 클릭
  └─ POST /api/mixer { card_ids: [5개], ratios: {peer/industry/keyword} }
        → MixerAnalysisAgent
        ├─ 산식: 입력 비율 도넛 + 6축 radar score
        ├─ LLM: 반복 신호 추출 (cross-card 공통 주제)
        ├─ LLM: 연결 관계 (카드 간 인과/유사 라벨링)
        ├─ LLM: 종합 인사이트 1문장 + bullet 3개
        └─ return { mix_id, insight, radar_axes[], connections[], confidence }

User: 결과 공유 (URL 토큰 발급)
  └─ POST /api/mixer/{mix_id}/share                      → 공개 share URL
```

### 4.7 Keyword Graph (`GET /api/keyword-graph`)

```text
User: KeywordGraph 페이지 로딩
  └─ GET /api/keyword-graph?companies=[...]&sectors=[...]
        → KeywordGraphBuilderAgent (cached, nightly 02:30 빌드)
        → return { nodes: [{id, label, size, color}], edges: [{src, dst, weight}], categories[] }
```

### 4.8 Floating AI Chat (`POST /api/assistant/chat`)

```text
User: "삼성SDS 의 AX 최근 동향 요약해줘" 입력 (FloatingAiChat 위젯)
  └─ POST /api/assistant/chat { message, session_id, history? }
        → DialogueSupervisor (axis-ai)
        ├─ IntentRouterAgent (LLM mini) → intent="summary", entity={peer:"samsung_sds", topic:"AX", period:"recent"}
        ├─ ConversationAgent (LLM mini) → 메모리 update (chat_sessions 테이블)
        ├─ (위임) HybridSearchAgent + AnswerAgent → 검색 + 답변 (gpt-4o)
        └─ return { reply, sources[], confidence, follow_up_suggestions[] }
```

> 현재 backend `AssistantController` 가 이 endpoint 의 fixture 를 리턴 — 위 axis-ai 위임은 P8 우선순위.

### 4.9 일일 브리핑 (Spring @Scheduled 08:30 KST MON-FRI)

```text
Spring Scheduler 발화
  └─ SchedulerConfig.sendDailyBriefing()
        → BriefingService.generateAndSend()
        ├─ CardNewsService.getTodayCards()    — DB SELECT card_news WHERE created_at >= today
        ├─ resolveRecipients()                 — env BRIEFING_RECIPIENTS
        ├─ buildBriefingHtml() + buildBriefingText()  — sector-grouped builder
        └─ SesMailService.sendBriefing()       — AWS SES V2 SDK (IRSA)
              → SES → 6명 inbox
```

### 4.10 약신호 alert (W7+, 월 09:00 KST)

```text
Spring Scheduler 발화 (월요일)
  └─ POST axis-ai /weak-signal/run
        → WeakSignalSupervisor
        ├─ PatternDetectAgent (산식)
        ├─ AnomalyDetectionAgent (산식 + LLM 해석)
        └─ (재사용) SesMailService — alert email
```

---

## §5. 재사용 + 최적화 패턴

### 5.1 Cross-supervisor agent 공유

```text
HybridSearchAgent  ←─┬─ SearchSupervisor
                     └─ DialogueSupervisor (재사용)

ConfidenceScoreAgent ←─ 모든 LLM 출력 wrap (cross-cutting)

FinancialLinkerAgent ←─┬─ Ingestion (EvidenceAgent 가 호출)
                       └─ Home dashboard (DART radar)
                       └─ Peer+ (IR pack)

BriefingComposerAgent ←─┬─ AnalysisSupervisor (on-demand 보고서)
                        └─ DeliverySupervisor (이메일 본문) — 단 현재는 BE Java 직빌드

KeywordExtractionAgent ←─┬─ EnrichmentSupervisor (전체 dashboard)
                         └─ PeerWordCloudAgent (Peer 필터)
                         └─ KeywordGraphBuilderAgent (그래프 입력)
```

### 5.2 산식 우선, LLM 최후

| 책임 | 1st choice | LLM 사용 시점 |
|---|---|---|
| exposure_score | 결정적 산식 (4-component weighted) | — |
| credibility | 출처 화이트리스트 휴리스틱 | — |
| dedup | BGE-M3 임베딩 유사도 | — |
| event_type / sector | 키워드 매칭 → LLM fallback | 매칭 실패 시 |
| card 요약 | — | LLM 필수 |
| 시사점 (implication) | — | LLM 필수 |
| 인사이트 4단계 분석 | — | LLM 필수 (CoT) |
| 키워드 추출 | TF-IDF | — |
| 키워드 카테고리 (기술/사업/MOU) | 키워드 사전 → LLM fallback | 사전 미스 시 |

**이유**: LLM 호출 = 비용 + latency + 비결정성. 결정적 산식이 가능하면 그쪽이 항상 더 좋음 (재현 + 디버깅 + 테스트).

### 5.3 Caching 전략

| 데이터 | 캐시 위치 | TTL |
|---|---|---|
| KeywordExtraction 결과 (전체) | DB `enrichment_cache` 테이블 | 6시간 (nightly 갱신) |
| KeywordGraph 빌드 결과 | DB `enrichment_cache` | 24시간 |
| PeerWordCloud | DB `enrichment_cache` per peer | 24시간 |
| InsightCascade 결과 | DB `analysis_cache` keyed by card_id set hash | 7일 |
| Mixer 분석 결과 | DB `analysis_cache` keyed by card_id set hash | 7일 |
| Search embedding | Qdrant 자체 (영구) | — |
| Dashboard summary | Redis (옵션) | 5분 |

> **NOTE**: `enrichment_cache` / `analysis_cache` 테이블은 신규. V11+ migration 필요.

### 5.4 LLM 모델 선택

| Use case | 모델 | 이유 |
|---|---|---|
| classify (event_type / sector) | gpt-4o-mini | 빠름 + 분류는 mini 로 충분 |
| card 요약 (3줄) | gpt-4o-mini | 짧은 출력 |
| implication (시사점) | gpt-4o | 품질 중요 |
| Insight Cascade (4단계 CoT) | gpt-4o | reasoning 깊이 |
| Mixer 신호 추출 | gpt-4o | 복합 분석 |
| Peer 비교 | gpt-4o | 구조화 출력 + 도메인 |
| Dialogue (chat) | gpt-4o-mini | 빠른 turn 응답 |
| Intent classification | gpt-4o-mini | zero-shot 분류 |

---

## §6. State 모델 — 무엇이 어디 저장되는지

### 6.1 DB 영속 (Postgres in-cluster)

| 테이블 | Producer | Consumer |
|---|---|---|
| `raw_articles` | CrawlerAgent | DedupAgent, FinancialLinkerAgent, EmbedAgent |
| `card_news` (V9 이후) | CardNewsAgent | Frontend, BriefingComposerAgent, InsightCascadeAgent, MixerAnalysisAgent |
| `evidence_chain` | EvidenceAgent | 모든 분석 agent (provenance trace) |
| `peer_companies` | manual seed | ClassificationAgent, PeerComparisonAgent |
| `peer_financials` | IRParserAgent (DART) | FinancialLinkerAgent |
| `briefing_history` | (BE) BriefingService | Frontend 브리핑 페이지 |
| `pipeline_logs` | 모든 agent (`_logged_step`) | Admin 대시보드, AuditLogAgent |
| **`enrichment_cache`** (신규 V11) | Enrichment agents | Frontend dashboard |
| **`analysis_cache`** (신규 V12) | Analysis agents | Frontend on-demand 화면 |
| **`chat_sessions`** (신규 V13) | DialogueSupervisor | Frontend chat widget |

### 6.2 Qdrant 컬렉션 (in-cluster)

| 컬렉션 | TTL | payload |
|---|---|---|
| `axis_main` | 3개월 | rdb_id, peer_id, event_type, sector, exposure_score, cluster_id, title, summary, card_news_id (legacy column, V10 후 → card_news_id) |
| `axis_history` | 12개월 | 동일 + 시그널 히스토리 분석 전용 |

### 6.3 Provenance 정형 (모든 AI 출력)

```python
provenance = {
    "raw_article_ids": [int, ...],   # 원천 추적
    "llm_model": "gpt-4o" | "gpt-4o-mini",
    "prompt_version": "v3.0",
    "evidence_version": "v3.0",
    "run_at": "2026-05-12T08:30:00Z",
    "git_sha": "1d1a054",            # 코드 버전
    "agent": "InsightCascadeAgent",
    "confidence": 0.78,
}
```

---

## §7. 비용 예측 (LLM token, GPT-4o 기준)

### 일일 비용 (정상 가동)

| Agent | 호출수 | 토큰/호출 (in+out) | 일일 비용 |
|---|---|---|---|
| ClassificationAgent (mini) | ~80 | ~1,500 | ₩300 |
| RelevanceAgent (mini, preprocess_route) | ~500 (crawled 전체) | ~500 | ₩100 |
| IssueCardAgent / NewsSummary / NewsAnalysis (mini, card_news 노드) | ~80 (cluster 단위) | ~2,000 | ₩400 |
| EvidenceAgent (mini, sub) | ~80 | ~1,000 | ₩200 |
| TopInsightSelector / Trend / KeywordExtraction / KeywordGraphBuilder / MonitoringOverview (산식 only) | — | — | ₩0 |
| PeerWordCloudAgent (mini, category 라벨링 only) | ~4 (peer 별) | ~500 | ₩20 |
| SearchSuggestAgent (산식 + 옵션 embed) | — | — | ₩0 |
| LinkVerificationAgent (산식, HTTP only) | — | — | ₩0 |
| InsightCascadeAgent (gpt-4o, on-demand) | ~10 (가정) | ~5,000 | ₩650 |
| MixerAnalysisAgent (gpt-4o, on-demand) | ~5 | ~5,000 | ₩325 |
| PeerComparisonAgent (gpt-4o) | ~4 | ~3,000 | ₩200 |
| AnswerAgent (gpt-4o, SC ×3) | ~20 | ~5,000 | ₩400 |
| IntentRouterAgent (mini) | ~50 (chat turn) | ~500 | ₩30 |
| ConversationAgent (mini) | ~50 | ~1,500 | ₩200 |
| WeakSignal (AnomalyDetection 의 LLM 해석 부분, 주 1회) | ~5 (가정) | ~2,000 | ₩50 (주간) → 일평균 ₩7 |
| AlertRoutingAgent (산식) | — | — | ₩0 |
| **합계** | | | **~₩2,832 / 일** |

**목표**: ≤ ₩5,000 / 일. 여유 약 43% — 사용자 증가 / on-demand 호출 증가 흡수 가능.

> v1.1 변경: RelevanceAgent 누락 추가 (~₩100/일), 신규 4 agents (MonitoringOverview/SearchSuggest/LinkVerification/AlertRouting) 모두 산식 only 라 비용 0, WeakSignal 의 LLM 해석 부분 추가 (~₩7/일). 총 +₩107 (₩2,725 → ₩2,832).

### TokenBudgetAgent 임계값

```python
LIMITS = {
    "daily_total_won": 5000,
    "per_user_daily_won": 500,  # 일반 사용자
    "per_admin_daily_won": 2000,  # 관리자
    "per_request_max_tokens": 8000,
}
```

초과 시 `gpt-4o → gpt-4o-mini` fallback, 그래도 초과면 503 + admin alert.

---

## §8. 구현 우선순위

> **공통 패턴**: 모든 P6~P8 작업은 **"기존 backend fixture endpoint 의 응답을 axis-ai 위임 호출로 교체"** 형태 (endpoint 신규 spec 거의 불요).

### P5 (현재 W5-6 완료 영역)

- ✅ IngestionSupervisor 전 8 nodes (crawl/credibility/preprocess_route/dedup/classify/card_news/evidence/vector_index)
- ✅ Specialized parsers (DartParser/IRParser/Parser/ParserQuality/Relevance/NewsSummary/NewsAnalysis)
- ✅ ClassificationAgent + IssueCardAgent + EvidenceAgent + FinancialLinkerAgent + DedupAgent + CredibilityAgent
- ✅ SearchSupervisor 골격 4 agents (Embed/HybridSearch/Rerank/Answer — stub 상태, 실 LLM 호출은 placeholder)
- ✅ Delivery (BE Java 직빌드 + SES IRSA, 2026-05-12 end-to-end 검증 완료)
- ✅ axis-backend 22 controllers + openapi 71 endpoints (fixture-only)
- ✅ DB rename `issue_cards → card_news` (V9 + backward-compat VIEW, 2026-05-12 적용)

### P6 (다음 1~2주 — 발표 직전, Enrichment 중심)

목표: Home / Peer+ / KeywordGraph 뷰의 fixture 응답을 실 데이터로 교체.

1. **TopInsightSelectorAgent** — `GET /api/dashboard/summary` 의 `topInsightId` 필드 axis-ai 위임
2. **TrendAggregatorAgent** — `GET /api/dashboard/summary` 의 `trends` 필드 (산식 only)
3. **KeywordExtractionAgent** — `GET /api/dashboard/summary` 의 `keywordSeries` 필드 (TF-IDF 산식)
4. **KeywordGraphBuilderAgent** — `GET /api/keyword-graph` 의 fixture → 실 그래프 (cached nightly)
5. **PeerWordCloudAgent** — `GET /api/peers/{peerId}/wordcloud` (신규 spec 1건) 또는 `/strategy` 응답에 통합
6. **SearchSuggestAgent** — `GET /api/search/suggestions` fixture → 실 추천
7. **MonitoringOverviewAgent** — `GET /api/monitoring/overview` + `/comparison` 의 fixture → 실 집계 데이터
8. `enrichment_cache` 테이블 신규 (V11 migration)

### P7 (W7 — Analysis 위임)

목표: Insight / Mixer / Peer strategy 의 fixture → 실 LLM 분석.

1. **InsightCascadeAgent** — `POST /api/insights/generate` + `GET /api/insights/latest` 의 fixture → axis-ai 위임
2. **MixerAnalysisAgent** — `POST /api/mixer` + `GET /api/mixer/options` 의 fixture → axis-ai 위임
3. **PeerComparisonAgent** — `GET /api/monitoring/{peerId}/strategy` + `/comparison` 의 fixture → axis-ai 위임
4. **LinkVerificationAgent** — `POST /api/cards/{id}/verify-link` 의 fixture → 실 HTTP check + diff 감지
5. **ConfidenceScoreAgent** (cross-cutting) — 모든 응답에 confidence 필드 강제 부착
6. `analysis_cache` 테이블 (V12)

### P8 (W8 — 약신호 + Chat 위젯)

목표: FloatingAiChat 위젯 + WeakSignal 알림 활성화.

1. **WeakSignalSupervisor 재구축** — `_deprecated/weak_signal_agent.py` 의 패턴 매칭 로직 활용
   - PatternDetectAgent
   - AnomalyDetectionAgent
   - **AlertRoutingAgent** — `/api/alerts/rules` 의 사용자 정의 임계값과 매칭
2. **DialogueSupervisor** — `POST /api/assistant/chat` 의 fixture → axis-ai 위임
   - IntentRouterAgent
   - ConversationAgent
   - HybridSearchAgent + AnswerAgent 재사용
3. **TokenBudgetAgent + AuditLogAgent** (cross-cutting, Admin `/api/admin/usage` + `/api/admin/audit-logs` 연동)
4. `chat_sessions` 테이블 (V13)
5. Weak signal 결과 노출 endpoint 신규 spec (예: `GET /api/weak-signals`)

### P9 (W9 — 정리)

1. **V10 cleanup migration**: `evidence_chain.issue_card_id` / `article_images.issue_card_id` 컬럼 rename + V9 의 VIEW drop
2. `axis-cron-delivery` CronJob 삭제 (Spring `@Scheduled` 와 중복, 매일 500 발생)
3. `axis-cron-ingestion-a/b/c` CronJob 삭제 (Spring `@Scheduled.triggerIngestionPipeline` 와 중복 — LLM 비용 2배 위험)
4. `axis-ai/src/pipeline/delivery_graph.py` 정리 (dead code 삭제 또는 W7+ LLM 빌더로 활성)
5. ADR 작성:
   - ADR-0009 Supervisor 분리 + cross-supervisor 재사용 패턴
   - ADR-0010 Cross-cutting agents (Confidence/Provenance/TokenBudget/Audit)
   - ADR-0011 결정적 산식 우선 정책 (exposure_score · credibility · keyword extraction)
   - ADR-0012 Caching 계층 (enrichment_cache + analysis_cache 키 hashing)
   - ADR-0013 Dialogue session 모델 (chat_sessions + LLM context window 관리)

---

## §9. ADR 후보

향후 작성 권장:

- **ADR-0009 Supervisor 분리 원칙 (확장판)**: trigger 주기 + 소비자 다름 = 분리. 같은 책임 공유는 cross-supervisor 재사용 (이 문서가 시드)
- **ADR-0010 Cross-cutting agents**: Confidence/Provenance/TokenBudget/AuditLog 를 wrapper/middleware 로 주입 (구체적 구현 패턴)
- **ADR-0011 결정적 산식 우선 정책**: exposure_score 처럼 LLM 대신 산식 가능한 영역은 산식 사용 강제
- **ADR-0012 Caching 계층**: enrichment_cache + analysis_cache 의 키 hashing + invalidation 정책
- **ADR-0013 Dialogue session 모델**: chat 세션 상태 보존 + LLM context window 관리

---

## §10. Known limitations / Out of scope

### Out of scope (현재 design)

- **개인화 학습** — 사용자별 관심 키워드 학습. v2 후순위. 영향: 모든 사용자가 동일 dashboard.
- **Synthetic data** — 가상 시나리오 보고서. business value 불명확.
- **다국어** — 영문 보고서. 현재 KR only.
- **실시간 stream** — 모든 ingestion 은 batch (1시간). webhook 미지원.

### Known limitations

- **InsightCascade 의 confidence < 0.6** 일 경우 UI 경고만 표시. 자동 재시도 안 함 — 사용자가 다른 카드 선택해서 재호출 필요.
- **Mixer 카드 ≥ 20 건** 일 때 LLM context 가 부족. 현재 frontend 가 ≤ 20 으로 제한. ≥ 20 지원하려면 chunking 필요.
- **DialogueSupervisor 의 multi-turn memory** 는 단일 session 내부만. 사용자 간 컨텍스트 공유 X.
- **WeakSignalSupervisor 는 W7+** — 발표 전 데모 시점에는 placeholder.
- **TokenBudget 초과 시 fallback** 은 자동이지만 사용자 visibility 0. 향후 admin dashboard 에 visualization 필요.

### 데이터 의존성

- card_news 가 0 건이면 모든 downstream agent 가 동작 안 함. **데이터 확보가 P5 의 critical path**.
- Peer financials 가 없으면 FinancialLinkerAgent skip → Home DART radar / Peer+ IR pack 빈 상태.
- BGE-M3 모델 다운로드 실패 시 EmbedAgent + DedupAgent 전부 fail. Pod startup 시 캐시 필요.

### Backend fixture 의존성 (현재 상태, 2026-05-13)

- 22개 controller 모두 `ApiContractFixtureService` 의 fixture 데이터 리턴 중. axis-ai 위임 호출 미연결.
- frontend 가 정상 동작하는 이유 = fixture 의 contract 가 정합. 실 데이터 교체 시에도 응답 schema 보존 필수.
- P6~P8 작업은 **응답 schema 그대로 유지하면서 source 만 fixture → axis-ai 위임으로 교체** — 즉 controller 의 method body 만 수정, frontend 무수정.

### Bookmark / Notification / Share feature

- 현재 BE-only 처리 (DB CRUD). AI 비관여.
- 장기 후보: 북마크 history 가 사용자 선호도 학습 input — InsightCascadeAgent / MixerAnalysisAgent 의 추천 가중치 + AlertRoutingAgent 의 rule 자동 제안에 사용 가능. v2.

### Link Verification (`POST /api/cards/{id}/verify-link`)

- 현재 fixture. 실제 구현 시 HTTP HEAD/GET + content diff (Levenshtein 또는 hash) 가 필요.
- LLM 없음 (전부 산식). **LinkVerificationAgent** (P7) 의 단일 책임.

---

## 부록 A. Agent 인덱스 (31 agents + 4 cross-cutting)

> **상태 범례**: ✅ axis-ai 실 구현 + 동작 / 🟡 backend endpoint+fixture 존재, axis-ai 위임 미연결 / 🔴 신규 (axis-ai + backend 둘 다)

### Core agents (IngestionSupervisor 8 nodes)

| # | Agent | LangGraph node | 상태 |
|---|---|---|---|
| 1 | **CrawlerAgent** (`crawler_agent.py`) | `crawl` | ✅ |
| 2 | **CredibilityAgent** (`credibility_agent.py`) | `credibility` | ✅ |
| 3 | **RelevanceAgent** (`relevance_agent.py`) | `preprocess_route` | ✅ |
| 4 | **DedupAgent** (`dedup_agent.py`) | `dedup` | ✅ |
| 5 | **ClassificationAgent** (`classification_agent.py`) | `classify` | ✅ |
| 6 | **IssueCardAgent** (`issue_card_agent.py`, class 명 유지 / DB 는 card_news) | `card_news` | ✅ |
| 7 | **EvidenceAgent** (`evidence_agent.py`) | `evidence` | ✅ |
| 8 | **EmbedAgent** (`rag/embedder.py` + `rag/vector_index.py`) | `vector_index` | ✅ |

### Specialized sub-agents (Ingestion 내부 호출, §3.9)

| # | Agent | 호출 위치 | 상태 |
|---|---|---|---|
| 25 | **ParserAgent** | `crawl` sub | ✅ |
| 26 | **ParserQualityAgent** | `crawl` sub | ✅ |
| 27 | **DartParserAgent** | DART Track B 크롤 | ✅ |
| 28 | **IRParserAgent** | `evidence` sub (IR PDF) | ✅ |
| 29 | **NewsSummaryAgent** (`PeerNewsSummaryAgent`) | `card_news` sub | ✅ |
| 30 | **NewsAnalysisAgent** (`PeerNewsAnalysisAgent`) | `card_news` sub | ✅ |
| 31 | **FinancialLinkerAgent** | `evidence` sub + Enrichment | ✅ |

### Enrichment / Analysis / Search / Dialogue / WeakSignal

| # | Agent | Supervisor | 상태 |
|---|---|---|---|
| 9 | **KeywordExtractionAgent** | Enrichment | 🟡 P6 |
| 10 | **KeywordGraphBuilderAgent** | Enrichment | 🟡 P6 |
| 11 | **PeerWordCloudAgent** | Enrichment | 🟡 P6 |
| 12 | **TopInsightSelectorAgent** | Enrichment | 🟡 P6 (산식) |
| 13 | **TrendAggregatorAgent** | Enrichment | 🟡 P6 (산식) |
| 14 | **MonitoringOverviewAgent** | Enrichment | 🟡 P6 |
| 15 | **SearchSuggestAgent** | Enrichment | 🟡 P6 |
| 16 | **InsightCascadeAgent** | Analysis | 🟡 P7 (backend endpoint 존재) |
| 17 | **MixerAnalysisAgent** | Analysis | 🟡 P7 (backend endpoint 존재) |
| 18 | **PeerComparisonAgent** | Analysis | 🟡 P7 (backend endpoint 존재) |
| 19 | **LinkVerificationAgent** | Analysis | 🟡 P7 (backend endpoint 존재) |
| 20 | **BriefingComposerAgent** (현재 BE Java 직빌드) | Analysis / Delivery (재사용) | ✅ Java |
| 21 | **HybridSearchAgent** (`rag/hybrid_search.py`) | Search / Dialogue (재사용) | ✅ (stub) |
| 22 | **RerankAgent** (`rag/reranker.py`) | Search | ✅ (stub) |
| 23 | **AnswerAgent** (`/gen-search` handler) | Search / Dialogue (재사용) | ✅ (stub) |
| 24 | **IntentRouterAgent** | Dialogue | 🟡 P8 (backend endpoint 존재) |
| 32 | **ConversationAgent** | Dialogue | 🟡 P8 (backend endpoint 존재) |
| 33 | **PatternDetectAgent** (재구축) | WeakSignal | 🔴 W7+ |
| 34 | **AnomalyDetectionAgent** | WeakSignal | 🔴 W7+ |
| 35 | **AlertRoutingAgent** | WeakSignal (cross-frontend) | 🔴 W7+ |

### Cross-cutting (별도, 모든 supervisor 에 주입)

- **ConfidenceScoreAgent** — 모든 LLM 출력 직후 confidence 0~1 산정
- **ProvenanceTrackerAgent** — evidence_chain.provenance 자동 부착
- **TokenBudgetAgent** — 일일 LLM 비용 추적 + 회로 차단
- **AuditLogAgent** — admin/user 액션 → pipeline_logs / audit_logs

**합계**: 35 agents + 4 cross-cutting = 39 logical agent.

---

## 부록 B. Frontend view → API → agent 빠른 참조 (실 path 정정)

| Frontend view | API endpoint (실 path) | Agent (entry) |
|---|---|---|
| Home (HomeCardNewsView) | `GET /api/dashboard/summary` | TopInsightSelector + TrendAggregator + KeywordExtraction |
| Home | `GET /api/cards/today` | (DB SELECT only) |
| Briefings (BriefingsView) | `GET /api/briefings`, `/briefings/today`, `/briefings/summary`, `/briefings/{id}`, `/briefings/{id}/status`, `/briefings/cards/search`, `POST /briefings/generate`, `POST /briefings/{id}/share` | BriefingComposer (Java 직빌드) |
| Insight (Briefings 내) | `POST /api/insights/generate`, `GET /api/insights/latest` | InsightCascade |
| Peer+ / Monitoring (MonitoringView) | `GET /api/monitoring`, `/overview`, `/comparison`, `/{peerId}`, `/{peerId}/cards`, `/{peerId}/financials`, `/{peerId}/strategy`, `/cards/search` | MonitoringOverview + FinancialLinker + PeerComparison |
| Peer+ (워드클라우드, 신규) | (신규 spec) `GET /api/peers/{peerId}/wordcloud` | PeerWordCloud |
| Peer 메타 | `GET /api/peers`, `/peers/{peerId}/profile` | (AI 비관여) |
| Issues (IssuesView) | `GET /api/cards`, `/cards/{id}` | (DB SELECT + filter) |
| Issues (자연어 검색) | `GET /api/cards?q=...`, `GET /api/search/suggestions` | HybridSearch + SearchSuggest |
| Issues (카드 액션) | `POST /api/cards/{id}/share`, `POST /api/cards/{id}/verify-link` | LinkVerification (verify) |
| Issues (북마크) | `GET/POST /api/bookmarks`, `DELETE /api/bookmarks/{cardId}` | (AI 비관여, 장기적으로 추천 input) |
| Mixer | `POST /api/mixer`, `GET /api/mixer/options`, `POST /api/mixer/{id}/share` | MixerAnalysis |
| Keyword Graph | `GET /api/keyword-graph`, `GET /api/keyword-graph/{nodeId}/cards` | KeywordGraphBuilder (cached) |
| Alerts (AlertsView) | `GET /api/alerts`, `POST /api/alerts/{id}/read`, `GET/POST /api/alerts/rules`, `PUT/DELETE /api/alerts/rules/{ruleId}` | AlertRouting (W7+, WeakSignal → 사용자 rule 매칭) |
| Floating Chat | `POST /api/assistant/chat` | IntentRouter → Conversation → (HybridSearch + Answer) |
| Search box (top) | `POST /api/search`, `GET /api/search/suggestions`, `POST /gen-search` | HybridSearch + Answer + SearchSuggest |
| Settings (SettingsView) | (SettingsController endpoints) | (AI 비관여) |
| Admin (AdminView) | `/api/admin/peers`, `/sources`, `/prompts`, `/scheduler`, `/usage`, `/usage/limits`, `/audit-logs` (12 path) | TokenBudget + AuditLog (cross-cutting) |
| Raw Articles (RawArticlesView, 내부용) | (RawArticleController endpoints) | (AI 비관여 — debug) |
| Auth | `/api/auth/login`, `/signup`, `/verify-email`, `/refresh`, `/me`, `/logout` | (AI 비관여) |
| Daily briefing email | (Spring @Scheduled 08:30 KST MON-FRI) | BriefingComposer (Java) → SesMailService |
| Hourly ingestion | (Spring @Scheduled 매시 정각) | IngestionSupervisor 8 nodes |
| Weak signal (W7+) | (월 09:00, `GET /api/weak-signals` 신규 후보) | PatternDetect + AnomalyDetection + AlertRouting |

---

**문서 유지 정책**:

- 새 frontend view 추가 시 §1 매트릭스 + §4 흐름 + 부록 B 동시 갱신
- 새 agent 추가 시 §3 카탈로그 + 부록 A 인덱스 동시 갱신
- 우선순위 변경 시 §8 갱신
- LLM 모델 변경 시 §5.4 + §7 비용 갱신

---

## §11. Changelog (v1 → v1.1, 2026-05-13)

v1 작성 직후 axis 4개 레포 (`axis-ai/src/agents/`, `axis-backend/src/main/java/.../controller/`, `axis-infra/api/openapi.yaml`, `axis-frontend/src/`) 의 실 코드와 cross-check 한 결과 발견된 14건 mismatch 정정.

### 🔴 큰 정정 (5건)

| # | v1 | v1.1 | 위치 |
|---|---|---|---|
| 1 | "24 agents 카탈로그" | **35 agents + 4 cross-cutting** — axis-ai/src/agents 에 이미 존재하지만 v1 카탈로그에 누락된 7개 (DartParser/IRParser/Parser/ParserQuality/Relevance/NewsSummary/NewsAnalysis) + Specialized §3.9 신규 + Enrichment 추가 agent (MonitoringOverview/SearchSuggest/LinkVerification/AlertRouting) | §3.1, §3.9, 부록 A |
| 2 | "모든 신규 endpoint 가 신규 spec" | **22개 backend controller + 71개 `/api/*` endpoint 가 이미 OpenAPI + fixture 구현 완료**. P6~P8 = "fixture 를 axis-ai 위임으로 교체" 형태 | §1, §8 |
| 3 | API path 다수 오류 | 정정: `POST /api/mixer` (analyze 아님), `POST /api/assistant/chat` (chat/turn 아님), `GET /api/monitoring/{peerId}/strategy` (peer/{id}/compare 아님), `GET /api/monitoring/{peerId}/financials` (peer/{id}/ir-pack 아님) | §1, §3.3, §3.5, §4, 부록 B |
| 4 | "IngestionSupervisor 6 nodes" | **8 nodes** — preprocess_route + vector_index 추가 (실 LangGraph) | §3.1 |
| 5 | "Frontend view 10개 (Explore 보고)" | App.tsx routing key **10** vs 실 `*View.tsx` 파일 **9** 두 개념 공존 명시. **MonitoringView · AlertsView · NotificationView 추가** | §1 |

### 🟡 작은 정정 (9건)

| # | 변경 |
|---|---|
| 6 | WeakSignalSupervisor "🔴 신규" → "🔴 W7+ **재구축**" (`_deprecated/weak_signal_agent.py` 존재). AlertRoutingAgent 신규 추가 |
| 7 | DialogueSupervisor "axis-backend 측 신규" → "**AssistantController + `/api/assistant/chat` 이미 fixture 존재**, axis-ai 위임만 신규" |
| 8 | Bookmark / Notification / Share / Verify-link 기능 누락 → §10 Known limitations 보강 |
| 9 | `/api/insights/latest` (GET) — 누락된 endpoint 추가 |
| 10 | `/api/search/suggestions` — SearchSuggestAgent 신규 (Enrichment) |
| 11 | `/api/alerts/rules` — AlertRoutingAgent 와 연결되는 사용자 정의 임계값 |
| 12 | `/api/monitoring/*` 7개 path — Peer+ 기능 분해 (overview/comparison/{peerId}/{peerId}/cards/financials/strategy + cards/search) |
| 13 | `/api/cards/{id}/verify-link` — LinkVerificationAgent 신규 |
| 14 | `BriefingComposerAgent` 상태 명시: BE Java 직빌드 (LLM 없음), 2026-05-12 end-to-end 검증 완료. W7+ LLM upgrade 옵션 |

### 보존된 정확한 부분 (변경 불요)

- 7 Supervisor 토폴로지 골격 (Ingestion / Enrichment / Analysis / Search / Dialogue / Delivery / WeakSignal)
- Cross-cutting 4 agents (Confidence / Provenance / TokenBudget / AuditLog)
- 결정적 산식 우선 정책 (`§5.2`)
- LLM 모델 선택 (gpt-4o-mini 우선, gpt-4o reasoning 만)
- 비용 예측 (~₩2,725/일, 목표 ≤ ₩5,000)
- Caching 전략 (3-tier)
- SES IRSA + BriefingService Java 직빌드 + STS module + zone="Asia/Seoul"

### 검증 방법론

```bash
# 1. axis-ai agent 파일 목록 검증
ls axis-ai/src/agents/*.py | grep -v "__init__\|_deprecated"

# 2. ingestion_graph 실 노드 검증
grep "graph.add_node" axis-ai/src/pipeline/ingestion_graph.py

# 3. axis-backend controller 검증
ls axis-backend/src/main/java/com/skala/axis/controller/*.java

# 4. openapi 전체 endpoint 검증
grep "^  /api/" axis-infra/api/openapi.yaml | sort -u | wc -l

# 5. Spring @Scheduled cron 검증
grep "@Scheduled" axis-backend/src/main/java/com/skala/axis/config/SchedulerConfig.java

# 6. Frontend view 파일 검증
find axis-frontend/src -name "*View.tsx"
```

### Open question (v1.2 후속)

- frontend App.tsx 의 `activeView` routing key (10) 와 실 `*View.tsx` 파일 (9) 의 1:1 매핑 명시 (어떤 file 이 어떤 routing key 의 entry component 인지)
- axis-ai 위임이 매니저 가이드 + 매니저 시연 시 어느 정도까지 필요한지 우선순위 재논의 (모든 fixture 를 axis-ai 위임으로 교체 vs 발표용 일부만)
- `delivery_graph.py` dead code 처리: 삭제 (V9 정리 PR 포함) 또는 W7+ LLM builder 로 활성?
