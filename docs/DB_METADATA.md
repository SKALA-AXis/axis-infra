# AXIS DB 메타데이터 인벤토리

> 어떤 데이터가 어느 저장소의 어떤 필드에 들어가는지 한눈에 본다.
> DDL 의 단일 소스: [`axis-infra/db/schema.sql`](../db/schema.sql)
> 실제 INSERT/UPDATE 코드: [`axis-ai/src/db/article_store.py`](../../axis-ai/src/db/article_store.py)
> Qdrant payload 구성: [`axis-ai/src/rag/vector_index.py`](../../axis-ai/src/rag/vector_index.py)

---

## 저장소 구성 한눈에

| 저장소 | 용도 | 보존 | 비고 |
|---|---|---|---|
| **PostgreSQL (Supabase)** | 원문 보존·감사·재처리 | 6개월 | 10개 테이블 |
| **Qdrant `axis_main`** | 검색엔진 (3개월 hot) | 90d TTL | Dense+Sparse 페이로드는 메타만 |
| **Qdrant `axis_history`** | 시그널 히스토리 (1년 cold) | 365d TTL | 약신호 분석 전용 |
| **공유 볼륨 (`IMAGE_STORAGE_PATH`)** | 카드 뉴스 이미지 파일 | 6개월 (대응 raw_articles 와 동기) | `axis-images` named volume — ai write, backend read-only |
| **`data/peer_financials/*.json`** | 재무 stub (PoC) | — | `peer_financials` 테이블 마이그 후 폐기 |

---

## 1. PostgreSQL — 10 테이블

### 1.1 `peer_companies` — 모니터링 대상 4사

> schema.sql 의 `INSERT ... ON CONFLICT DO NOTHING` 으로 4사 시드. AI 코드는 read-only.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` (PK) | VARCHAR(50) | `samsung_sds` · `lg_cns` · `hyundai_autoever` · `posco_dx` |
| `name` | VARCHAR(100) | 한글 표기명 |
| `keywords` | TEXT[] | 검색 키워드 배열 |
| `is_active` | BOOLEAN | 활성 여부 |
| `created_at` | TIMESTAMPTZ | |

### 1.2 `raw_articles` — 크롤링 원문 전량 (6개월 보관)

한 행에 다단계 결과가 누적된다 — Crawl → Cred → Dedup → Classify 가 같은 row 를 UPDATE 하면서 `processing_status` 로 단계를 추적.

| 컬럼 | 타입 | 채우는 주체 | 비고 |
|---|---|---|---|
| `id` (PK) | BIGSERIAL | DB | |
| `peer_id` (FK) | VARCHAR(50) | CrawlAgent | |
| `source_tier` | SMALLINT | CrawlAgent | 1~5 |
| `source_name` | VARCHAR(100) | CrawlAgent | |
| `title` / `content` / `url` | TEXT | CrawlAgent | `url` UNIQUE — 멱등 보장 |
| `published_at` / `collected_at` | TIMESTAMPTZ | CrawlAgent | |
| `credibility_score` / `credibility_grade` | FLOAT / VARCHAR(20) | CredibilityAgent | High/Medium/Low/Unverified |
| `cluster_id` / `is_representative` | BIGINT / BOOLEAN | DedupAgent | |
| `processing_status` | VARCHAR(30) | 단계별 update | `RAW` → `CLUSTERED_REP/DUPE` → `CLASSIFIED` (또는 `SKIPPED_QUALITY/CREDIBILITY/ERROR`) |
| `importance_level` / `importance_score` | VARCHAR(20) / FLOAT | ClassifyAgent | v3: exposure_band/score 호환 저장 |
| `qdrant_vector_id` | UUID | IndexerAgent | 대표 기사만 채워짐 |
| `metadata` | JSONB | CrawlAgent | `{url_hash, ...크롤러별 부가 필드}` |
| `created_at` | TIMESTAMPTZ | DB | |

**인덱스**: `(peer_id, published_at DESC)` · `(processing_status)` · `(cluster_id)` · `(url)`

### 1.3 `issue_cards` — AI 생성 동향 카드

`id` 형식: `IC-YYYYMMDD-NNN` (날짜별 순번, lock 으로 중복 방지)

| 컬럼 | 타입 | 채우는 주체 | 비고 |
|---|---|---|---|
| `id` (PK) | VARCHAR(50) | IssueCardAgent | `IC-20260420-001` |
| `peer_id` (FK) | VARCHAR(50) | | |
| `cluster_id` | BIGINT | DedupAgent 결과 | |
| `title` | TEXT | IssueCardAgent | ≤500자 |
| `summary_lines` | TEXT[] | IssueCardAgent | 정확히 3줄 |
| `event_type` | VARCHAR(50) | ClassifyAgent | `partnership` / `ma` / `personnel` / `tech` / `regulation` / `new_biz` |
| `importance` | VARCHAR(20) | ClassifyAgent | v3: `high/medium/low` (exposure_band 호환) |
| `importance_score` | FLOAT | ClassifyAgent | v3: exposure_score (0~1, 결정적 산식) |
| `implication` | JSONB | IssueCardAgent + EvidenceAgent | v3 통합 메타 (아래 §3.1 참조) |
| `sources` | JSONB | IssueCardAgent | 출처 목록 |
| `validation_pass` | BOOLEAN | EvidenceAgent | Quality Gate 결과 |
| `validation_sc_score` | FLOAT | EvidenceAgent | 1.0 (pass) / 0.0 (fail) — SC 검증 폐기, 의미 전환 |
| `is_human_reviewed` | BOOLEAN | 운영자 | 검토 플래그 |
| `created_at` | TIMESTAMPTZ | DB | |

**인덱스**: `(peer_id, created_at DESC)` · `(importance)` · `(event_type)`

### 1.4 `evidence_chain` — 검증 체인 4종

issue_card 1:1 — `UNIQUE(issue_card_id)` + `ON DELETE CASCADE`.
현재는 `issue_cards.implication` JSONB 안에도 통합 저장 중 (마이그 진행 중).

| 컬럼 | 타입 | 채우는 주체 | 비고 |
|---|---|---|---|
| `issue_card_id` (FK) | VARCHAR(50) | EvidenceAgent | UNIQUE |
| `source_links` | JSONB[] | EvidenceAgent | `{title, source_name, url, credibility_score}` |
| `provenance` | JSONB | EvidenceAgent | `{raw_article_ids, cluster_id, llm_model, prompt_version, evidence_version, run_at}` |
| `financial_refs` | JSONB[] | FinancialLinkerAgent | `{period, metric, value, delta_qoq, delta_yoy, dart_rcept_no, ir_page}` |
| `mbb_refs` | JSONB[] | (W5) | 컨설팅 보고서 자동 매칭 |
| `financial_link` | JSONB | FinancialLinkerAgent | `{linked, segment, highlights, headcount_delta, reason}` |
| `evidence_version` | VARCHAR(20) | EvidenceAgent | 기본 `v3.0` |
| `pass` | BOOLEAN | EvidenceAgent | 4종 첨부 통과 여부 |
| `missing` | TEXT[] | EvidenceAgent | pass=false 시 누락 항목 — human_review 트리거 |

**인덱스**: `(issue_card_id)` · `(pass)`

### 1.5 `peer_financials` — 분기·연간 재무 시계열 (Track B)

> 현재는 `axis-ai/data/peer_financials/{peer_id}.json` 의 stub 파일을 FinancialLinkerAgent 가 read 하는 구조. 본 테이블은 정의만 되어 있고 AI 코드의 INSERT 는 W5 IRParserAgent 활성 후 추가 예정.

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `peer_id` + `period` | UNIQUE | period 형식: `'2026Q1'` |
| `report_date` | DATE | 공시·발표일 |
| `dart_rcept_no` | VARCHAR(40) | DART 공시번호 (검증 추적) |
| `ir_page` | INT | IR 자료 페이지 번호 |
| `revenue_total_krwbn` | FLOAT | 전체 매출 (억원) |
| `operating_profit_krwbn` | FLOAT | 영업이익 (억원) |
| `segment_revenue` | JSONB | `{segment_id: 매출_억원}` |
| `ai_revenue_share_pct` | FLOAT | AI 매출 비중 (%) |
| `headcount` | JSONB | `{total, rd, ai_engineers_est}` |
| `raw_payload` | JSONB | IRParserAgent 원본 파싱 결과 |
| `source` | VARCHAR(20) | `stub_v0` / `dart` / `ir_pdf` / `manual` |

### 1.6 `job_postings` — 채용공고 (약신호 감지용)

> 테이블 정의만 존재. 현재 AI 코드에 writer 없음 — W7+ WeakSignalSupervisor 활성 시 사람인 크롤러가 적재 예정.

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `peer_id` (FK) | VARCHAR(50) | |
| `job_title` / `department` | TEXT / VARCHAR(100) | |
| `tech_stack` | TEXT[] | 기술 스택 배열 |
| `snapshot_week` | DATE | 월요일 기준 주간 스냅샷 |
| `is_new` | BOOLEAN | 신규 등장 여부 |
| `url` | TEXT | |
| `collected_at` | TIMESTAMPTZ | |

### 1.7 `pipeline_logs` — 파이프라인 단계 통계

`pipeline_step` · `peer_id` · `input_count` / `output_count` · `elapsed_ms` · `llm_tokens_used` · `error_msg` · `created_at`

### 1.8 `crawl_logs` — 크롤러 실행 로그

> 테이블 정의만 존재. 현재 AI 코드에 writer 없음 — 크롤러 instrumentation 추가 시 적재 예정.

`peer_id` · `source_name` · `started_at` / `finished_at` · `total_count` / `success_count` / `skipped_count` · `error_msg`

### 1.9 `golden_set` — RAG 평가용

> 사람이 수기로 적재 (annotator 컬럼 = 라벨러 이름). AI 파이프라인은 read-only.

`query` · `expected_card_ids` (TEXT[]) · `annotator` · `difficulty` (easy/hard)

### 1.10 `article_images` — 카드 뉴스 이미지 메타 (Flyway V2, W4 추가)

> 이미지 파일은 공유 볼륨(`IMAGE_STORAGE_PATH`, 기본 `/data/images`) 에 저장. DB 는 메타와 상대 경로(`storage_path`) 만 보관.
>
> - **write**: axis-ai (ImageFetchAgent — 별도 PR 예정)
> - **read**: axis-backend (`ImageController` 가 `GET /api/images/{id}` 로 바이너리 서빙, 1년 캐시)

| 컬럼 | 타입 | 채우는 주체 | 비고 |
|---|---|---|---|
| `id` (PK) | BIGSERIAL | DB | |
| `article_id` (FK) | BIGINT | ImageFetchAgent | `raw_articles(id)` · `ON DELETE SET NULL` |
| `cluster_id` | BIGINT | ImageFetchAgent | DedupAgent 결과 — 같은 클러스터 카드끼리 dedup 용 |
| `issue_card_id` (FK) | VARCHAR(50) | ImageFetchAgent | `issue_cards(id)` · `ON DELETE SET NULL` · backend 의 카드 lookup 키 |
| `source_url` | TEXT | ImageFetchAgent | og:image 또는 본문 첫 이미지 URL (원본) |
| `source_url_hash` (UNIQUE) | VARCHAR(64) | ImageFetchAgent | SHA-256(source_url) — 중복 다운로드 차단 |
| `storage_path` | TEXT | ImageFetchAgent | `IMAGE_STORAGE_PATH` 기준 **상대 경로** (예: `lg_cns/2026-04/<hash>.jpg`) |
| `content_type` | VARCHAR(50) | ImageFetchAgent | `image/jpeg` / `image/png` / `image/webp` |
| `width` / `height` | INT | ImageFetchAgent | Pillow 로 추출 |
| `file_size_bytes` | INT | ImageFetchAgent | 5MB 상한 권장 |
| `image_hash` | VARCHAR(64) | ImageFetchAgent | SHA-256(파일 콘텐츠) — 동일 파일 다른 URL 검출 |
| `alt_text` | TEXT | ImageFetchAgent | 카드 title 또는 og:image:alt |
| `attribution` | TEXT | ImageFetchAgent | 출처 표기 (예: "제공: 한경") |
| `license_status` | VARCHAR(20) | ImageFetchAgent | `unknown` / `attributed` / `public_domain` / `unsafe` (기본 `unknown`) |
| `fetched_at` | TIMESTAMPTZ | ImageFetchAgent | 다운로드 완료 시각 |
| `created_at` | TIMESTAMPTZ | DB | |

**인덱스**: `(issue_card_id)` · `(cluster_id)` · `(image_hash)`

**경로 규약 (계약)**:
- `storage_path` 는 **반드시 상대 경로** — `..` 포함 금지 (backend 가 path-traversal 차단)
- 권장 형식: `<peer_id>/<yyyy-mm>/<sha256>.<ext>` — 예: `lg_cns/2026-04/abc123de.jpg`
- 절대 경로 (`/data/images/...`) 저장 금지 — 환경 이동 시 깨짐

---

## 2. Qdrant — 벡터 페이로드

**컬렉션**: `axis_main` (3개월 hot) · `axis_history` (1년 cold)
**인덱싱 조건**: `evidence_chain.pass=True` 카드의 대표 기사 (Gate 1~3 모두 통과 ~10%)
**원문 텍스트 저장 금지** — title 500자 / summary 1000자 발췌만

| 키 | 타입 | 출처 |
|---|---|---|
| `rdb_id` | int | `raw_articles.id` (FK · 원문 조회용) |
| `issue_card_id` | str | `IC-YYYYMMDD-NNN` |
| `peer_id` | str | 4사 중 1 |
| `event_type` | str | 6 taxonomy |
| `sector` | str | 5 trend: `security` / `ai_tech` / `large_deal` / `sk_ax_biz` / `other` |
| `exposure_score` / `exposure_band` | float / str | 결정적 산식 결과 |
| `credibility_score` | float | 대표 기사 신뢰도 |
| `published_at` | int | Unix timestamp |
| `cluster_id` | int | DedupAgent 결과 |
| `source_name` | str | |
| `title` | str | ≤500자 |
| `summary` | str | 3줄 요약 ≤1000자 |

**벡터**: Dense (BGE-M3, 1024차원, COSINE) + Sparse (RRF k=60)

---

## 3. 주요 JSONB 내부 구조

### 3.1 `issue_cards.implication` (v3 통합)

```json
{
  "sector": "ai_tech",
  "sectors": ["ai_tech", "security"],
  "exposure_score": 0.74,
  "exposure_band": "high",
  "signals": { ... },
  "evidence_chain": { ... }
}
```

> 향후 `evidence_chain` 테이블로 분리 마이그레이션 예정 — 현재는 dual-write 상태.

### 3.2 `evidence_chain.provenance`

```json
{
  "raw_article_ids": [12345, 12346, 12347],
  "cluster_id": 789,
  "llm_model": "gpt-4o",
  "prompt_version": "ic-v3.0",
  "evidence_version": "v3.0",
  "run_at": "2026-04-20T08:30:00Z"
}
```

> 상수 정의 위치: [`axis-ai/src/agents/evidence_agent.py`](../../axis-ai/src/agents/evidence_agent.py) 의 `LLM_MODEL` / `PROMPT_VERSION` / `EVIDENCE_VERSION`.

### 3.3 `evidence_chain.financial_refs[]`

```json
[
  {
    "period": "2026Q1",
    "metric": "ai_revenue_share_pct",
    "value": 18.5,
    "delta_qoq": 2.3,
    "delta_yoy": 5.1,
    "dart_rcept_no": "20260315000123",
    "ir_page": 12
  }
]
```

### 3.4 `evidence_chain.financial_link`

```json
{
  "linked": true,
  "segment": "ai_solutions",
  "highlights": ["YoY 매출 +12%", "AI 인력 +30명"],
  "headcount_delta": 30,
  "reason": "ok"
}
```

### 3.5 `raw_articles.metadata`

크롤러별 부가 필드 + 공통 `url_hash` + 이미지 파이프라인 임시 보관용 키:

```json
{
  "url_hash": "a1b2c3...",
  "naver_doc_id": "...",
  "rss_guid": "...",
  "image_source_url": "https://..."
}
```

| 키 | 채우는 주체 | 읽는 주체 | 역할 |
|---|---|---|---|
| `url_hash` | CrawlAgent | (모든 단계) | URL SHA-256 — `raw_articles.url` UNIQUE 보조 |
| `naver_doc_id` / `rss_guid` 등 | 소스별 CrawlAgent | (디버깅) | 출처 추적용 부가 필드 |
| `image_source_url` | CrawlAgent (og:image / twitter:image / 본문 첫 `<img>`) | ImageFetchAgent | 카드 단계 이전에 이미지 URL 만 임시 보관. ImageFetchAgent 가 다운로드 후 `article_images` 로 정식 이전. CrawlAgent 단계에서 추출 실패해도 다음 cycle 재시도 가능 |

---

## 4. 단계별 데이터 흐름 요약

```
CrawlAgent          → INSERT raw_articles (peer_id, source_*, title, content, url,
                                          credibility_score, metadata, status='RAW')
                      ※ credibility_score 는 소스 tier 기반으로 크롤러가 미리 채움
                      ※ og:image / twitter:image / 본문 첫 <img> 추출 →
                         metadata.image_source_url 임시 저장 (ImageFetchAgent 가 읽음)
CredibilityAgent    → UPDATE raw_articles (credibility_grade,
                                          status: 'SKIPPED_CREDIBILITY' if score < 0.5)
                      ※ score 는 변경하지 않음 — grade·status 만 update
DedupAgent          → UPDATE raw_articles (cluster_id, is_representative,
                                          status: 'CLUSTERED_REP' / 'CLUSTERED_DUPE')
ClassifyAgent       → UPDATE raw_articles (importance_level, importance_score,
                                          status: 'CLASSIFIED')
                      ※ qdrant_vector_id 는 이 단계엔 NULL — IndexerAgent 가 나중에 채움
                      + 카드 dict 에 sector / event_type / exposure_score 채움
FinancialLinkAgent  → 카드 dict 에 financial_refs / financial_link 채움 (Track B 만)
IssueCardAgent      → INSERT issue_cards (id, title, summary_lines, implication, sources, ...)
EvidenceAgent       → INSERT evidence_chain (4종 + pass + missing)
                    → UPSERT 시 issue_cards.implication / validation_pass / validation_sc_score 갱신
ImageFetchAgent     → evidence.pass=true 인 카드만 대상 · fail-soft (실패해도 카드는 살림)
                    → metadata.image_source_url 다운로드 (HEAD 사전 검증 + SSRF 차단 + 5MB 상한)
                    → 공유 볼륨 IMAGE_STORAGE_PATH/<peer_id>/<yyyy-mm>/<sha256>.<ext> 저장
                    → INSERT article_images (issue_card_id, source_url, source_url_hash UNIQUE,
                                             storage_path 상대경로, content_type, width, height,
                                             image_hash, alt_text, attribution, ...)
                    ※ ON CONFLICT (source_url_hash) DO NOTHING — 중복 다운로드 차단
IndexerAgent        → evidence.pass=true 인 카드만 대상으로 필터
(vector_index_node)   → Qdrant axis_main upsert (payload + dense+sparse vector)
                    → UPDATE raw_articles (qdrant_vector_id, importance 재기록)

DeliveryAgent (08:30):
CardSelectorAgent   → SELECT issue_cards JOIN evidence_chain WHERE pass=true
                                        AND created_at > now()-24h
                    ※ backend 의 IssueCardService 도 같은 시점에 article_images JOIN
                       (issue_card_id 로 lookup) → 응답에 image_url 첨부
BriefingAgent       → 본문 생성 (수신자 role 별 fan-out) · 카드별 image_url 인라인
EmailAgent          → SMTP 발송 + INSERT briefing_history (※ DDL 미정의 — 아래 5번 참조)

PatternDetect (W7+ MON 09:00):
                    → SELECT raw_articles WHERE collected_at > now()-7d
                    → SELECT job_postings WHERE snapshot_week = 지난주
                    → AlertAgent (조건부) — Delivery.EmailAgent 재사용
```

모든 단계는 `pipeline_logs` 에 input/output count + elapsed_ms 기록.

---

## 5. 알려진 불일치 / TODO

- **`briefing_history` 테이블이 schema.sql 에 없다.** 아키텍처 문서 (`architecture/04-ai-agent-view.html`, `architecture/05-data-view.html`) 와 EmailAgent 코드 흐름에서는 참조하지만 DDL 미정의 — 마이그레이션 추가 필요.
- **`recipients` 테이블도 schema.sql 에 없다.** CardSelectorAgent 가 수신자 role 별 차등 필터링하려면 `(id, email, role, is_active)` 정도의 테이블 필요.
- **`mbb_baseline` 테이블도 schema.sql 에 없다.** 아키텍처 문서에서 4사 비교 baseline 으로 참조하지만 DDL 없음 — W5 컨설팅 보고서 매칭과 함께 정의 필요.
- **`issue_cards.implication` JSONB 와 `evidence_chain` 테이블이 dual-write 중**. 분리 마이그레이션은 BE 측에서 evidence_chain 전용 컬럼 분리 후 진행 예정 ([article_store.py:182-183](../../axis-ai/src/db/article_store.py#L182-L183)).
- **v1 잔재 컬럼**: `raw_articles.importance_level` (urgent/notable/reference) 와 `issue_cards.importance` (동일) 는 v3 에서 exposure_band (high/medium/low) 로 의미 전환 — 컬럼명 그대로 두고 값만 호환 저장. 추후 rename 마이그레이션 후보.
- **`issue_cards.validation_sc_score`**: SC 검증이 폐기된 v3 에서는 단순히 1.0/0.0 플래그로 의미 축소 — `validation_pass` 와 중복. 정리 후보.
- **`article_images` 의 파일 실체는 클러스터/PG 외부**: 공유 볼륨 (`IMAGE_STORAGE_PATH`) 에 저장. backend/ai 컨테이너가 같은 볼륨 마운트되어 있어야 동작. v1 에서 S3 + CloudFront 로 마이그 검토 — 그땐 `storage_backend` 컬럼 추가 가능성.
