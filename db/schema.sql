-- ============================================================
-- AXIS — PostgreSQL DDL
-- Single Source of Truth: axis-infra/db/schema.sql
-- 직접 수정 금지. 변경은 마이그레이션 파일로 관리하세요.
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ============================================================
-- 1. peer_companies — 모니터링 대상 Peer사
-- ============================================================
CREATE TABLE IF NOT EXISTS peer_companies (
    id          VARCHAR(50)  PRIMARY KEY,            -- 예: 'samsung_sds', 'lg_cns'
    name        VARCHAR(100) NOT NULL,
    keywords    TEXT[]       DEFAULT '{}',            -- 수집 키워드 목록
    is_active   BOOLEAN      DEFAULT TRUE,
    created_at  TIMESTAMPTZ  DEFAULT NOW()
);

-- ============================================================
-- 2. raw_articles — 크롤링 원문 전량 아카이브
-- ============================================================
CREATE TABLE IF NOT EXISTS raw_articles (
    id                  BIGSERIAL    PRIMARY KEY,
    peer_id             VARCHAR(50)  NOT NULL REFERENCES peer_companies(id),
    source_tier         SMALLINT     NOT NULL,        -- 1~5 (출처 등급)
    source_name         VARCHAR(100) NOT NULL,
    title               TEXT         NOT NULL,
    content             TEXT,
    url                 TEXT         NOT NULL UNIQUE,
    published_at        TIMESTAMPTZ  NOT NULL,
    collected_at        TIMESTAMPTZ  DEFAULT NOW(),
    credibility_score   FLOAT,
    credibility_grade   VARCHAR(20),                  -- High/Medium/Low/Unverified
    cluster_id          BIGINT,
    is_representative   BOOLEAN      DEFAULT FALSE,
    processing_status   VARCHAR(30)  DEFAULT 'RAW',   -- RAW/EMBEDDED/SKIPPED_QUALITY/SKIPPED_CREDIBILITY/CLUSTERED_DUPE/ERROR
    importance_level    VARCHAR(20),                  -- urgent/notable/reference
    importance_score    FLOAT,
    qdrant_vector_id    UUID,
    metadata            JSONB        DEFAULT '{}',
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_raw_articles_peer_published
    ON raw_articles (peer_id, published_at DESC);
CREATE INDEX IF NOT EXISTS idx_raw_articles_status
    ON raw_articles (processing_status);
CREATE INDEX IF NOT EXISTS idx_raw_articles_cluster
    ON raw_articles (cluster_id);
CREATE INDEX IF NOT EXISTS idx_raw_articles_url
    ON raw_articles (url);

-- ============================================================
-- 3. issue_cards — AI가 생성한 이슈 카드
-- ============================================================
CREATE TABLE IF NOT EXISTS issue_cards (
    id                  VARCHAR(50)  PRIMARY KEY,     -- 'IC-20260420-001' 형식
    peer_id             VARCHAR(50)  NOT NULL REFERENCES peer_companies(id),
    cluster_id          BIGINT,
    title               TEXT         NOT NULL,
    summary_lines       TEXT[]       DEFAULT '{}',    -- 3줄 요약
    event_type          VARCHAR(50),                  -- partnership/ma/personnel/tech/regulation/new_biz
    importance          VARCHAR(20),                  -- urgent/notable/reference
    importance_score    FLOAT,
    implication         JSONB,                        -- 시사점 초안 (why_important, potential_impact 등)
    sources             JSONB,                        -- 출처 목록
    validation_pass     BOOLEAN,
    validation_sc_score FLOAT,                        -- Self-Consistency 검증 점수
    is_human_reviewed   BOOLEAN      DEFAULT FALSE,
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_issue_cards_peer_created
    ON issue_cards (peer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_issue_cards_importance
    ON issue_cards (importance);
CREATE INDEX IF NOT EXISTS idx_issue_cards_event_type
    ON issue_cards (event_type);

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
    peer_id         VARCHAR(50),
    input_count     INT,
    output_count    INT,
    elapsed_ms      INT,
    llm_tokens_used INT,
    error_msg       TEXT,
    created_at      TIMESTAMPTZ  DEFAULT NOW()
);

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
-- 초기 데이터
-- ============================================================
INSERT INTO peer_companies (id, name, keywords) VALUES
    ('samsung_sds', '삼성SDS', ARRAY['삼성SDS', '삼성 SDS', 'Samsung SDS']),
    ('lg_cns',      'LG CNS',  ARRAY['LG CNS', 'LGCNS'])
ON CONFLICT (id) DO NOTHING;
