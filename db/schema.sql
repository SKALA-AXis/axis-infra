-- AXIS minimal product schema, V30 target
-- Snapshot date: 2026-05-19 KST
--
-- Physical app tables after V30:
--   peer_companies, raw_articles, raw_article_source_metadata,
--   raw_article_parse_results, card_news, market_price_ohlcv,
--   briefing_reports, mixer_results, insight_reports,
--   global_industry_trends, crawl_cursors, legacy_records.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE OR REPLACE FUNCTION axis_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS peer_companies (
    id VARCHAR(50) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    tier VARCHAR(20) NOT NULL DEFAULT 'domestic',
    keywords TEXT[] DEFAULT '{}',
    dart_period TEXT,
    dart_revenue_krwbn NUMERIC(18,2),
    dart_operating_profit_krwbn NUMERIC(18,2),
    dart_operating_margin_pct NUMERIC(9,4),
    dart_revenue_growth_pct NUMERIC(9,4),
    dart_operating_profit_growth_pct NUMERIC(9,4),
    ax_revenue_share_pct NUMERIC(9,4),
    contract_count INT NOT NULL DEFAULT 0,
    core_keywords TEXT[] NOT NULL DEFAULT '{}',
    peer_plus_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    financial_history JSONB NOT NULL DEFAULT '[]'::jsonb,
    job_posting_history JSONB NOT NULL DEFAULT '[]'::jsonb,
    legacy_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    financial_updated_at TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT chk_peer_companies_tier CHECK (tier IN ('self', 'domestic', 'overseas'))
);

CREATE INDEX IF NOT EXISTS idx_peer_companies_core_keywords
    ON peer_companies USING GIN(core_keywords);

CREATE TABLE IF NOT EXISTS crawl_cursors (
    source_name VARCHAR(100) PRIMARY KEY,
    cursor_date DATE NOT NULL,
    until_date DATE NOT NULL,
    window_days INT NOT NULL,
    max_windows_per_run INT NOT NULL DEFAULT 1,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw_articles (
    id BIGSERIAL PRIMARY KEY,
    source_name VARCHAR(100) NOT NULL,
    title VARCHAR(500) NOT NULL,
    content TEXT,
    url TEXT NOT NULL UNIQUE,
    published_at TIMESTAMPTZ,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    cluster_id BIGINT,
    is_representative BOOLEAN,
    processing_status VARCHAR(40) NOT NULL DEFAULT 'RAW',
    importance_score FLOAT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    source_type VARCHAR(50) NOT NULL DEFAULT 'news',
    publisher VARCHAR(150),
    url_hash VARCHAR(32) NOT NULL,
    company JSONB NOT NULL DEFAULT '[]'::jsonb,
    language VARCHAR(10) NOT NULL DEFAULT 'ko',
    content_type VARCHAR(30) NOT NULL DEFAULT 'news',
    crawl_status VARCHAR(20) NOT NULL DEFAULT 'success',
    error_message TEXT,
    relevance_score FLOAT,
    relevance_label VARCHAR(20),
    relevance_reason TEXT,
    matched_companies JSONB NOT NULL DEFAULT '[]'::jsonb,
    matched_sectors JSONB NOT NULL DEFAULT '[]'::jsonb,
    importance_level VARCHAR(20),
    qdrant_vector_id UUID,
    crawl_run_id UUID,
    peer_company_ids TEXT[] NOT NULL DEFAULT '{}',
    peer_company_links JSONB NOT NULL DEFAULT '[]'::jsonb,
    financial_metrics JSONB NOT NULL DEFAULT '[]'::jsonb,
    business_signals JSONB NOT NULL DEFAULT '[]'::jsonb,
    crawl_events JSONB NOT NULL DEFAULT '[]'::jsonb,
    legacy_payload JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_raw_articles_url_hash ON raw_articles(url_hash);
CREATE INDEX IF NOT EXISTS idx_raw_articles_source_type ON raw_articles(source_type);
CREATE INDEX IF NOT EXISTS idx_raw_articles_published_at ON raw_articles(published_at);
CREATE INDEX IF NOT EXISTS idx_raw_articles_processing_status ON raw_articles(processing_status);
CREATE INDEX IF NOT EXISTS idx_raw_articles_company ON raw_articles USING GIN(company);
CREATE INDEX IF NOT EXISTS idx_raw_articles_matched_companies ON raw_articles USING GIN(matched_companies);
CREATE INDEX IF NOT EXISTS idx_raw_articles_peer_company_ids ON raw_articles USING GIN(peer_company_ids);

CREATE TABLE IF NOT EXISTS raw_article_source_metadata (
    raw_article_id BIGINT PRIMARY KEY REFERENCES raw_articles(id) ON DELETE CASCADE,
    source_type VARCHAR(50) NOT NULL,
    source_name VARCHAR(100),
    source_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    external_id TEXT,
    period TEXT,
    document_url TEXT,
    company_name TEXT,
    parser_quality_label TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_raw_article_source_metadata_source
    ON raw_article_source_metadata(source_type, source_name);
CREATE INDEX IF NOT EXISTS idx_raw_article_source_metadata_gin
    ON raw_article_source_metadata USING GIN(source_metadata);

CREATE TABLE IF NOT EXISTS raw_article_parse_results (
    raw_article_id BIGINT PRIMARY KEY REFERENCES raw_articles(id) ON DELETE CASCADE,
    parser_version TEXT,
    parse_status TEXT,
    parser_quality_label TEXT,
    parser_result JSONB NOT NULL DEFAULT '{}'::jsonb,
    financial_record JSONB NOT NULL DEFAULT '{}'::jsonb,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    warnings JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS card_news (
    id VARCHAR(50) PRIMARY KEY,
    company VARCHAR(50) NOT NULL,
    peer_company_id VARCHAR(50) REFERENCES peer_companies(id),
    cluster_id BIGINT,
    title VARCHAR(500) NOT NULL,
    summary_lines TEXT[] NOT NULL DEFAULT '{}',
    event_type VARCHAR(50) DEFAULT 'tech',
    importance VARCHAR(20) DEFAULT 'low',
    importance_score FLOAT DEFAULT 0.0,
    implication JSONB NOT NULL DEFAULT '{}'::jsonb,
    sources JSONB NOT NULL DEFAULT '[]'::jsonb,
    primary_keyword_category VARCHAR(80),
    keyword_categories JSONB NOT NULL DEFAULT '[]'::jsonb,
    keywords TEXT[] NOT NULL DEFAULT '{}',
    keyword_frequency JSONB NOT NULL DEFAULT '{}'::jsonb,
    source_raw_article_ids BIGINT[] NOT NULL DEFAULT '{}',
    source_articles JSONB NOT NULL DEFAULT '[]'::jsonb,
    evidence_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    image_assets JSONB NOT NULL DEFAULT '[]'::jsonb,
    legacy_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    validation_pass BOOLEAN DEFAULT FALSE,
    validation_sc_score FLOAT DEFAULT 0.0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_card_news_peer_company_id ON card_news(peer_company_id);
CREATE INDEX IF NOT EXISTS idx_card_news_importance ON card_news(importance, importance_score DESC);
CREATE INDEX IF NOT EXISTS idx_card_news_keywords ON card_news USING GIN(keywords);
CREATE INDEX IF NOT EXISTS idx_card_news_keyword_categories ON card_news USING GIN(keyword_categories);
CREATE INDEX IF NOT EXISTS idx_card_news_source_raw_article_ids ON card_news USING GIN(source_raw_article_ids);

CREATE OR REPLACE VIEW issue_cards AS SELECT * FROM card_news;

CREATE TABLE IF NOT EXISTS market_price_ohlcv (
    id BIGSERIAL PRIMARY KEY,
    raw_article_id BIGINT REFERENCES raw_articles(id) ON DELETE SET NULL,
    instrument_id BIGINT,
    peer_id TEXT,
    peer_company_id VARCHAR(50) REFERENCES peer_companies(id) ON DELETE SET NULL,
    ticker TEXT NOT NULL,
    exchange VARCHAR(20) NOT NULL DEFAULT 'KRX',
    instrument_name VARCHAR(100),
    trade_date DATE NOT NULL,
    open NUMERIC,
    high NUMERIC,
    low NUMERIC,
    close NUMERIC,
    volume BIGINT,
    change_pct NUMERIC,
    currency TEXT DEFAULT 'KRW',
    source_type TEXT NOT NULL DEFAULT 'market_data',
    source_name TEXT,
    publisher TEXT,
    collected_at TIMESTAMPTZ,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    instrument_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_market_price_ohlcv_ticker_date_source UNIQUE (ticker, trade_date, source_name)
);

CREATE INDEX IF NOT EXISTS idx_market_price_ohlcv_ticker_date
    ON market_price_ohlcv(ticker, trade_date DESC);
CREATE INDEX IF NOT EXISTS idx_market_price_ohlcv_peer_company_date
    ON market_price_ohlcv(peer_company_id, trade_date DESC)
    WHERE peer_company_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_market_price_ohlcv_exchange_ticker_date
    ON market_price_ohlcv(exchange, ticker, trade_date DESC);

CREATE TABLE IF NOT EXISTS briefing_reports (
    id VARCHAR(40) PRIMARY KEY,
    title VARCHAR(500) NOT NULL,
    briefing_type VARCHAR(20) NOT NULL,
    date_from DATE NOT NULL,
    date_to DATE NOT NULL,
    report_date DATE,
    period_label TEXT,
    requested_by_user_id BIGINT,
    status VARCHAR(20) NOT NULL DEFAULT 'queued',
    progress NUMERIC(3,2) NOT NULL DEFAULT 0.0,
    key_summary TEXT,
    sk_implication TEXT,
    related_card_ids TEXT[] NOT NULL DEFAULT '{}',
    related_raw_article_ids BIGINT[] NOT NULL DEFAULT '{}',
    recipients JSONB NOT NULL DEFAULT '[]'::jsonb,
    delivery_history JSONB NOT NULL DEFAULT '[]'::jsonb,
    payload JSONB,
    legacy_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_message TEXT,
    confidence NUMERIC(3,2),
    provenance JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    CONSTRAINT briefing_reports_status_check
        CHECK (status IN ('queued', 'running', 'completed', 'completed_partial', 'failed')),
    CONSTRAINT briefing_reports_type_check
        CHECK (briefing_type IN ('daily', 'weekly', 'custom')),
    CONSTRAINT briefing_reports_date_order CHECK (date_from <= date_to)
);

CREATE INDEX IF NOT EXISTS idx_briefing_status ON briefing_reports(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_briefing_date_range ON briefing_reports(date_from, date_to);
CREATE INDEX IF NOT EXISTS idx_briefing_related_cards ON briefing_reports USING GIN(related_card_ids);

CREATE TABLE IF NOT EXISTS mixer_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_analysis_id VARCHAR(100),
    title VARCHAR(300),
    requested_by_user_id BIGINT,
    input_card_ids TEXT[] NOT NULL DEFAULT '{}',
    input_peer_ids TEXT[] NOT NULL DEFAULT '{}',
    input_keywords TEXT[] NOT NULL DEFAULT '{}',
    ratios JSONB NOT NULL DEFAULT '{}'::jsonb,
    generated_implication JSONB NOT NULL DEFAULT '{}'::jsonb,
    insight_brief JSONB NOT NULL DEFAULT '[]'::jsonb,
    radar_axes JSONB NOT NULL DEFAULT '[]'::jsonb,
    connections JSONB NOT NULL DEFAULT '[]'::jsonb,
    sk_ax_implication TEXT,
    final_one_liner TEXT,
    confidence NUMERIC(3,2),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_mixer_results_source_analysis_id
    ON mixer_results(source_analysis_id) WHERE source_analysis_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mixer_results_created_at ON mixer_results(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mixer_results_input_cards ON mixer_results USING GIN(input_card_ids);

CREATE TABLE IF NOT EXISTS insight_reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_analysis_id VARCHAR(100),
    title VARCHAR(300),
    insight_type VARCHAR(40) NOT NULL DEFAULT 'cascade',
    status VARCHAR(30) NOT NULL DEFAULT 'completed',
    requested_by_user_id BIGINT,
    focus_peer_ids TEXT[] NOT NULL DEFAULT '{}',
    focus_card_ids TEXT[] NOT NULL DEFAULT '{}',
    focus_keywords TEXT[] NOT NULL DEFAULT '{}',
    date_from DATE,
    date_to DATE,
    summary TEXT,
    final_one_liner TEXT,
    sk_ax_implication TEXT,
    reasoning_steps JSONB NOT NULL DEFAULT '[]'::jsonb,
    evidence JSONB NOT NULL DEFAULT '[]'::jsonb,
    source_card_ids TEXT[] NOT NULL DEFAULT '{}',
    confidence NUMERIC(3,2),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_insight_reports_source_analysis_id
    ON insight_reports(source_analysis_id) WHERE source_analysis_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_insight_reports_created_at ON insight_reports(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_insight_reports_focus_peers ON insight_reports USING GIN(focus_peer_ids);

CREATE TABLE IF NOT EXISTS global_industry_trends (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_analysis_id VARCHAR(100),
    trend_date DATE NOT NULL DEFAULT CURRENT_DATE,
    industry VARCHAR(100) NOT NULL,
    region VARCHAR(50) NOT NULL DEFAULT 'global',
    keyword VARCHAR(120) NOT NULL,
    keyword_category VARCHAR(80),
    title VARCHAR(300),
    summary TEXT,
    mention_count INT NOT NULL DEFAULT 0,
    impact_score NUMERIC(5,2),
    confidence NUMERIC(3,2),
    related_peer_ids TEXT[] NOT NULL DEFAULT '{}',
    related_card_ids TEXT[] NOT NULL DEFAULT '{}',
    source_raw_article_ids BIGINT[] NOT NULL DEFAULT '{}',
    sk_ax_implication TEXT,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_global_industry_trends_daily_keyword
        UNIQUE (trend_date, industry, region, keyword)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_global_industry_trends_source_analysis_id
    ON global_industry_trends(source_analysis_id) WHERE source_analysis_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_global_industry_trends_date ON global_industry_trends(trend_date DESC);
CREATE INDEX IF NOT EXISTS idx_global_industry_trends_keyword ON global_industry_trends(keyword);

CREATE TABLE IF NOT EXISTS legacy_records (
    id BIGSERIAL PRIMARY KEY,
    source_table VARCHAR(100) NOT NULL,
    source_pk TEXT,
    owner_table VARCHAR(100),
    owner_id TEXT,
    payload JSONB NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_legacy_records_source_pk
    ON legacy_records(source_table, source_pk)
    WHERE source_pk IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_legacy_records_source
    ON legacy_records(source_table, archived_at DESC);
CREATE INDEX IF NOT EXISTS idx_legacy_records_owner
    ON legacy_records(owner_table, owner_id)
    WHERE owner_table IS NOT NULL;

CREATE OR REPLACE VIEW raw_article_metadata_unified AS
SELECT
    ra.id AS raw_article_id,
    ra.source_type,
    ra.source_name,
    ra.metadata AS common_metadata,
    COALESCE(rasm.source_metadata, '{}'::jsonb) AS source_metadata,
    ra.metadata || COALESCE(rasm.source_metadata, '{}'::jsonb) AS metadata
FROM raw_articles ra
LEFT JOIN raw_article_source_metadata rasm
    ON rasm.raw_article_id = ra.id;

COMMENT ON TABLE legacy_records IS
    'Row-level archive for V30-collapsed tables. Not part of the product ERD.';
