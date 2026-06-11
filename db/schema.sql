-- AXIS crawler/parser-aware product schema snapshot
-- Snapshot date: 2026-06-11 KST
-- Migration baseline: backend Flyway V44 (V40 integrated issue storage + V41~V44 read-model/seed additions).
--
-- Physical app tables after V32:
--   peer_companies, raw_articles, raw_article_parse_results,
--   raw_article_financial_metrics, raw_article_business_signals,
--   integrated_issues, integrated_issue_source_articles,
--   integrated_issue_content_sections, integrated_issue_evidence_references,
--   card_news, market_price_ohlcv, briefing_reports, mixer_results,
--   insight_reports, global_industry_trends, crawl_cursors, crawl_runs,
--   crawl_run_articles, legacy_records.
-- Additional auth/admin tables:
--   users, auth_tokens, user_settings, user_card_news_bookmarks,
--   user_notifications, user_access_logs, admin_audit_logs.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

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

CREATE TABLE IF NOT EXISTS crawl_runs (
    id UUID PRIMARY KEY,
    run_type VARCHAR(30) NOT NULL,
    source_name VARCHAR(100) NOT NULL,
    window_start DATE NOT NULL,
    window_end DATE NOT NULL,
    status VARCHAR(30) NOT NULL,
    inserted_count INT NOT NULL DEFAULT 0,
    skipped_count INT NOT NULL DEFAULT 0,
    error_message TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_crawl_runs_source_started
    ON crawl_runs(source_name, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_crawl_runs_status ON crawl_runs(status);
CREATE INDEX IF NOT EXISTS idx_crawl_runs_window ON crawl_runs(window_start, window_end);

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
    crawl_run_id UUID REFERENCES crawl_runs(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_raw_articles_url_hash ON raw_articles(url_hash);
CREATE INDEX IF NOT EXISTS idx_raw_articles_source_type ON raw_articles(source_type);
CREATE INDEX IF NOT EXISTS idx_raw_articles_published_at ON raw_articles(published_at);
CREATE INDEX IF NOT EXISTS idx_raw_articles_processing_status ON raw_articles(processing_status);
CREATE INDEX IF NOT EXISTS idx_raw_articles_company ON raw_articles USING GIN(company);
CREATE INDEX IF NOT EXISTS idx_raw_articles_matched_companies ON raw_articles USING GIN(matched_companies);

CREATE TABLE IF NOT EXISTS crawl_run_articles (
    id BIGSERIAL PRIMARY KEY,
    crawl_run_id UUID NOT NULL REFERENCES crawl_runs(id) ON DELETE CASCADE,
    raw_article_id BIGINT REFERENCES raw_articles(id) ON DELETE SET NULL,
    url TEXT NOT NULL,
    url_hash VARCHAR(32) NOT NULL,
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    action VARCHAR(30) NOT NULL,
    fetch_status VARCHAR(30),
    error_message TEXT,
    source_rank INT,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_crawl_run_articles_run_url UNIQUE (crawl_run_id, url_hash)
);

CREATE INDEX IF NOT EXISTS idx_crawl_run_articles_run
    ON crawl_run_articles(crawl_run_id);
CREATE INDEX IF NOT EXISTS idx_crawl_run_articles_article
    ON crawl_run_articles(raw_article_id);
CREATE INDEX IF NOT EXISTS idx_crawl_run_articles_action
    ON crawl_run_articles(action);
CREATE INDEX IF NOT EXISTS idx_crawl_run_articles_url_hash
    ON crawl_run_articles(url_hash);

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

CREATE TABLE IF NOT EXISTS raw_article_financial_metrics (
    id BIGSERIAL PRIMARY KEY,
    raw_article_id BIGINT NOT NULL REFERENCES raw_articles(id) ON DELETE CASCADE,
    metric_uid TEXT NOT NULL,
    source_type VARCHAR(50) NOT NULL,
    source_name VARCHAR(100),
    peer_id VARCHAR(50),
    period TEXT,
    period_year INT,
    period_quarter INT,
    period_type TEXT,
    metric_name TEXT NOT NULL,
    metric_label TEXT,
    metric_scope TEXT,
    business_area TEXT,
    value_numeric NUMERIC(24, 6),
    value_krwbn DOUBLE PRECISION,
    value_krw NUMERIC(24, 2),
    unit TEXT,
    currency VARCHAR(10) DEFAULT 'KRW',
    source_page INT,
    source_table_uid TEXT,
    source_chunk_uid TEXT,
    confidence DOUBLE PRECISION,
    extraction_method TEXT,
    evidence_text TEXT,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_raw_article_financial_metric UNIQUE (raw_article_id, metric_uid),
    CONSTRAINT chk_raw_article_financial_metrics_confidence
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1))
);

CREATE INDEX IF NOT EXISTS idx_raw_article_financial_metrics_peer_period
    ON raw_article_financial_metrics(peer_id, period);
CREATE INDEX IF NOT EXISTS idx_raw_article_financial_metrics_metric
    ON raw_article_financial_metrics(metric_name, period);
CREATE INDEX IF NOT EXISTS idx_raw_article_financial_metrics_source
    ON raw_article_financial_metrics(source_type, source_name);
CREATE INDEX IF NOT EXISTS idx_raw_article_financial_metrics_payload_gin
    ON raw_article_financial_metrics USING GIN(payload);

CREATE TABLE IF NOT EXISTS raw_article_business_signals (
    id BIGSERIAL PRIMARY KEY,
    raw_article_id BIGINT NOT NULL REFERENCES raw_articles(id) ON DELETE CASCADE,
    signal_uid TEXT NOT NULL,
    source_type VARCHAR(50) NOT NULL,
    source_name VARCHAR(100),
    peer_id VARCHAR(50),
    period TEXT,
    period_year INT,
    period_quarter INT,
    period_type TEXT,
    business_area TEXT NOT NULL,
    signal_type TEXT NOT NULL,
    sentiment TEXT,
    summary TEXT NOT NULL,
    evidence_text TEXT,
    source_page INT,
    source_chunk_uid TEXT,
    confidence DOUBLE PRECISION,
    extraction_method TEXT,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_raw_article_business_signal UNIQUE (raw_article_id, signal_uid),
    CONSTRAINT chk_raw_article_business_signals_confidence
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    CONSTRAINT chk_raw_article_business_signals_sentiment
        CHECK (
            sentiment IS NULL
            OR sentiment IN ('positive', 'neutral', 'negative', 'mixed', 'unknown')
        )
);

CREATE INDEX IF NOT EXISTS idx_raw_article_business_signals_peer_period
    ON raw_article_business_signals(peer_id, period);
CREATE INDEX IF NOT EXISTS idx_raw_article_business_signals_area_type
    ON raw_article_business_signals(business_area, signal_type);
CREATE INDEX IF NOT EXISTS idx_raw_article_business_signals_source
    ON raw_article_business_signals(source_type, source_name);
CREATE INDEX IF NOT EXISTS idx_raw_article_business_signals_payload_gin
    ON raw_article_business_signals USING GIN(payload);

CREATE TABLE IF NOT EXISTS integrated_issues (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    schema_version VARCHAR(40) NOT NULL DEFAULT 'integrated_issue_v3',
    issue_key VARCHAR(160) NOT NULL,
    cluster_id BIGINT,
    representative_raw_article_id BIGINT REFERENCES raw_articles(id) ON DELETE SET NULL,
    main_company VARCHAR(80),
    event_type VARCHAR(80),
    source_family VARCHAR(40),
    scope_type VARCHAR(40),
    is_valid BOOLEAN NOT NULL DEFAULT FALSE,
    confidence DOUBLE PRECISION,
    status VARCHAR(30) NOT NULL DEFAULT 'active',
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    superseded_by UUID REFERENCES integrated_issues(id) ON DELETE SET NULL,
    headline TEXT,
    one_line_summary TEXT,
    analyzed_source_ids BIGINT[] NOT NULL DEFAULT '{}',
    source_ids BIGINT[] NOT NULL DEFAULT '{}',
    sectors TEXT[] NOT NULL DEFAULT '{}',
    mentioned_peer_companies TEXT[] NOT NULL DEFAULT '{}',
    content_summary TEXT,
    content_detailed_explanation TEXT,
    content_has_content BOOLEAN NOT NULL DEFAULT FALSE,
    content_compression_method VARCHAR(80),
    content_basis_scope VARCHAR(80),
    content_source_count INT NOT NULL DEFAULT 0,
    content_section_count INT NOT NULL DEFAULT 0,
    issue_brief JSONB NOT NULL DEFAULT '{}'::jsonb,
    analysis_ready_inputs JSONB NOT NULL DEFAULT '{}'::jsonb,
    content_digest JSONB NOT NULL DEFAULT '{}'::jsonb,
    issue_frame JSONB NOT NULL DEFAULT '{}'::jsonb,
    sources JSONB NOT NULL DEFAULT '[]'::jsonb,
    evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
    quality JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    payload_hash VARCHAR(64),
    global_search_text TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_integrated_issues_confidence
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    CONSTRAINT chk_integrated_issues_status
        CHECK (status IN ('active', 'superseded', 'failed', 'review')),
    CONSTRAINT chk_integrated_issues_content_counts
        CHECK (content_source_count >= 0 AND content_section_count >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_integrated_issues_current_issue_key
    ON integrated_issues(schema_version, issue_key)
    WHERE is_current = TRUE;
CREATE INDEX IF NOT EXISTS idx_integrated_issues_cluster_current
    ON integrated_issues(cluster_id, is_current, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_representative
    ON integrated_issues(representative_raw_article_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_company_event
    ON integrated_issues(main_company, event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_valid_current
    ON integrated_issues(is_valid, is_current, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_analyzed_sources
    ON integrated_issues USING GIN(analyzed_source_ids);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_source_ids
    ON integrated_issues USING GIN(source_ids);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_sectors
    ON integrated_issues USING GIN(sectors);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_peer_companies
    ON integrated_issues USING GIN(mentioned_peer_companies);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_payload_gin
    ON integrated_issues USING GIN(payload);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_content_digest_gin
    ON integrated_issues USING GIN(content_digest);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_issue_frame_gin
    ON integrated_issues USING GIN(issue_frame);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_evidence_gin
    ON integrated_issues USING GIN(evidence);
CREATE INDEX IF NOT EXISTS idx_integrated_issues_global_search_trgm
    ON integrated_issues USING GIN(global_search_text gin_trgm_ops);

CREATE TABLE IF NOT EXISTS integrated_issue_source_articles (
    id BIGSERIAL PRIMARY KEY,
    integrated_issue_id UUID NOT NULL REFERENCES integrated_issues(id) ON DELETE CASCADE,
    raw_article_id BIGINT REFERENCES raw_articles(id) ON DELETE SET NULL,
    source_order INT NOT NULL DEFAULT 0,
    is_analyzed_basis BOOLEAN NOT NULL DEFAULT FALSE,
    title TEXT,
    source_name VARCHAR(100),
    source_type VARCHAR(50),
    publisher VARCHAR(150),
    published_at TIMESTAMPTZ,
    url TEXT,
    relevance_label VARCHAR(30),
    relevance_score DOUBLE PRECISION,
    source_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_integrated_issue_source_article
        UNIQUE (integrated_issue_id, raw_article_id),
    CONSTRAINT chk_integrated_issue_source_relevance_score
        CHECK (relevance_score IS NULL OR (relevance_score >= 0 AND relevance_score <= 1))
);

CREATE INDEX IF NOT EXISTS idx_integrated_issue_sources_issue_order
    ON integrated_issue_source_articles(integrated_issue_id, source_order);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sources_raw_article
    ON integrated_issue_source_articles(raw_article_id);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sources_basis
    ON integrated_issue_source_articles(integrated_issue_id, is_analyzed_basis);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sources_payload_gin
    ON integrated_issue_source_articles USING GIN(source_payload);

CREATE TABLE IF NOT EXISTS integrated_issue_content_sections (
    id BIGSERIAL PRIMARY KEY,
    integrated_issue_id UUID NOT NULL REFERENCES integrated_issues(id) ON DELETE CASCADE,
    section_key VARCHAR(80) NOT NULL,
    section_order INT NOT NULL DEFAULT 0,
    title TEXT,
    summary TEXT,
    details TEXT,
    key_points TEXT[] NOT NULL DEFAULT '{}',
    raw_article_ids BIGINT[] NOT NULL DEFAULT '{}',
    evidence_ref_ids TEXT[] NOT NULL DEFAULT '{}',
    section_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_integrated_issue_content_section
        UNIQUE (integrated_issue_id, section_key)
);

CREATE INDEX IF NOT EXISTS idx_integrated_issue_sections_issue_order
    ON integrated_issue_content_sections(integrated_issue_id, section_order);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sections_key
    ON integrated_issue_content_sections(section_key);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sections_raw_articles
    ON integrated_issue_content_sections USING GIN(raw_article_ids);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sections_evidence_refs
    ON integrated_issue_content_sections USING GIN(evidence_ref_ids);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_sections_payload_gin
    ON integrated_issue_content_sections USING GIN(section_payload);

CREATE TABLE IF NOT EXISTS integrated_issue_evidence_references (
    id BIGSERIAL PRIMARY KEY,
    integrated_issue_id UUID NOT NULL REFERENCES integrated_issues(id) ON DELETE CASCADE,
    evidence_ref_id VARCHAR(40) NOT NULL,
    evidence_text TEXT NOT NULL,
    source_ids BIGINT[] NOT NULL DEFAULT '{}',
    reference_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_integrated_issue_evidence_ref
        UNIQUE (integrated_issue_id, evidence_ref_id)
);

CREATE INDEX IF NOT EXISTS idx_integrated_issue_evidence_issue
    ON integrated_issue_evidence_references(integrated_issue_id);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_evidence_source_ids
    ON integrated_issue_evidence_references USING GIN(source_ids);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_evidence_text_trgm
    ON integrated_issue_evidence_references USING GIN(evidence_text gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_integrated_issue_evidence_payload_gin
    ON integrated_issue_evidence_references USING GIN(reference_payload);

CREATE TABLE IF NOT EXISTS card_news (
    id VARCHAR(50) PRIMARY KEY,
    company VARCHAR(50) NOT NULL,
    peer_company_id VARCHAR(50) REFERENCES peer_companies(id),
    cluster_id BIGINT,
    integrated_issue_id UUID REFERENCES integrated_issues(id) ON DELETE SET NULL,
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
    primary_raw_article_id BIGINT REFERENCES raw_articles(id) ON DELETE SET NULL,
    source_articles JSONB NOT NULL DEFAULT '[]'::jsonb,
    evidence_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    image_assets JSONB NOT NULL DEFAULT '[]'::jsonb,
    legacy_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    validation_pass BOOLEAN DEFAULT FALSE,
    validation_sc_score FLOAT DEFAULT 0.0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT chk_card_news_status
        CHECK (status IN ('ACTIVE', 'PENDING', 'DELETED')),
    CONSTRAINT chk_card_news_primary_raw_article_in_sources
        CHECK (
            primary_raw_article_id IS NULL
            OR cardinality(COALESCE(source_raw_article_ids, '{}'::bigint[])) = 0
            OR primary_raw_article_id = ANY(source_raw_article_ids)
        )
);

CREATE INDEX IF NOT EXISTS idx_card_news_peer_company_id ON card_news(peer_company_id);
CREATE INDEX IF NOT EXISTS idx_card_news_status_created_at ON card_news(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_card_news_importance ON card_news(importance, importance_score DESC);
CREATE INDEX IF NOT EXISTS idx_card_news_keywords ON card_news USING GIN(keywords);
CREATE INDEX IF NOT EXISTS idx_card_news_keyword_categories ON card_news USING GIN(keyword_categories);
CREATE INDEX IF NOT EXISTS idx_card_news_source_raw_article_ids ON card_news USING GIN(source_raw_article_ids);
CREATE INDEX IF NOT EXISTS idx_card_news_primary_raw_article
    ON card_news(primary_raw_article_id)
    WHERE primary_raw_article_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_card_news_integrated_issue
    ON card_news(integrated_issue_id)
    WHERE integrated_issue_id IS NOT NULL;

CREATE OR REPLACE VIEW issue_cards AS SELECT * FROM card_news;

CREATE TABLE IF NOT EXISTS admin_audit_logs (
    id BIGSERIAL PRIMARY KEY,
    actor_user_id UUID,
    actor_email VARCHAR(320) NOT NULL,
    action_type VARCHAR(80) NOT NULL,
    resource_type VARCHAR(40) NOT NULL,
    resource_id VARCHAR(80) NOT NULL,
    reason TEXT,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_created_at
    ON admin_audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_resource
    ON admin_audit_logs(resource_type, resource_id, created_at DESC);

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
    primary_card_news_id VARCHAR(50) REFERENCES card_news(id) ON DELETE SET NULL,
    primary_peer_company_id VARCHAR(50) REFERENCES peer_companies(id) ON DELETE SET NULL,
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
        CHECK (briefing_type IN ('daily', 'weekly', 'monthly', 'custom')),
    CONSTRAINT briefing_reports_date_order CHECK (date_from <= date_to),
    CONSTRAINT chk_briefing_reports_primary_card_in_related
        CHECK (
            primary_card_news_id IS NULL
            OR cardinality(COALESCE(related_card_ids, '{}'::text[])) = 0
            OR primary_card_news_id = ANY(related_card_ids)
        )
);

CREATE INDEX IF NOT EXISTS idx_briefing_status ON briefing_reports(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_briefing_date_range ON briefing_reports(date_from, date_to);
CREATE INDEX IF NOT EXISTS idx_briefing_related_cards ON briefing_reports USING GIN(related_card_ids);
CREATE INDEX IF NOT EXISTS idx_briefing_reports_primary_card_news
    ON briefing_reports(primary_card_news_id)
    WHERE primary_card_news_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_briefing_reports_primary_peer_company
    ON briefing_reports(primary_peer_company_id)
    WHERE primary_peer_company_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS mixer_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_analysis_id VARCHAR(100),
    title VARCHAR(300),
    requested_by_user_id BIGINT,
    input_card_ids TEXT[] NOT NULL DEFAULT '{}',
    primary_card_news_id VARCHAR(50) REFERENCES card_news(id) ON DELETE SET NULL,
    input_peer_ids TEXT[] NOT NULL DEFAULT '{}',
    primary_peer_company_id VARCHAR(50) REFERENCES peer_companies(id) ON DELETE SET NULL,
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
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_mixer_results_primary_card_in_inputs
        CHECK (
            primary_card_news_id IS NULL
            OR cardinality(COALESCE(input_card_ids, '{}'::text[])) = 0
            OR primary_card_news_id = ANY(input_card_ids)
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_mixer_results_source_analysis_id
    ON mixer_results(source_analysis_id) WHERE source_analysis_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mixer_results_created_at ON mixer_results(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_mixer_results_input_cards ON mixer_results USING GIN(input_card_ids);
CREATE INDEX IF NOT EXISTS idx_mixer_results_primary_card_news
    ON mixer_results(primary_card_news_id)
    WHERE primary_card_news_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mixer_results_primary_peer_company
    ON mixer_results(primary_peer_company_id)
    WHERE primary_peer_company_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS insight_reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_analysis_id VARCHAR(100),
    title VARCHAR(300),
    insight_type VARCHAR(40) NOT NULL DEFAULT 'cascade',
    status VARCHAR(30) NOT NULL DEFAULT 'completed',
    requested_by_user_id BIGINT,
    focus_peer_ids TEXT[] NOT NULL DEFAULT '{}',
    primary_peer_company_id VARCHAR(50) REFERENCES peer_companies(id) ON DELETE SET NULL,
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
    primary_card_news_id VARCHAR(50) REFERENCES card_news(id) ON DELETE SET NULL,
    confidence NUMERIC(3,2),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_insight_reports_primary_card_in_sources
        CHECK (
            primary_card_news_id IS NULL
            OR (
                cardinality(COALESCE(source_card_ids, '{}'::text[]))
                + cardinality(COALESCE(focus_card_ids, '{}'::text[]))
            ) = 0
            OR primary_card_news_id = ANY(source_card_ids)
            OR primary_card_news_id = ANY(focus_card_ids)
        )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_insight_reports_source_analysis_id
    ON insight_reports(source_analysis_id) WHERE source_analysis_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_insight_reports_created_at ON insight_reports(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_insight_reports_focus_peers ON insight_reports USING GIN(focus_peer_ids);
CREATE INDEX IF NOT EXISTS idx_insight_reports_primary_card_news
    ON insight_reports(primary_card_news_id)
    WHERE primary_card_news_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_insight_reports_primary_peer_company
    ON insight_reports(primary_peer_company_id)
    WHERE primary_peer_company_id IS NOT NULL;

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
    '{}'::jsonb AS source_metadata,
    ra.metadata AS metadata
FROM raw_articles ra;

CREATE OR REPLACE FUNCTION axis_refresh_integrated_issue_global_search_text()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.global_search_text := concat_ws(
        ' ',
        NEW.headline,
        NEW.one_line_summary,
        NEW.main_company,
        NEW.event_type,
        NEW.source_family,
        NEW.scope_type,
        NEW.content_summary,
        NEW.content_detailed_explanation,
        array_to_string(NEW.sectors, ' '),
        array_to_string(NEW.mentioned_peer_companies, ' '),
        NEW.issue_frame::text,
        NEW.content_digest::text,
        NEW.evidence::text
    );
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION axis_first_existing_raw_article_id(candidate_ids BIGINT[])
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT ra.id
    FROM unnest(COALESCE(candidate_ids, '{}'::bigint[]))
        WITH ORDINALITY AS candidate(raw_article_id, sort_order)
    JOIN raw_articles ra
        ON ra.id = candidate.raw_article_id
    ORDER BY candidate.sort_order
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION axis_first_existing_card_news_id(candidate_ids TEXT[])
RETURNS VARCHAR(50)
LANGUAGE sql
STABLE
AS $$
    SELECT cn.id
    FROM unnest(COALESCE(candidate_ids, '{}'::text[]))
        WITH ORDINALITY AS candidate(card_news_id, sort_order)
    JOIN card_news cn
        ON cn.id = candidate.card_news_id
    ORDER BY candidate.sort_order
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION axis_first_existing_peer_company_id(
    candidate_peer_ids TEXT[],
    candidate_card_news_ids TEXT[]
)
RETURNS VARCHAR(50)
LANGUAGE sql
STABLE
AS $$
    WITH candidates AS (
        SELECT
            candidate.peer_company_id,
            0 AS source_order,
            candidate.sort_order
        FROM unnest(COALESCE(candidate_peer_ids, '{}'::text[]))
            WITH ORDINALITY AS candidate(peer_company_id, sort_order)
        WHERE candidate.peer_company_id IS NOT NULL
          AND candidate.peer_company_id <> ''

        UNION ALL

        SELECT
            COALESCE(cn.peer_company_id, cn.company) AS peer_company_id,
            1 AS source_order,
            candidate.sort_order
        FROM unnest(COALESCE(candidate_card_news_ids, '{}'::text[]))
            WITH ORDINALITY AS candidate(card_news_id, sort_order)
        JOIN card_news cn
            ON cn.id = candidate.card_news_id
        WHERE COALESCE(cn.peer_company_id, cn.company) IS NOT NULL
          AND COALESCE(cn.peer_company_id, cn.company) <> ''
    )
    SELECT pc.id
    FROM candidates
    JOIN peer_companies pc
        ON pc.id = candidates.peer_company_id
    ORDER BY candidates.source_order, candidates.sort_order
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION axis_set_card_news_primary_refs()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.primary_raw_article_id IS NULL
       OR (
            cardinality(COALESCE(NEW.source_raw_article_ids, '{}'::bigint[])) > 0
            AND NOT NEW.primary_raw_article_id = ANY(NEW.source_raw_article_ids)
       ) THEN
        NEW.primary_raw_article_id := axis_first_existing_raw_article_id(NEW.source_raw_article_ids);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION axis_set_briefing_report_primary_refs()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.primary_card_news_id IS NULL
       OR (
            cardinality(COALESCE(NEW.related_card_ids, '{}'::text[])) > 0
            AND NOT NEW.primary_card_news_id = ANY(NEW.related_card_ids)
       ) THEN
        NEW.primary_card_news_id := axis_first_existing_card_news_id(NEW.related_card_ids);
    END IF;

    IF NEW.primary_peer_company_id IS NULL THEN
        NEW.primary_peer_company_id :=
            axis_first_existing_peer_company_id('{}'::text[], NEW.related_card_ids);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION axis_set_mixer_result_primary_refs()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.primary_card_news_id IS NULL
       OR (
            cardinality(COALESCE(NEW.input_card_ids, '{}'::text[])) > 0
            AND NOT NEW.primary_card_news_id = ANY(NEW.input_card_ids)
       ) THEN
        NEW.primary_card_news_id := axis_first_existing_card_news_id(NEW.input_card_ids);
    END IF;

    IF NEW.primary_peer_company_id IS NULL
       OR (
            cardinality(COALESCE(NEW.input_peer_ids, '{}'::text[])) > 0
            AND NOT NEW.primary_peer_company_id = ANY(NEW.input_peer_ids)
       ) THEN
        NEW.primary_peer_company_id :=
            axis_first_existing_peer_company_id(NEW.input_peer_ids, NEW.input_card_ids);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION axis_set_insight_report_primary_refs()
RETURNS TRIGGER AS $$
DECLARE
    candidate_card_ids TEXT[];
BEGIN
    candidate_card_ids :=
        COALESCE(NEW.source_card_ids, '{}'::text[])
        || COALESCE(NEW.focus_card_ids, '{}'::text[]);

    IF NEW.primary_card_news_id IS NULL
       OR (
            cardinality(candidate_card_ids) > 0
            AND NOT NEW.primary_card_news_id = ANY(candidate_card_ids)
       ) THEN
        NEW.primary_card_news_id := axis_first_existing_card_news_id(candidate_card_ids);
    END IF;

    IF NEW.primary_peer_company_id IS NULL
       OR (
            cardinality(COALESCE(NEW.focus_peer_ids, '{}'::text[])) > 0
            AND NOT NEW.primary_peer_company_id = ANY(NEW.focus_peer_ids)
       ) THEN
        NEW.primary_peer_company_id :=
            axis_first_existing_peer_company_id(NEW.focus_peer_ids, candidate_card_ids);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_card_news_primary_refs
BEFORE INSERT OR UPDATE OF source_raw_article_ids, primary_raw_article_id ON card_news
FOR EACH ROW
EXECUTE FUNCTION axis_set_card_news_primary_refs();

CREATE TRIGGER trg_briefing_reports_primary_refs
BEFORE INSERT OR UPDATE OF related_card_ids, primary_card_news_id, primary_peer_company_id
ON briefing_reports
FOR EACH ROW
EXECUTE FUNCTION axis_set_briefing_report_primary_refs();

CREATE TRIGGER trg_mixer_results_primary_refs
BEFORE INSERT OR UPDATE OF input_card_ids, input_peer_ids, primary_card_news_id, primary_peer_company_id
ON mixer_results
FOR EACH ROW
EXECUTE FUNCTION axis_set_mixer_result_primary_refs();

CREATE TRIGGER trg_insight_reports_primary_refs
BEFORE INSERT OR UPDATE OF source_card_ids, focus_card_ids, focus_peer_ids, primary_card_news_id, primary_peer_company_id
ON insight_reports
FOR EACH ROW
EXECUTE FUNCTION axis_set_insight_report_primary_refs();

CREATE TRIGGER trg_integrated_issues_updated_at
BEFORE UPDATE ON integrated_issues
FOR EACH ROW
EXECUTE FUNCTION axis_touch_updated_at();

CREATE TRIGGER trg_integrated_issues_global_search_text
BEFORE INSERT OR UPDATE ON integrated_issues
FOR EACH ROW
EXECUTE FUNCTION axis_refresh_integrated_issue_global_search_text();

COMMENT ON TABLE legacy_records IS
    'Row-level archive for V30-collapsed tables. Not part of the product ERD.';
COMMENT ON TABLE integrated_issues IS
    'Canonical storage for IssueIntegrationAgent output. Keeps full payload plus queryable fields for downstream analysis agents.';
COMMENT ON COLUMN integrated_issues.issue_key IS
    'Idempotency key. Recommended values: cluster:{cluster_id}:v3 or raw:{raw_article_id}:v3.';
COMMENT ON COLUMN integrated_issues.representative_raw_article_id IS
    'raw_articles.id that was actually analyzed when a cluster has many source articles.';
COMMENT ON COLUMN integrated_issues.analyzed_source_ids IS
    'raw_articles.id list used as analytical basis, usually one representative source for clustered news.';
COMMENT ON COLUMN integrated_issues.source_ids IS
    'All raw_articles.id values retained as source/citation candidates.';
COMMENT ON COLUMN integrated_issues.payload IS
    'Full integrated_issue_v3 JSON object returned by IssueIntegrationAgent.';
COMMENT ON TABLE integrated_issue_source_articles IS
    'Normalized source list for an integrated issue. Mirrors the public sources array with raw_articles FK support.';
COMMENT ON COLUMN integrated_issue_source_articles.is_analyzed_basis IS
    'True when the article was actually analyzed, not only retained as a citation/source candidate.';
COMMENT ON TABLE integrated_issue_content_sections IS
    'Normalized content_digest.sections for section-level retrieval by Summary, Analysis, CardNews, Mixer, and KeywordGraph agents.';
COMMENT ON TABLE integrated_issue_evidence_references IS
    'Deduplicated evidence.references text store. Facts and frames can point here by evidence_ref_id.';
COMMENT ON COLUMN card_news.integrated_issue_id IS
    'IntegratedIssue payload used as the factual input for CardNewsAgent.';
