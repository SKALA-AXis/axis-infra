# AXIS DB 설명서

> 프론트 화면이 실제로 읽는 데이터에서 출발해 DB를 설명한다.
> DDL 기준: [`axis-infra/db/schema.sql`](../db/schema.sql) / ERD 기준: [`axis-infra/db/schema.dbml`](../db/schema.dbml)
> Flyway 기준: `axis-backend/src/main/resources/db/migration` V1..V30
> 업데이트: 2026-05-19 KST, V30 최소 스키마 기준

---

## 0. 현재 스냅샷

V30 목표 public schema 기준:

| 항목 | 값 | 비고 |
|---|---:|---|
| 앱 테이블 | 12 | `flyway_schema_history` 제외 |
| DB 관리 테이블 | 1 | `flyway_schema_history` |
| View | 2 | `issue_cards`, `raw_article_metadata_unified` |
| 최신 Flyway | V30 | `collapse legacy tables into minimal product schema` |
| 보존 archive | `legacy_records` | V30에서 제거되는 레거시 테이블 모든 row를 원본 payload로 보존 |

V30은 단순 drop migration이 아니다. 제거 대상 테이블을 먼저 `legacy_records`에 row 단위로 복사하고, 화면에서 계속 필요한 값은 소유 테이블의 배열/JSONB 컬럼으로 흡수한 뒤 원본 테이블을 제거한다.

리허설 결과는 다음과 같았다. 실제 운영 DB에는 `ROLLBACK`으로 되돌렸고, migration 파일만 준비했다.

| 검증 항목 | 결과 |
|---|---:|
| V30 후 base table 수 | 13 |
| 앱 테이블 수 | 12 |
| `legacy_records` archive row | 83,053 |
| `raw_articles` count | 12,268 |
| `card_news` count | 179 |
| `peer_companies` count | 5 |
| `market_price_ohlcv` count | 3,605 |
| 제거 대상 테이블 잔존 수 | 0 |

데이터 보존 원칙:

| 데이터 | V30 이후 위치 |
|---|---|
| 기사 원문 | `raw_articles` |
| 출처별 metadata | `raw_article_source_metadata` |
| metadata 호환 조회 | `raw_article_metadata_unified` view |
| 기사-회사 연결 | `raw_articles.peer_company_ids`, `raw_articles.peer_company_links` |
| 기사 재무 metric | `raw_articles.financial_metrics` |
| 기사 사업 signal | `raw_articles.business_signals` |
| crawl run/event | `raw_articles.crawl_run_id`, `raw_articles.crawl_events`, `raw_articles.legacy_payload` |
| 카드 근거 기사 | `card_news.source_raw_article_ids`, `card_news.source_articles` |
| 검증 근거 | `card_news.evidence_payload` |
| 카드/기사 이미지 metadata | `card_news.image_assets` |
| Peer+ 재무 시계열 | `peer_companies.financial_history` |
| 채용 기반 signal | `peer_companies.job_posting_history` |
| 브리핑 카드/기사/수신/발송 이력 | `briefing_reports.related_*`, `recipients`, `delivery_history`, `legacy_payload` |
| Mixer/Insight/Global 분석 결과 | `mixer_results`, `insight_reports`, `global_industry_trends` |
| 운영/감사/비용/로그/평가 데이터 | `legacy_records` |

주의: V28 이후 최신 기사 일부는 `raw_articles.metadata = {}`처럼 보일 수 있다. source-specific payload는 `raw_article_source_metadata.source_metadata`로 분리되었고, 화면/API 호환 조회는 `raw_article_metadata_unified`를 사용한다.

---

## 1. 프론트 페이지 기준 데이터 요구사항

| 프론트 화면 | 필요한 DB 중심축 | V30 설계 |
|---|---|---|
| 홈 대시보드 | 카드, 키워드, 주가, Peer+ 요약 | `card_news`, `market_price_ohlcv`, `peer_companies` |
| 카드뉴스 | 동향 카드, 근거 원문, 검증 근거, 이미지 | `card_news` 단일 master에 `source_*`, `evidence_payload`, `image_assets` 포함 |
| Peer+ | 회사별 DART 매출/영업이익/증감률/AX 비중/수주/키워드 | `peer_companies` read model |
| 브리핑 | 일/주간 문서, 포함 카드/원문, 수신자와 발송 상태 | `briefing_reports` 단일 read model |
| 믹서 | 여러 카드를 묶은 공통 신호와 시사점 | `mixer_results` |
| 인사이트 | 선택 카드/피어 기반 전략 인사이트 | `insight_reports` |
| 글로벌 산업 | 글로벌 키워드, 산업 트렌드, SK AX 시사점 | `global_industry_trends` |
| 키워드 그래프 | 키워드 빈도, 카테고리, 카드 연결 | `card_news.keywords`, `keyword_categories`, `keyword_frequency` |
| Raw Articles | 원문 기사, 파싱 결과, 출처 metadata | `raw_articles`, `raw_article_source_metadata`, `raw_article_parse_results` |

관리자/운영 화면은 이번 최소 Product ERD에서 제외했다. 보존이 필요한 과거 row는 `legacy_records`로 조회할 수 있고, 장기적으로 별도 Ops schema 또는 로그 저장소로 분리하는 것이 맞다.

---

## 2. 최종 최소 ERD

Product ERD에 남길 테이블:

```text
peer_companies
  ├─ card_news
  └─ market_price_ohlcv

raw_articles
  ├─ raw_article_source_metadata
  └─ raw_article_parse_results

card_news
  ├─ mixer_results
  ├─ insight_reports
  ├─ global_industry_trends
  └─ briefing_reports
```

운영 상태와 데이터 보존:

```text
crawl_cursors
legacy_records
flyway_schema_history
```

View:

```text
issue_cards = SELECT * FROM card_news
raw_article_metadata_unified = raw_articles.metadata + raw_article_source_metadata.source_metadata
```

`legacy_records`는 product UX를 위한 ERD 관계에는 넣지 않는다. 대신 “무엇을 언제 어느 테이블에서 접었는지”를 추적하는 보존 금고 역할을 한다.

---

## 3. 테이블별 설명

### 3.1 `peer_companies`

모니터링 회사 master이자 Peer+ 화면 read model이다. 기존 회사명 중심 테이블에 프론트 표시 컬럼을 추가했다.

```text
dart_period
dart_revenue_krwbn
dart_operating_profit_krwbn
dart_operating_margin_pct
dart_revenue_growth_pct
dart_operating_profit_growth_pct
ax_revenue_share_pct
contract_count
core_keywords
peer_plus_payload
financial_history
job_posting_history
legacy_payload
financial_updated_at
```

`peer_financials`는 제거되지만 row는 `legacy_records`에 보존되고, 회사별 시계열은 `financial_history`로 흡수된다.

### 3.2 `raw_articles`

수집 원문의 canonical archive다. 절대 삭제하면 안 되는 기준 데이터다.

V30에서 흡수된 컬럼:

```text
peer_company_ids
peer_company_links
financial_metrics
business_signals
crawl_run_id
crawl_events
legacy_payload
```

정규화 관점으로는 원문 본문, 처리 상태, 관련 회사, 추출 metric을 더 나눌 수 있지만, 현재 서비스 규모에서는 `raw_articles`를 중심으로 두고 출처 metadata와 파싱 결과만 sidecar로 분리한 구조가 가장 유지보수 비용이 낮다.

### 3.3 `raw_article_source_metadata`

네이버/DART/채용/IR/주가 등 출처별 payload를 보관한다. V28에서 여러 source별 metadata 테이블을 하나로 모았다.

### 3.4 `raw_article_parse_results`

IR, DART, PDF 계열 파서 결과와 품질 정보를 보관한다. 원문 재처리와 품질 점검용이다.

### 3.5 `card_news`

프론트 카드뉴스의 master다. V30 이후 카드 상세에 필요한 관계 테이블을 이 테이블로 흡수했다.

```text
keyword_categories
keywords
keyword_frequency
source_raw_article_ids
source_articles
evidence_payload
image_assets
legacy_payload
```

`card_news_articles`, `evidence_chain`, `article_images`는 제거된다. 원본 row는 `legacy_records`에 있고, 화면에 필요한 값은 위 컬럼으로 옮긴다.

### 3.6 `market_price_ohlcv`

5개 KRX 회사의 일별 OHLCV read model이다. `market_instruments` 없이도 화면이 조회할 수 있도록 `peer_company_id`, `exchange`, `instrument_name`, `instrument_payload`를 갖는다.

`instrument_id`는 과거 payload 추적용으로만 남긴다. active FK로 보지 않는다.

### 3.7 `briefing_reports`

브리핑 문서 master와 발송 상태 read model을 합친 테이블이다.

```text
key_summary
sk_implication
related_card_ids
related_raw_article_ids
recipients
delivery_history
legacy_payload
```

`briefing_report_cards`, `briefing_report_articles`, `briefing_recipients`, `briefing_history`, `briefing_history_cards`, `recipients`의 화면 필요 데이터는 이 테이블로 접는다. 수신자 master row는 archive에 보존된다.

### 3.8 `mixer_results`

믹서 화면 read model이다. 선택 카드/피어/키워드와 생성 시사점을 저장한다.

### 3.9 `insight_reports`

인사이트 화면 read model이다. `@with_ledger_writeback` 결과가 이 테이블에 저장된다.

### 3.10 `global_industry_trends`

글로벌 산업 키워드와 SK AX 시사점을 저장한다. 키워드 그래프와 글로벌 산업 페이지의 기반이다.

### 3.11 `crawl_cursors`

backfill crawler의 source별 cursor만 유지한다. 실행 상세는 `raw_articles.crawl_events`와 `legacy_records`로 접었다.

### 3.12 `legacy_records`

V30에서 제거되는 레거시 테이블의 row 단위 archive다.

```text
source_table
source_pk
owner_table
owner_id
payload
archived_at
```

운영자가 과거 테이블 row를 확인해야 할 때 이 테이블을 먼저 본다.

---

## 4. 제거/흡수 매핑

| 제거 테이블 | V30 이후 위치 |
|---|---|
| `article_peer_companies` | `raw_articles.peer_company_ids`, `raw_articles.peer_company_links`, `legacy_records` |
| `raw_article_financial_metrics` | `raw_articles.financial_metrics`, `legacy_records` |
| `raw_article_business_signals` | `raw_articles.business_signals`, `legacy_records` |
| `crawl_runs`, `crawl_run_articles`, `crawl_logs` | `raw_articles.crawl_events`, `raw_articles.legacy_payload`, `legacy_records` |
| `card_news_articles` | `card_news.source_raw_article_ids`, `card_news.source_articles`, `legacy_records` |
| `evidence_chain` | `card_news.evidence_payload`, `legacy_records` |
| `article_images` | `card_news.image_assets`, `legacy_records` |
| `weak_signal_cards`, `weak_signal_card_articles` | `card_news.legacy_payload`, `peer_companies.legacy_payload`, `legacy_records` |
| `analysis_ledger` | `mixer_results`, `insight_reports`, `global_industry_trends`, `peer_companies.legacy_payload`, `legacy_records` |
| `analysis_ledger_card_news`, `analysis_ledger_peer_companies` | `legacy_records` |
| `market_instruments` | `market_price_ohlcv.peer_company_id`, `exchange`, `instrument_name`, `instrument_payload`, `legacy_records` |
| `peer_financials` | `peer_companies.financial_history`, `legacy_records` |
| `job_postings` | `peer_companies.job_posting_history`, `legacy_records` |
| `mbb_baseline` | `legacy_records` |
| `briefing_report_cards`, `briefing_report_articles` | `briefing_reports.related_card_ids`, `related_raw_article_ids`, `legacy_payload`, `legacy_records` |
| `briefing_recipients`, `recipients` | `briefing_reports.recipients`, `legacy_records` |
| `briefing_history`, `briefing_history_cards` | `briefing_reports.delivery_history`, `legacy_records` |
| `pipeline_logs`, `usage_logs`, `cost_daily_billed`, `infra_cost_daily` | `legacy_records` |
| `audit_logs`, `user_events`, `chat_sessions`, `chat_turns`, `feedback`, `golden_set` | `legacy_records` |

---

## 5. DBeaver 확인 쿼리

Flyway 버전:

```sql
SELECT installed_rank, version, description, success
FROM flyway_schema_history
ORDER BY installed_rank;
```

현재 테이블 목록:

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
```

핵심 데이터 count:

```sql
SELECT 'raw_articles' AS table_name, COUNT(*) FROM raw_articles
UNION ALL
SELECT 'card_news', COUNT(*) FROM card_news
UNION ALL
SELECT 'peer_companies', COUNT(*) FROM peer_companies
UNION ALL
SELECT 'market_price_ohlcv', COUNT(*) FROM market_price_ohlcv
UNION ALL
SELECT 'legacy_records', COUNT(*) FROM legacy_records;
```

Archive 출처별 row count:

```sql
SELECT source_table, COUNT(*) AS archived_rows
FROM legacy_records
GROUP BY source_table
ORDER BY source_table;
```

Raw article metadata 확인:

```sql
SELECT raw_article_id, source_type, source_name, metadata
FROM raw_article_metadata_unified
ORDER BY raw_article_id DESC
LIMIT 50;
```

카드 근거/검증/이미지 확인:

```sql
SELECT id, title, source_raw_article_ids, evidence_payload, image_assets
FROM card_news
ORDER BY created_at DESC
LIMIT 20;
```

---

## 6. 운영 주의사항

1. V30은 앱 코드 배포와 함께 적용해야 한다. 기존 실행 중인 pod가 삭제된 테이블을 읽으면 장애가 날 수 있다.
2. 운영 DB에 직접 적용하기 전에는 반드시 `BEGIN; ... ROLLBACK;` 리허설로 archive row count와 핵심 row count를 확인한다.
3. `legacy_records`는 데이터 보존용이다. Product ERD에서는 제외하되, 삭제하지 않는다.
4. `raw_articles`, `raw_article_source_metadata`, `market_price_ohlcv`는 사용자가 이미 쌓아둔 데이터가 있으므로 count guard를 유지한다.
