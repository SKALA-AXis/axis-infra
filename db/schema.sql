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
-- sk_ax — 자사. raw_articles 까지만 적재, issue_card 생성 X (id 로 분기)
CREATE TABLE IF NOT EXISTS peer_companies (
    id          VARCHAR(50)  PRIMARY KEY,            -- 'samsung_sds' · 'lg_cns' · 'hyundai_autoever' · 'posco_dx' · 'sk_ax'
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
    importance_score    FLOAT,                        -- v3 exposure_score (결정적 산식, 0~1)
    metadata            JSONB        DEFAULT '{}',
    created_at          TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_raw_articles_peer_published
    ON raw_articles (peer_id, published_at DESC);
CREATE INDEX IF NOT EXISTS idx_raw_articles_status
    ON raw_articles (processing_status);
CREATE INDEX IF NOT EXISTS idx_raw_articles_cluster
    ON raw_articles (cluster_id);
-- url 컬럼은 UNIQUE 제약으로 PG 가 자동 인덱스 생성 — 별도 인덱스 불필요.

-- ============================================================
-- 3. issue_cards — AI가 생성한 이슈 카드 (v3에서 "동향 카드"로 리네임 예정)
-- ============================================================
-- v3 변경사항:
--   - importance 컬럼: v3에서 exposure_band(high/medium/low)를 그대로 저장 (값 호환)
--   - implication JSONB: v3 메타데이터 (sector, sectors, exposure_score, exposure_band,
--     signals, evidence_chain) 통합 저장. 향후 evidence_chain 테이블로 분리 마이그레이션 예정
--   - validation_pass / validation_sc_score: SC 검증 → EvidenceAgent의 검증 첨부 결과로 의미 전환
CREATE TABLE IF NOT EXISTS issue_cards (
    id                  VARCHAR(50)  PRIMARY KEY,     -- 'IC-20260420-001' 형식
    peer_id             VARCHAR(50)  NOT NULL REFERENCES peer_companies(id),
    cluster_id          BIGINT,
    title               TEXT         NOT NULL,
    summary_lines       TEXT[]       DEFAULT '{}',    -- 3줄 요약
    event_type          VARCHAR(50),                  -- partnership/ma/personnel/tech/regulation/new_biz
    importance          VARCHAR(20),                  -- v1: urgent/notable/reference, v3: high/medium/low (exposure_band)
    importance_score    FLOAT,                        -- v3: exposure_score (0~1, 결정적 산식)
    implication         JSONB,                        -- v3: {sector, sectors, exposure_score, exposure_band, signals, evidence_chain}
    sources             JSONB,                        -- 출처 목록
    validation_pass     BOOLEAN,                      -- v3: 검증 정보 4종 자동 첨부 통과 여부
    validation_sc_score FLOAT,                        -- v3: 1.0 (pass) / 0.0 (fail) — SC 검증 폐기, 의미 전환
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
-- 모든 이슈카드의 4종 검증 정보 (source_links / provenance / financial_refs / mbb_refs).
-- 현재는 issue_cards.implication JSONB 안에 통합 저장 중 — 본 테이블로 분리 마이그레이션 예정.
-- API: GET /api/evidence/{issue_card_id} 가 이 테이블을 조회.
CREATE TABLE IF NOT EXISTS evidence_chain (
    id                  BIGSERIAL    PRIMARY KEY,
    issue_card_id       VARCHAR(50)  NOT NULL REFERENCES issue_cards(id) ON DELETE CASCADE,
    source_links        JSONB        DEFAULT '[]',       -- 원문 URL + 출처명 + 신뢰도
    provenance          JSONB        DEFAULT '{}',       -- raw_article_ids, llm_model, prompt_version, run_at
    financial_refs      JSONB        DEFAULT '[]',       -- {period, metric, value, delta_qoq, delta_yoy, dart_rcept_no, ir_page}
    mbb_refs            JSONB        DEFAULT '[]',       -- 컨설팅사 보고서 자동 매칭 (W5)
    financial_link      JSONB,                           -- {linked, segment, highlights, headcount_delta}
    evidence_version    VARCHAR(20)  DEFAULT 'v3.0',
    pass                BOOLEAN      DEFAULT FALSE,      -- 4종 첨부 통과 여부
    missing             TEXT[]       DEFAULT '{}',       -- 누락 항목 — pass=false 시 human_review
    created_at          TIMESTAMPTZ  DEFAULT NOW(),
    UNIQUE (issue_card_id)
);

-- issue_card_id 는 UNIQUE 제약으로 PG 가 자동 인덱스 생성 — 별도 인덱스 불필요.
CREATE INDEX IF NOT EXISTS idx_evidence_chain_pass
    ON evidence_chain (pass);

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
    issue_card_id       VARCHAR(50)  REFERENCES issue_cards(id) ON DELETE SET NULL,

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
    ON article_images (issue_card_id);
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
    card_ids            TEXT[]       DEFAULT '{}',                -- 포함된 issue_cards.id 배열
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
-- 초기 데이터 — Peer사 4사 + SK AX 자사 (V5 시드, id 로 분기)
-- ============================================================
INSERT INTO peer_companies (id, name, keywords) VALUES
    ('samsung_sds',      '삼성SDS',     ARRAY['삼성SDS', '삼성 SDS', 'Samsung SDS']),
    ('lg_cns',           'LG CNS',      ARRAY['LG CNS', 'LGCNS']),
    ('hyundai_autoever', '현대오토에버', ARRAY['현대오토에버', '오토에버', 'Hyundai AutoEver']),
    ('posco_dx',         '포스코DX',    ARRAY['포스코DX', '포스코 DX', 'POSCO DX']),
    ('sk_ax',            'SK AX',       ARRAY['SK AX', 'SKAX', '에스케이에이엑스', 'SK 에이엑스'])
ON CONFLICT (id) DO NOTHING;
