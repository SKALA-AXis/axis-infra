# AXIS DB 메타데이터 인벤토리

> 어떤 데이터가 어느 저장소의 어떤 필드에 들어가는지 한눈에 본다.
> DDL 의 단일 소스: [`axis-infra/db/schema.sql`](../db/schema.sql)
> 실제 INSERT/UPDATE 코드: [`axis-ai/src/db/article_store.py`](../../axis-ai/src/db/article_store.py)
> Qdrant payload 구성: [`axis-ai/src/rag/vector_index.py`](../../axis-ai/src/rag/vector_index.py)

---

## 저장소 구성 한눈에

| 저장소 | 용도 | 보존 | 비고 |
|---|---|---|---|
| **PostgreSQL (in-cluster · 5Gi gp3 PVC)** | 원문 보존·감사·재처리 | 6개월 | 13개 테이블 — `postgres:5432` (ClusterIP) · 일일 백업 `axis-pg-dump` CronJob |
| **Qdrant `axis_main`** | 검색엔진 (3개월 hot) | 90d TTL | Dense+Sparse 페이로드는 메타만 |
| **Qdrant `axis_history`** | 시그널 히스토리 (1년 cold) | 365d TTL | 약신호 분석 전용 |
| **공유 볼륨 (`IMAGE_STORAGE_PATH`)** | 카드 뉴스 이미지 파일 | 6개월 (대응 raw_articles 와 동기) | `axis-images` named volume — ai write, backend read-only |
| **`data/peer_financials/*.json`** | 재무 stub (PoC) | — | `peer_financials` 테이블 마이그 후 폐기 |

---

## 1. PostgreSQL — 13 테이블

### 1.1 `peer_companies` — 모니터링 대상 4사

> schema.sql 의 `INSERT ... ON CONFLICT DO NOTHING` 으로 4사 + 자사 (SK AX) 시드. AI 코드는 read-only.

| 컬럼 | 타입 | 설명 |
|---|---|---|
| `id` (PK) | VARCHAR(50) | `samsung_sds` · `lg_cns` · `hyundai_autoever` · `posco_dx` · `sk_ax` |
| `name` | VARCHAR(100) | 한글 표기명 |
| `tier` | VARCHAR(20) | `self` · `domestic` · `overseas` |
| `keywords` | TEXT[] | 검색 키워드 배열 |
| `is_active` | BOOLEAN | 활성 여부 |
| `created_at` | TIMESTAMPTZ | |

> **id 별 도메인 의미**
> - 4사 (`samsung_sds` · `lg_cns` · `hyundai_autoever` · `posco_dx`) — 모니터링 대상 경쟁사. 풀 파이프라인 (raw_articles → issue_cards → evidence_chain) 진행
> - `sk_ax` — 자사. MVP 단계에서 발주처 내부 데이터 부재로 외부 공개 정보 (뉴스·공시·채용) 만 크롤링하여 비교 baseline 으로 활용. **issue_card 생성 안 함** — raw_articles 까지만 적재
> - 향후 `global_companies` 로 추가되는 해외 기업은 `tier = 'overseas'` 로 저장
> - axis-ai 영향: `IssueCardAgent` 가 `peer.id == 'sk_ax'` (또는 `SELF_PEER_IDS` config) 면 카드 생성 skip. `ExposureScoreAgent` 도 sk_ax 인 경우 `peer_mention_rate=0` 강제.

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
| `importance_score` | FLOAT | ClassifyAgent | v3 exposure_score (결정적 산식, 0~1) |
| `metadata` | JSONB | CrawlAgent | `{url_hash, ...크롤러별 부가 필드}` |
| `created_at` | TIMESTAMPTZ | DB | |

**인덱스**: `(peer_id, published_at DESC)` · `(processing_status)` · `(cluster_id)`
> `url` 은 UNIQUE 제약으로 자동 인덱스 생성 — 별도 명시적 인덱스 X (V4 정리)

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
| `alt_text` | TEXT | ImageFetchAgent | 카드 title 또는 og:image:alt |
| `attribution` | TEXT | ImageFetchAgent | 출처 표기 (예: "제공: 한경") |
| `fetched_at` | TIMESTAMPTZ | ImageFetchAgent | 다운로드 완료 시각 |
| `created_at` | TIMESTAMPTZ | DB | |

**인덱스**: `(issue_card_id)` · `(cluster_id)`

**경로 규약 (계약)**:
- `storage_path` 는 **반드시 상대 경로** — `..` 포함 금지 (backend 가 path-traversal 차단)
- 권장 형식: `<peer_id>/<yyyy-mm>/<sha256>.<ext>` — 예: `lg_cns/2026-04/abc123de.jpg`
- 절대 경로 (`/data/images/...`) 저장 금지 — 환경 이동 시 깨짐

### 1.11 `recipients` — 메일 수신자 (Flyway V3, W5 추가)

> CardSelectorAgent 가 `role` 별 `impact_threshold` 로 차등 필터링.
> PM = impact ≥ 3 전체 / 임원 = impact ≥ 4 핵심 (architecture/04 §4.5 와 일치).
>
> - **write**: 운영자 (관리 도구) 또는 seed SQL
> - **read**: axis-ai (CardSelectorAgent) — 활성 수신자 목록 조회

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `id` (PK) | BIGSERIAL | DB |
| `email` (UNIQUE) | VARCHAR(255) | 메일 주소 (수신자 키) |
| `name` | VARCHAR(100) | 이름 (메일 To 표시용) |
| `role` | VARCHAR(20) | `pm` / `executive` / `admin` |
| `impact_threshold` | SMALLINT | 1~5 · 수신할 카드의 최소 importance_score (default 3) |
| `locale` | VARCHAR(10) | default `ko-KR` |
| `is_active` | BOOLEAN | default TRUE — 비활성 수신자 일괄 토글 |
| `created_at` / `updated_at` | TIMESTAMPTZ | DB |

**인덱스**: `(is_active, role)` — 활성 수신자만 role 별로 조회

### 1.12 `briefing_history` — 메일 발송 이력 (Flyway V3)

> 평일 08:30 EmailAgent 가 발송 후 INSERT.
> `status=skipped` (card_count==0) / `sent` / `failed` 모두 기록 — DLQ + 운영 알림의 단일 소스.

| 컬럼 | 타입 | 채우는 주체 | 비고 |
|---|---|---|---|
| `id` (PK) | BIGSERIAL | DB | |
| `recipient_id` (FK) | BIGINT | EmailAgent | `recipients(id)` · `ON DELETE RESTRICT` (이력 보존) |
| `briefing_date` | DATE | EmailAgent | 어느 영업일의 브리핑인지 (배치 단위) |
| `run_id` | VARCHAR(50) | EmailAgent | 한 cycle 식별자 — retry 추적 |
| `card_count` | INT | EmailAgent | 메일에 포함된 카드 수 (0 이면 skipped) |
| `card_ids` | TEXT[] | EmailAgent | 포함된 `issue_cards.id` 배열 |
| `subject` | TEXT | EmailAgent | 메일 제목 |
| `body_preview` | TEXT | EmailAgent | 본문 첫 200자 (감사 + 디버깅) |
| `status` | VARCHAR(20) | EmailAgent | `sent` / `failed` / `skipped` |
| `smtp_response` | TEXT | EmailAgent | SendGrid/SMTP 응답 (코드 + 메시지) |
| `error_msg` | TEXT | EmailAgent | status=failed 시 상세 |
| `retry_count` | SMALLINT | EmailAgent | EmailAgent 의 retry ×3 횟수 |
| `sent_at` | TIMESTAMPTZ | EmailAgent | 발송 시각 |
| `created_at` | TIMESTAMPTZ | DB | |

**인덱스**: `(recipient_id, briefing_date DESC)` · `(run_id)` · `(status)`

### 1.13 `mbb_baseline` — 컨설팅 보고서 baseline (Flyway V3, W5 활성)

> McKinsey · Bain · BCG · 커니 등 글로벌 컨설팅 보고서를 baseline 으로 보관.
> EvidenceAgent 가 카드의 `sectors`/`keywords` 와 매칭하여 `evidence_chain.mbb_refs` 에 첨부.
>
> - **write**: 운영자 (수기 적재) 또는 W5 컨설팅 보고서 크롤러
> - **read**: axis-ai (EvidenceAgent)

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `id` (PK) | BIGSERIAL | DB |
| `source` | VARCHAR(50) | `McKinsey` / `BCG` / `Bain` / `Kearney` / ... |
| `report_id` | VARCHAR(100) | 발행처 내부 식별자 (있으면) |
| `title` | TEXT | 보고서 제목 |
| `published_date` | DATE | 발행일 |
| `url` | TEXT | 원문 URL (PDF · 웹) |
| `summary` | TEXT | 핵심 요약 (운영자 입력 또는 AI 생성) |
| `sectors` | TEXT[] | 매칭 키 — `[ax, security]` 등 |
| `keywords` | TEXT[] | 매칭 키워드 배열 |
| `raw_payload` | JSONB | 추가 메타 (저자 · 페이지 수 등) |
| `is_active` | BOOLEAN | default TRUE |
| `created_at` | TIMESTAMPTZ | DB |

**인덱스**: `(source, published_date DESC)` · `(is_active)`

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
| `sector` | str | 5 trend: `ax` / `security` / `infra` / `deal` / `other` |
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
  "sector": "ax",
  "sectors": ["ax", "security"],
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
ClassifyAgent       → UPDATE raw_articles (importance_score, status: 'CLASSIFIED')
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
                                             alt_text, attribution, fetched_at, ...)
                    ※ ON CONFLICT (source_url_hash) DO NOTHING — 중복 다운로드 차단
IndexerAgent        → evidence.pass=true 인 카드만 대상으로 필터
(vector_index_node)   → Qdrant axis_main upsert (payload + dense+sparse vector)
                      ※ Qdrant payload 의 rdb_id 가 raw_articles 역참조 키 — DB 컬럼 별도 X

DeliveryAgent (08:30):
CardSelectorAgent   → SELECT recipients WHERE is_active=true       (V3 활성 후)
                    → SELECT issue_cards JOIN evidence_chain WHERE pass=true
                                        AND created_at > now()-24h
                    → 수신자 role 별 차등: PM (impact_threshold=3) · 임원 (=4)
                    ※ backend 의 IssueCardService 도 같은 시점에 article_images JOIN
                       (issue_card_id 로 lookup) → 응답에 image_url 첨부
BriefingAgent       → EvidenceAgent 가 mbb_baseline 에서 sectors/keywords 매칭
                       → evidence_chain.mbb_refs 에 첨부 (W5 활성)
                    → 본문 생성 (수신자 role 별 fan-out) · 카드별 image_url 인라인
EmailAgent          → SMTP 발송 + INSERT briefing_history
                       (recipient_id, briefing_date, run_id, card_ids, status, retry_count, ...)
                    → status=skipped (card_count==0) / sent / failed 모두 기록 — DLQ 단일 소스

PatternDetect (W7+ MON 09:00):
                    → SELECT raw_articles WHERE collected_at > now()-7d
                    → SELECT job_postings WHERE snapshot_week = 지난주
                    → AlertAgent (조건부) — Delivery.EmailAgent 재사용
```

모든 단계는 `pipeline_logs` 에 input/output count + elapsed_ms 기록.

---

## 5. 알려진 불일치 / TODO

### 해결된 항목 (참고용 · 이력)

- ~~**`briefing_history` 테이블이 schema.sql 에 없다.**~~ → V3 추가 (§1.12)
- ~~**`recipients` 테이블도 schema.sql 에 없다.**~~ → V3 추가 (§1.11)
- ~~**`mbb_baseline` 테이블도 schema.sql 에 없다.**~~ → V3 추가 (§1.13)

### V4 (2026-05-06) 정리 완료

- ~~`raw_articles.importance_level`~~ DROP — v1 잔재. SELECT 0 건 (importance_score 만 사용).
- ~~`raw_articles.qdrant_vector_id`~~ DROP — Qdrant payload `rdb_id` 로 역참조 충분.
- ~~`article_images.image_hash`~~ DROP — INSERT/SELECT 0 건 (source_url_hash 가 UNIQUE 키).
- ~~`article_images.license_status`~~ DROP — 기본값 'unknown' 외 INSERT 없음.
- ~~`idx_raw_articles_url`~~, ~~`idx_evidence_chain_card`~~, ~~`idx_article_images_hash`~~ DROP — UNIQUE 자동 인덱스와 중복 / 컬럼 폐기.

### V5 (2026-05-06) 자사 (SK AX) 비교 baseline 도입

- `sk_ax` 시드 추가 (keywords: SK AX · SKAX · 에스케이에이엑스 · SK 에이엑스)
- ~~`peer_companies.role` 컬럼 + `idx_peer_companies_role`~~ → V6 에서 제거
- **의도**: MVP 단계에서 발주처 내부 정보 부재 → 외부 공개 정보로 비교 baseline 확보. `PeersView` 5사 비교 시 사용 (frontend 변경은 W6+ 보류)

### V6 (2026-05-06) role 컬럼 폐기 — id 로 분기

- ~~`peer_companies.role`~~ DROP — 자사가 영원히 단일 row (`sk_ax`) 라 single-value 필드. id 자체가 PK 라 `id == 'sk_ax'` 로 충분히 식별
- ~~`idx_peer_companies_role`~~ DROP — 컬럼 폐기에 따라 자동 정리
- `sk_ax` 시드 row 는 그대로 보존 (V5 의 데이터 가치 유지)
- **axis-ai 동반 변경 필요 (별도 PR)**:
  - `IssueCardAgent` — `peer.id == 'sk_ax'` (또는 `SELF_PEER_IDS = {'sk_ax'}` config 상수) 면 카드 생성 skip
  - `ExposureScoreAgent` — `sk_ax` 인 경우 `peer_mention_rate=0` 강제
  - 크롤러 config — `peer_id='sk_ax'` 키워드 추가하여 raw_articles 적재 (V5 와 동일)

### V7 (2026-05-07) company tier 도입

- `peer_companies.tier` 추가 — `self | domestic | overseas`
- 초기 시드 기준: `sk_ax = self`, 기존 국내 4사 = `domestic`
- 향후 해외 기업 registry (`global_companies`) 에서 들어오는 row 는 `overseas` 로 저장

### 남은 항목 (코드 변경 동반 — 별도 PR)

- **`issue_cards.implication` JSONB 와 `evidence_chain` 테이블이 dual-write 중**. axis-ai 의 [article_store.py](../../axis-ai/src/db/article_store.py) 가 implication JSONB 안에 evidence_chain 도 함께 저장 + evidence_chain 테이블에도 따로 INSERT. 분리는 BE 측의 IssueCard JPA entity 에서 evidence_chain 전용 컬럼 제거 후 진행 예정. **현재 영향**: 같은 데이터가 두 곳에 — 한 쪽 수정 시 sync 깨질 위험.
- **`issue_cards.importance` (varchar)**: v1 잔재명이지만 v3 에서 exposure_band (high/medium/low) 호환 저장. backend `IssueCardRepository.findAll(orderBy importance)` 가 사용 중 — 컬럼명 그대로 유지, 값만 호환.
- **`issue_cards.validation_sc_score`**: SC 검증이 폐기된 v3 에서는 단순히 1.0/0.0 플래그로 의미 축소 — `validation_pass` 와 중복. evidence_agent 가 여전히 채우는 중 → axis-ai 동반 정리 필요.
- **`article_images` 의 파일 실체는 클러스터/PG 외부**: 공유 볼륨 (`IMAGE_STORAGE_PATH`) 에 저장. backend/ai 컨테이너가 같은 볼륨 마운트되어 있어야 동작. v1 에서 S3 + CloudFront 로 마이그 검토 — 그땐 `storage_backend` 컬럼 추가 가능성.
