# AXIS 관리자 대시보드 설계 계획서

> 버전: v0.1 (초안)  
> 작성일: 2026-05-13  
> 대상 시스템: AXIS — AX 전략 인텔리전스 플랫폼  
> 시각화 도구: Grafana (OSS 11.x 기준)

---

## 1. 목표 (Goals)

운영자(관리자)가 한 화면에서 다음 세 가지를 판단할 수 있도록 한다.

1. **서비스 안정성** — LLM/API/인프라가 정상 동작 중인가? SLO 위반은 없는가?
2. **비용 통제** — 예산 대비 LLM/인프라 비용 추세는 어떤가? 이상 지출은 없는가?
3. **사용자 가치** — 누가, 어떤 기능을, 얼마나 만족하며 쓰는가?

### Non-Goals
- 일반 사용자(End user)용 분석 화면은 포함하지 않는다.
- 머신러닝 모델 학습 파이프라인 모니터링은 별도 시스템(예: MLflow)으로 이관한다.

---

## 2. 사용자 및 권한 (Personas & RBAC)

| 역할 | 권한 | 보는 화면 |
|------|------|----------|
| `super_admin` | 전체 대시보드, 비용/감사 로그, 사용자 PII 마스킹 해제 | 모든 패널 |
| `ops_admin` | 시스템·LLM·콘텐츠 패널 | 비용·사용자 패널 일부 |
| `viewer` | 읽기 전용, 마스킹된 데이터만 | 핵심 KPI만 |

> Grafana는 SSO(OAuth/OIDC) 로 인증, 폴더·팀 단위 권한으로 분리.

---

## 3. 아키텍처 개요

```
[AXIS App / API]
      │ ① LLM wrapper 미들웨어 (모든 모델 호출 경유)
      │ ② 이벤트 트래커 (페이지뷰/클릭/검색/피드백)
      ▼
[Message Bus: Kafka or Redis Stream]
      │
      ├──► [Worker] ──► PostgreSQL.analytics  (raw rows, 관계형 분석)
      ├──► [Prom Exporter] ──► Prometheus     (저카디널리티 카운터/히스토그램)
      └──► [Log Shipper] ──► Loki / S3        (원문 프롬프트·응답, 감사 로그)

[Batch ETL (Airflow/cron)]
      ├──► OpenAI/Anthropic Billing API ──► analytics.cost_daily_billed
      └──► AWS Cost Explorer            ──► analytics.infra_cost_daily

[Grafana] ── 데이터소스 3종(Prometheus, PostgreSQL, Loki) 동시 연결
```

### 핵심 설계 원칙
- **동기 INSERT 금지**: LLM 호출 응답 경로에서 DB I/O가 발생하지 않도록 큐 경유.
- **카디널리티 관리**: Prometheus 라벨에는 `user_id` 같은 고카디널리티 값 금지. user 단위 집계는 RDB에서 SQL로.
- **PII 격리**: 원문 프롬프트/응답은 RDB에 저장하지 않고 Loki(또는 S3 파케이) + TTL 정책.
- **추정 비용 ≠ 청구 비용**: 두 값을 별도 컬럼/테이블로 관리해 항상 비교 가능하게.

---

## 4. 데이터 모델 (PostgreSQL `analytics` 스키마)

### 4.1 `llm_call_logs` — LLM 호출 단위 로그
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | bigserial PK | |
| created_at | timestamptz | 호출 시작 시각 |
| user_id | uuid | nullable (게스트) |
| tenant_id | uuid | 멀티테넌트 키 |
| session_id | uuid | |
| feature | text | 'insight','cardnews','briefing','chat','peer_compare','keyword_graph' |
| model | text | 'gpt-4o','claude-opus-4',... |
| prompt_tokens | int | |
| completion_tokens | int | |
| total_tokens | int | |
| latency_ms | int | |
| status | text | 'success','error','timeout','filtered','rate_limited' |
| error_code | text | nullable |
| estimated_cost_usd | numeric(12,6) | token × 단가 자체 계산 |
| cache_hit | boolean | |
| prompt_hash | text | 원문은 Loki, 여기는 해시만 |
| trace_id | text | OpenTelemetry 연동 |

**인덱스**: `(created_at)`, `(tenant_id, created_at)`, `(feature, created_at)`, `(model, created_at)`.  
**파티셔닝**: `created_at` 월 단위 RANGE 파티션.

### 4.2 `user_events` — 행동 이벤트
| 컬럼 | 타입 | 설명 |
|------|------|------|
| id | bigserial PK | |
| occurred_at | timestamptz | |
| user_id | uuid | |
| tenant_id | uuid | |
| session_id | uuid | |
| event_type | text | 'page_view','search','card_click','feedback','regenerate','login','logout' |
| event_props | jsonb | 자유 속성(검색어, 클릭한 카드 id 등) |

**인덱스**: GIN on `event_props`, BTREE on `(event_type, occurred_at)`.

### 4.3 `feedback` — 콘텐츠/응답 평가
| 컬럼 | 타입 |
|------|------|
| id, created_at, user_id, tenant_id | — |
| artifact_id, llm_call_id | FK |
| thumbs | 'up'/'down'/null |
| rating | int (1~5) |
| comment | text |
| reported_issue | text |

### 4.4 `content_artifacts` — 산출물 메타
| 컬럼 | 타입 |
|------|------|
| id, created_at, type, created_by_user_id, tenant_id | — |
| llm_call_id | FK |
| title | text |
| source_count, citation_count | int |
| status | 'draft','published','archived' |

### 4.5 `cost_daily_estimated` — 일별 추정 비용 (앱 자체 계산)
| date, model, tenant_id, feature, calls, tokens_in, tokens_out, est_cost_usd |

### 4.6 `cost_daily_billed` — 일별 청구 비용 (벤더 API)
| date, vendor, model, billed_cost_usd, billed_tokens, source_uri |

### 4.7 `infra_cost_daily` — AWS 등 인프라 비용
| date, service, resource, cost_usd |

### 4.8 `audit_logs` — 관리자/보안 감사
| occurred_at, actor_user_id, action, target, ip, user_agent, result |

### 4.9 (참고) Prometheus 메트릭
```
llm_calls_total{model,feature,status,tenant}                  counter
llm_tokens_total{model,feature,direction,tenant}              counter
llm_latency_seconds_bucket{model,feature,le}                  histogram
llm_estimated_cost_usd_total{model,feature,tenant}            counter
http_requests_total{route,method,status}                      counter
active_sessions{tenant}                                       gauge
```

---

## 5. Grafana 대시보드 패널 구성

대시보드는 **5개 폴더** 로 나눈다. 각 폴더 안에 패널 4~8개.

### Folder A. Overview (홈 화면)
- 오늘의 호출 수 / 토큰 / 비용 / 에러율 (단일 stat 4개)
- 24h 호출 추세 (timeseries)
- 활성 사용자(현재 세션) (gauge)
- 최근 SLO 위반 알람 목록 (table)

### Folder B. LLM API & Quality
- 모델별 호출 수·토큰 시계열
- p50/p95/p99 응답 지연
- 에러율 분해(timeout, rate_limit, filtered, other)
- 캐시 hit rate
- 기능별(feature) 호출 분포 도넛
- 피드백 점수 시계열(👍/👎 비율, 평균 별점)
- 재생성(regenerate) 비율

### Folder C. Cost (FinOps)
- 일별 추정 vs 청구 비용 비교(timeseries 2 lines)
- 월 누적 비용 + 예산 게이지
- 모델별 비용 점유율(파이)
- 기능별·테넌트별 단위 비용(table)
- 비용 이상 탐지(이동평균 ±3σ 마커)

### Folder D. Users & Engagement
- DAU / WAU / MAU 시계열
- 신규 가입 / 이탈(7일 비활성) 시계열
- 권한·플랜별 사용자 분포
- 기능별 사용률(stacked bar)
- 검색 키워드 Top 20, zero-result 비율
- 사용자별 호출 Top N (이상 사용 감지용 table)

### Folder E. System & Security
- ALB RPS, 5xx 비율, target health
- Pod CPU/Mem, restart 수
- DB 연결 수·slow query
- 큐 적체량(메시지 백로그)
- 로그인 실패율, 비정상 IP Top N
- 감사 로그 최근 50건(audit_logs 직조회)

---

## 6. 알람 (Alerting) 초기 룰

| 이름 | 조건 | 채널 |
|------|------|------|
| LLM 5xx 급증 | 5분 평균 에러율 > 5% | Slack #ops |
| 비용 스파이크 | 시간당 비용 > 7일 평균 × 2 | Slack + Email |
| p95 지연 SLO 위반 | 10분 동안 p95 > 5s | Slack #ops |
| 비정상 로그인 | 동일 IP 실패 > 20/min | Slack #security |
| 큐 적체 | backlog > 1000 메시지 5분 지속 | PagerDuty |

---

## 7. 데이터 보존 및 PII 정책

| 데이터 | 보존 기간 | 비고 |
|--------|-----------|------|
| Prometheus 메트릭 | 30일(고해상도) / 1년(downsampled) | Thanos/Mimir 고려 |
| `llm_call_logs` | 13개월 | 월 파티션, 만료 시 detach + S3 archive |
| 원문 프롬프트·응답 (Loki/S3) | 30일 | 그 이후 자동 삭제. 마스킹 후 장기 보관 옵션 |
| `user_events` | 13개월 | |
| `audit_logs` | 5년 | 컴플라이언스 |

PII 컬럼은 `pgcrypto`로 컬럼 암호화, 이메일은 해시(`email_hash`)만 분석 영역에 노출.

---

## 8. 구현 로드맵

| 단계 | 기간(예상) | 산출물 |
|------|----------|--------|
| 0. 사전 | 1주 | DB 스키마 분리, Grafana/Prometheus 설치, OIDC 연동 |
| 1. MVP | 2주 | `llm_call_logs`, `user_events` 적재 + Overview/LLM 폴더 |
| 2. 비용 | 1주 | `cost_daily_*` ETL + Cost 폴더 + 예산 알람 |
| 3. 사용자/품질 | 2주 | `feedback`, `content_artifacts` + Users·Quality 패널 |
| 4. 보안/감사 | 1주 | `audit_logs` + Security 패널 + SSO RBAC 정리 |
| 5. 운영 안정화 | 지속 | SLO 정의, 알람 튜닝, 보존 정책 적용 |

---

## 9. 결정 사항 / 미결 (Open Questions)

- [ ] 메시지 버스: Kafka vs Redis Stream — 팀 운영 부담 기준 결정 필요
- [ ] 장기 메트릭 저장: Prometheus 단일 vs Thanos/Mimir
- [ ] 비용 정산 기준 통화: USD vs KRW (환율 스냅샷 정책)
- [ ] 멀티테넌트가 실제로 필요한가? 아니라면 `tenant_id`는 단일 default 값으로 보류

---

## 10. 부록: 동일 DB / 스키마 분리 SQL

```sql
-- 1) 스키마 생성
CREATE SCHEMA IF NOT EXISTS crawl;
CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS analytics;

-- 2) Grafana 읽기 전용 계정
CREATE ROLE grafana_ro LOGIN PASSWORD '<change-me>';
GRANT CONNECT ON DATABASE axis TO grafana_ro;
GRANT USAGE ON SCHEMA analytics TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
  GRANT SELECT ON TABLES TO grafana_ro;

-- 3) llm_call_logs 파티셔닝 예시
CREATE TABLE analytics.llm_call_logs (
  id           bigserial,
  created_at   timestamptz NOT NULL,
  user_id      uuid,
  tenant_id    uuid,
  feature      text,
  model        text,
  prompt_tokens int, completion_tokens int, total_tokens int,
  latency_ms   int,
  status       text,
  error_code   text,
  estimated_cost_usd numeric(12,6),
  cache_hit    boolean,
  prompt_hash  text,
  trace_id     text,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

CREATE TABLE analytics.llm_call_logs_2026_05
  PARTITION OF analytics.llm_call_logs
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
```