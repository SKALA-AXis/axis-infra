-- ============================================================
-- AXIS — PostgreSQL DDL
-- Single Source of Truth: axis-infra/db/schema.sql
-- 직접 수정 금지. 변경은 마이그레이션 파일로 관리하세요.
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================================
-- 1. peer_companies — 모니터링 대상 Peer사 + 자사 (SK AX)
-- ============================================================
-- 4사 (samsung_sds · lg_cns · hyundai_autoever · posco_dx) — 풀 파이프라인
-- sk_ax — 자사. raw_articles 까지만 적재, card_news 생성 X (id 로 분기)
CREATE TABLE IF NOT EXISTS peer_companies (
    id          VARCHAR(50)  PRIMARY KEY,            -- 'samsung_sds' · 'lg_cns' · 'hyundai_autoever' · 'posco_dx' · 'sk_ax'
    name        VARCHAR(100) NOT NULL,
    tier        VARCHAR(20)  NOT NULL DEFAULT 'domestic',
    keywords    TEXT[]       DEFAULT '{}',            -- 수집 키워드 목록
    is_active   BOOLEAN      DEFAULT TRUE,
    created_at  TIMESTAMPTZ  DEFAULT NOW(),
    CONSTRAINT chk_peer_companies_tier CHECK (tier IN ('self', 'domestic', 'overseas'))
);

ALTER TABLE peer_companies
    ADD COLUMN IF NOT EXISTS tier VARCHAR(20) NOT NULL DEFAULT 'domestic';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_peer_companies_tier'
          AND conrelid = 'peer_companies'::regclass
    ) THEN
        ALTER TABLE peer_companies
            ADD CONSTRAINT chk_peer_companies_tier
            CHECK (tier IN ('self', 'domestic', 'overseas'));
    END IF;
END $$;


-- ============================================================
-- 2. raw_articles — 크롤링 원문 전량 아카이브 (axis-ai current write path)
-- ============================================================
CREATE TABLE IF NOT EXISTS raw_articles (
    id                  BIGSERIAL    PRIMARY KEY,

    source_type         VARCHAR(50)  NOT NULL,
    source_name         VARCHAR(100) NOT NULL,
    publisher           VARCHAR(150),

    title               VARCHAR(500) NOT NULL,
    content             TEXT,
    url                 TEXT         NOT NULL UNIQUE,
    url_hash            VARCHAR(32)  NOT NULL,

    published_at        TIMESTAMPTZ,
    collected_at        TIMESTAMPTZ  NOT NULL,

    company             JSONB        NOT NULL DEFAULT '[]',
    language            VARCHAR(10)  NOT NULL DEFAULT 'ko',
    content_type        VARCHAR(30)  NOT NULL,

    crawl_status        VARCHAR(20)  NOT NULL DEFAULT 'success',
    error_message       TEXT,
    processing_status   VARCHAR(40)  NOT NULL DEFAULT 'RAW',
    metadata            JSONB        NOT NULL DEFAULT '{}',

    credibility_score   FLOAT,
    credibility_grade   VARCHAR(20),

    relevance_score     FLOAT,
    relevance_label     VARCHAR(20),
    relevance_reason    TEXT,
    matched_companies   JSONB        NOT NULL DEFAULT '[]',
    matched_sectors     JSONB        NOT NULL DEFAULT '[]',

    cluster_id          BIGINT,
    is_representative   BOOLEAN,

    importance_level    VARCHAR(20),
    importance_score    FLOAT,
    qdrant_vector_id    UUID,

    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_raw_articles_url_hash
    ON raw_articles (url_hash);
CREATE INDEX IF NOT EXISTS idx_raw_articles_source_type
    ON raw_articles (source_type);
CREATE INDEX IF NOT EXISTS idx_raw_articles_source_name
    ON raw_articles (source_name);
CREATE INDEX IF NOT EXISTS idx_raw_articles_published_at
    ON raw_articles (published_at);
CREATE INDEX IF NOT EXISTS idx_raw_articles_processing_status
    ON raw_articles (processing_status);
CREATE INDEX IF NOT EXISTS idx_raw_articles_company
    ON raw_articles USING GIN(company);
CREATE INDEX IF NOT EXISTS idx_raw_articles_metadata
    ON raw_articles USING GIN(metadata);
CREATE INDEX IF NOT EXISTS idx_raw_articles_matched_companies
    ON raw_articles USING GIN(matched_companies);
CREATE INDEX IF NOT EXISTS idx_raw_articles_matched_sectors
    ON raw_articles USING GIN(matched_sectors);
CREATE INDEX IF NOT EXISTS idx_raw_articles_cluster_id
    ON raw_articles (cluster_id);
CREATE INDEX IF NOT EXISTS idx_raw_articles_is_representative
    ON raw_articles (is_representative);
CREATE INDEX IF NOT EXISTS idx_raw_articles_qdrant_vector_id
    ON raw_articles (qdrant_vector_id);
-- url 컬럼은 UNIQUE 제약으로 PG 가 자동 인덱스 생성 — 별도 인덱스 불필요.


-- ============================================================
-- 3. card_news — AI가 생성한 카드 뉴스 (axis-ai current write path)
-- ============================================================
-- v3 변경사항:
--   - company 컬럼: axis-ai IssueCardAgent (function-named, 보존) 가 company/peer_id 값을 문자열로 저장
--   - implication JSONB: v3 메타데이터 (sector, sectors, exposure_score, exposure_band,
--     signals, evidence_chain) 통합 저장. 향후 evidence_chain 테이블로 분리 마이그레이션 예정
--   - validation_pass / validation_sc_score: EvidenceAgent의 검증 첨부 결과
CREATE TABLE IF NOT EXISTS card_news (
    id                  VARCHAR(30)  PRIMARY KEY,     -- 'IC-YYYYMMDD-001' 형식
    company             VARCHAR(50)  NOT NULL,
    cluster_id          BIGINT,

    title               VARCHAR(500) NOT NULL,
    summary_lines       TEXT[]       NOT NULL DEFAULT '{}',

    event_type          VARCHAR(50)  NOT NULL DEFAULT 'tech',
    importance          VARCHAR(20)  NOT NULL DEFAULT 'low',
    importance_score    FLOAT        NOT NULL DEFAULT 0.0,

    implication         JSONB        NOT NULL DEFAULT '{}',
    sources             JSONB        NOT NULL DEFAULT '[]',

    validation_pass     BOOLEAN      NOT NULL DEFAULT FALSE,
    validation_sc_score FLOAT        NOT NULL DEFAULT 0.0,
    is_human_reviewed   BOOLEAN      DEFAULT FALSE,
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_card_news_company
    ON card_news (company);
CREATE INDEX IF NOT EXISTS idx_card_news_cluster_id
    ON card_news (cluster_id);
CREATE INDEX IF NOT EXISTS idx_card_news_event_type
    ON card_news (event_type);
CREATE INDEX IF NOT EXISTS idx_card_news_importance
    ON card_news (importance);
CREATE INDEX IF NOT EXISTS idx_card_news_validation_pass
    ON card_news (validation_pass);

-- ============================================================
-- 4. job_postings — 채용공고 (약한 신호 감지용)
-- ============================================================
CREATE TABLE IF NOT EXISTS job_postings (
    id              BIGSERIAL    PRIMARY KEY,
    peer_id         VARCHAR(50)  NOT NULL REFERENCES peer_companies(id),
    job_title       TEXT         NOT NULL,
    department      VARCHAR(100),
    tech_stack      TEXT[]       DEFAULT '{}',
    snapshot_week   DATE         NOT NULL,            -- 주 단위 스냅샷 (월요일 기준)
    is_new          BOOLEAN      DEFAULT TRUE,
    url             TEXT,
    collected_at    TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_job_postings_peer_week
    ON job_postings (peer_id, snapshot_week DESC);

-- ============================================================
-- 5. golden_set — RAG 평가용 골든셋
-- ============================================================
CREATE TABLE IF NOT EXISTS golden_set (
    id                  BIGSERIAL   PRIMARY KEY,
    query               TEXT        NOT NULL,
    expected_card_ids   TEXT[]      DEFAULT '{}',
    annotator           VARCHAR(50),
    difficulty          VARCHAR(10),                  -- easy/hard
    created_at          TIMESTAMPTZ DEFAULT NOW()
);


-- ============================================================
-- 6. pipeline_logs — AI 파이프라인 실행 로그
-- ============================================================
CREATE TABLE IF NOT EXISTS pipeline_logs (
    id              BIGSERIAL    PRIMARY KEY,
    pipeline_step   VARCHAR(50)  NOT NULL,
    company         VARCHAR(50),
    input_count     INT          NOT NULL DEFAULT 0,
    output_count    INT          NOT NULL DEFAULT 0,
    elapsed_ms      INT          NOT NULL DEFAULT 0,
    llm_tokens_used INT          NOT NULL DEFAULT 0,
    error_msg       TEXT,
    created_at      TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pipeline_logs_step
    ON pipeline_logs (pipeline_step);
CREATE INDEX IF NOT EXISTS idx_pipeline_logs_company
    ON pipeline_logs (company);

-- ============================================================
-- 7. crawl_logs — 크롤러 실행 로그
-- ============================================================
CREATE TABLE IF NOT EXISTS crawl_logs (
    id              BIGSERIAL    PRIMARY KEY,
    peer_id         VARCHAR(50)  NOT NULL,
    source_name     VARCHAR(100) NOT NULL,
    started_at      TIMESTAMPTZ  NOT NULL,
    finished_at     TIMESTAMPTZ,
    total_count     INT          DEFAULT 0,
    success_count   INT          DEFAULT 0,
    skipped_count   INT          DEFAULT 0,
    error_msg       TEXT,
    created_at      TIMESTAMPTZ  DEFAULT NOW()
);

-- ============================================================
-- 8. peer_financials — Peer사 분기·연간 재무 시계열 (v3 §5.1)
-- ============================================================
-- IR PDF / DART 공시에서 추출한 매출·영업이익·사업부별 매출·AI 비중·헤드카운트.
-- FinancialLinkerAgent가 뉴스 카드와 연결하여 evidence_chain.financial_refs에 첨부.
-- PoC: data/peer_financials/{peer_id}.json 기반. 마이그레이션 후 이 테이블로 전환.
CREATE TABLE IF NOT EXISTS peer_financials (
    id                  BIGSERIAL    PRIMARY KEY,
    peer_id             VARCHAR(50)  NOT NULL REFERENCES peer_companies(id),
    period              VARCHAR(10)  NOT NULL,           -- 'YYYYQn' (예: '2026Q1')
    report_date         DATE,                            -- 공시·발표일
    dart_rcept_no       VARCHAR(40),                     -- DART 공시번호 (검증 추적용)
    ir_page             INT,                             -- IR 자료 페이지 번호
    revenue_total_krwbn FLOAT,                           -- 전체 매출 (억원)
    operating_profit_krwbn FLOAT,                        -- 영업이익 (억원)
    segment_revenue     JSONB        DEFAULT '{}',       -- {segment_id: 매출_억원}
    ai_revenue_share_pct FLOAT,                          -- AI 매출 비중 (%)
    headcount           JSONB        DEFAULT '{}',       -- {total, rd, ai_engineers_est}
    raw_payload         JSONB,                           -- 파싱 원본 / IRParserAgent 후처리 결과
    source              VARCHAR(20)  DEFAULT 'stub_v0',  -- stub_v0 / dart / ir_pdf / manual
    created_at          TIMESTAMPTZ  DEFAULT NOW(),
    UNIQUE (peer_id, period)
);

CREATE INDEX IF NOT EXISTS idx_peer_financials_peer_period
    ON peer_financials (peer_id, period);


-- ============================================================
-- 9. evidence_chain — 검증 체인 4종 (v3 §3.2, §5.6)
-- ============================================================
-- 모든 카드뉴스의 4종 검증 정보 (source_links / provenance / financial_refs / mbb_refs).
-- API: GET /api/evidence/{card_news_id} 가 이 테이블을 조회.
CREATE TABLE IF NOT EXISTS evidence_chain (
    card_news_id       VARCHAR(30)  PRIMARY KEY REFERENCES card_news(id) ON DELETE CASCADE,

    source_links        JSONB        NOT NULL DEFAULT '[]',
    provenance          JSONB        NOT NULL DEFAULT '{}',
    financial_refs      JSONB        NOT NULL DEFAULT '[]',
    mbb_refs            JSONB        NOT NULL DEFAULT '[]',
    financial_link      JSONB        NOT NULL DEFAULT '{}',

    evidence_version    VARCHAR(20)  NOT NULL DEFAULT 'v3.0',
    pass                BOOLEAN      NOT NULL DEFAULT FALSE,
    missing             TEXT[]       NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_evidence_chain_pass
    ON evidence_chain (pass);
CREATE INDEX IF NOT EXISTS idx_evidence_chain_version
    ON evidence_chain (evidence_version);

-- ============================================================
-- 10. article_images — 카드 뉴스 이미지 메타 (v3 W4 추가, V2 migration)
-- ============================================================
-- 이미지 파일은 공유 볼륨 (IMAGE_STORAGE_PATH) 에 저장.
-- DB 는 storage_path (relative) + 메타데이터만 보관.
--   write: axis-ai (ImageFetchAgent — 별도 PR 예정)
--   read:  axis-backend (ImageController)
CREATE TABLE IF NOT EXISTS article_images (
    id                  BIGSERIAL    PRIMARY KEY,

    article_id          BIGINT       REFERENCES raw_articles(id) ON DELETE SET NULL,
    cluster_id          BIGINT,
    card_news_id       VARCHAR(50)  REFERENCES card_news(id) ON DELETE SET NULL,

    source_url          TEXT         NOT NULL,
    source_url_hash     VARCHAR(64)  NOT NULL UNIQUE,    -- SHA-256(source_url)

    storage_path        TEXT         NOT NULL,           -- IMAGE_STORAGE_PATH 기준 상대 경로
    content_type        VARCHAR(50),                     -- image/jpeg | image/png | image/webp
    width               INT,
    height              INT,
    file_size_bytes     INT,

    alt_text            TEXT,
    attribution         TEXT,                            -- 예: "제공: 한경"

    fetched_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_article_images_card
    ON article_images (card_news_id);
CREATE INDEX IF NOT EXISTS idx_article_images_cluster
    ON article_images (cluster_id);

-- ============================================================
-- 11. recipients — 메일 수신자 (Flyway V3, W5 추가)
-- ============================================================
-- CardSelectorAgent 가 role 별 impact_threshold 로 차등 필터링.
-- PM = impact ≥ 3 전체 / 임원 = impact ≥ 4 핵심.
CREATE TABLE IF NOT EXISTS recipients (
    id                  BIGSERIAL    PRIMARY KEY,

    email               VARCHAR(255) NOT NULL UNIQUE,
    name                VARCHAR(100),
    role                VARCHAR(20)  NOT NULL,           -- pm | executive | admin
    impact_threshold    SMALLINT     NOT NULL DEFAULT 3, -- 1~5 (수신할 카드의 최소 importance_score)
    locale              VARCHAR(10)  DEFAULT 'ko-KR',

    is_active           BOOLEAN      DEFAULT TRUE,
    created_at          TIMESTAMPTZ  DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_recipients_active
    ON recipients (is_active, role);


-- ============================================================
-- 12. briefing_history — 메일 발송 이력 (Flyway V3)
-- ============================================================
-- 평일 08:30 EmailAgent 가 발송 후 INSERT.
-- status=skipped (card_count==0) / sent / failed 모두 기록 — DLQ + 운영 알림의 단일 소스.
CREATE TABLE IF NOT EXISTS briefing_history (
    id                  BIGSERIAL    PRIMARY KEY,

    recipient_id        BIGINT       NOT NULL REFERENCES recipients(id) ON DELETE RESTRICT,
    briefing_date       DATE         NOT NULL,                    -- 어느 영업일의 브리핑인지
    run_id              VARCHAR(50),                              -- 한 cycle 의 식별자 (재시도 추적)

    card_count          INT          NOT NULL DEFAULT 0,
    card_ids            TEXT[]       DEFAULT '{}',                -- 포함된 card_news.id 배열
    subject             TEXT,                                      -- 메일 제목
    body_preview        TEXT,                                      -- 본문 첫 200자 (감사 + 디버깅)

    status              VARCHAR(20)  NOT NULL,                    -- sent | failed | skipped
    smtp_response       TEXT,                                      -- SendGrid/SMTP 응답
    error_msg           TEXT,                                      -- status=failed 시 상세
    retry_count         SMALLINT     DEFAULT 0,                   -- EmailAgent 의 retry ×3 횟수

    sent_at             TIMESTAMPTZ  DEFAULT NOW(),
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_briefing_history_recipient_date
    ON briefing_history (recipient_id, briefing_date DESC);
CREATE INDEX IF NOT EXISTS idx_briefing_history_run
    ON briefing_history (run_id);
CREATE INDEX IF NOT EXISTS idx_briefing_history_status
    ON briefing_history (status);


-- ============================================================
-- 13. mbb_baseline — 컨설팅 보고서 baseline (Flyway V3, W5 활성 예정)
-- ============================================================
-- McKinsey · Bain · BCG · 커니 등 글로벌 컨설팅 보고서 baseline.
-- EvidenceAgent 가 카드 sector/keywords 와 매칭하여 evidence_chain.mbb_refs 에 첨부.
CREATE TABLE IF NOT EXISTS mbb_baseline (
    id                  BIGSERIAL    PRIMARY KEY,

    source              VARCHAR(50)  NOT NULL,                    -- 'McKinsey' | 'BCG' | 'Bain' | 'Kearney' | ...
    report_id           VARCHAR(100),                              -- 발행처 내부 식별자
    title               TEXT         NOT NULL,
    published_date      DATE,
    url                 TEXT,
    summary             TEXT,

    sectors             TEXT[]       DEFAULT '{}',                -- ['ai_tech', 'security'] 등
    keywords            TEXT[]       DEFAULT '{}',                -- 매칭 키워드 배열

    raw_payload         JSONB        DEFAULT '{}',

    is_active           BOOLEAN      DEFAULT TRUE,
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mbb_baseline_source_date
    ON mbb_baseline (source, published_date DESC);
CREATE INDEX IF NOT EXISTS idx_mbb_baseline_active
    ON mbb_baseline (is_active);


-- ============================================================
-- 초기 데이터 — Peer사 4사 + SK AX 자사 (tier 로 self/domestic/overseas 구분)
-- ============================================================
INSERT INTO peer_companies (id, name, tier, keywords) VALUES
    ('samsung_sds',      '삼성SDS',     'domestic', ARRAY['삼성SDS', '삼성 SDS', 'Samsung SDS']),
    ('lg_cns',           'LG CNS',      'domestic', ARRAY['LG CNS', 'LGCNS']),
    ('hyundai_autoever', '현대오토에버', 'domestic', ARRAY['현대오토에버', '오토에버', 'Hyundai AutoEver']),
    ('posco_dx',         '포스코DX',    'domestic', ARRAY['포스코DX', '포스코 DX', 'POSCO DX']),
    ('sk_ax',            'SK AX',       'self',     ARRAY['SK AX', 'SKAX', '에스케이에이엑스', 'SK 에이엑스'])
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    tier = EXCLUDED.tier,
    keywords = EXCLUDED.keywords;
