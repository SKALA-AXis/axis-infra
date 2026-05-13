# MetricsExporter — Design Plan

> ⏸ **[보류 — P10+]** Grafana / Prometheus 통합은 후순위. 본 design 은 spec 으로 유지하되 실 구현은 Langfuse + DB 마이그레이션 완료 후 별도 PR 로 진행.
>
> **사유**: SKALA 클러스터에 공용 Grafana / Prometheus / Loki / Tempo / Jaeger 가 이미 운영 중 (`observability` + `remote-rde` namespace, ingress: `observability.skala25a.project.skala-ai.com` 등). 활용 위해서는: ① Prometheus auto-discover 가능 여부 확인 ② Grafana 접근 권한 / login 방법 확인 ③ dashboard import 절차 매니저 협의. 9주 일정상 W10+ 로 미룸.
>
> **본 design 이 가정하는 잘못된 전제**: §6.5 "kube-prometheus-stack 설치 가정" — 실제 클러스터에는 vanilla Prometheus (Operator 없음). ServiceMonitor CR 불가 → pod annotation auto-discover 또는 매니저 scrape_config 신청으로 전환 예정.
>
> P10+ 활성 시 본 문서 §6.5 / §6.6 / §13 재작성 필요.

## 1. 메타

| 항목 | 값 |
|---|---|
| **이름** | `MetricsExporter` (Prometheus `/metrics` endpoint, axis-ai + BE 양쪽) |
| **Supervisor** | (none — FastAPI / Spring Actuator) |
| **상태** | ⏸ 보류 (P10+) — axis-ai `/metrics` endpoint + Grafana 통합 모두 미진행. Langfuse + DB 마이그 완료 후 재개 |
| **Trigger** | Prometheus scrape (15초 주기) |

## 2. 책임

**한 줄**: axis-ai 의 모든 LLM 호출 / pipeline 실행 / search query 를 Prometheus 카운터·히스토그램으로 노출하여 Grafana 가 시계열 메트릭으로 시각화.

**구체적**:

1. **counter** — `llm_calls_total{model, agent, status}`, `llm_tokens_total{model, agent, direction}`, `pipeline_run_total{supervisor, trigger, status}`, `crawler_fetch_total{source, status}`
2. **histogram** — `llm_latency_seconds{model, agent}`, `pipeline_duration_seconds{supervisor}`, `qdrant_search_latency_seconds{collection}`
3. **gauge** — `qdrant_collection_size{collection}`, `pipeline_logs_pending_review` (human_review_flag count)
4. **noop on disabled** — `METRICS_ENABLED=false` (개발 환경) 시 `/metrics` 가 빈 응답 + counter 갱신 X
5. **scrape endpoint** — `GET /metrics` (text/plain; version=0.0.4)

## 3. 책임 NOT

- **trace 시각화** — Langfuse (spec: `axis-infra/docs/OBSERVABILITY_LANGFUSE.md`)
- **빌링 정산** — TokenBudgetMiddleware (`axis-ai/design/90-cross-cutting/token-budget.md`) + CostReconciliationJob (`axis-infra/docs/admin/cost_reconciliation.md`)
- **로그 / audit** — Loki / audit_logs (`axis-infra/docs/AUDIT_LOG.md`)
- **alerting rule 직접 발화** — Grafana Alerting 또는 Prometheus Alertmanager (정의는 별도 PromQL)

## 4. 입력 스펙

```python
# 메트릭은 push 가 아닌 *카운터 증가 / observation* 패턴
metrics.llm_calls_total.labels(model="gpt-4o", agent="CardComposerAgent", status="success").inc()
metrics.llm_latency_seconds.labels(model="gpt-4o", agent="CardComposerAgent").observe(2.3)
metrics.llm_tokens_total.labels(model="gpt-4o", agent="CardComposerAgent", direction="input").inc(1800)
```

## 5. 출력 스펙

### axis-ai `/metrics` 응답 (text/plain)

```text
# HELP llm_calls_total LLM API call count
# TYPE llm_calls_total counter
llm_calls_total{model="gpt-4o",agent="CardComposerAgent",status="success"} 42
llm_calls_total{model="gpt-4o-mini",agent="ClassificationAgent",status="success"} 156

# HELP llm_tokens_total LLM token usage by direction
# TYPE llm_tokens_total counter
llm_tokens_total{model="gpt-4o",agent="CardComposerAgent",direction="input"} 75600
llm_tokens_total{model="gpt-4o",agent="CardComposerAgent",direction="output"} 12800

# HELP llm_latency_seconds LLM call wall time
# TYPE llm_latency_seconds histogram
llm_latency_seconds_bucket{model="gpt-4o",agent="CardComposerAgent",le="0.5"} 0
llm_latency_seconds_bucket{model="gpt-4o",agent="CardComposerAgent",le="1.0"} 5
llm_latency_seconds_bucket{model="gpt-4o",agent="CardComposerAgent",le="2.0"} 18
llm_latency_seconds_bucket{model="gpt-4o",agent="CardComposerAgent",le="5.0"} 38
llm_latency_seconds_bucket{model="gpt-4o",agent="CardComposerAgent",le="+Inf"} 42
llm_latency_seconds_sum{model="gpt-4o",agent="CardComposerAgent"} 88.4
llm_latency_seconds_count{model="gpt-4o",agent="CardComposerAgent"} 42

# HELP pipeline_run_total ingestion / delivery / weak_signal run count
# TYPE pipeline_run_total counter
pipeline_run_total{supervisor="ingestion",trigger="scheduled",status="success"} 24
pipeline_run_total{supervisor="ingestion",trigger="scheduled",status="error"} 0

# HELP qdrant_collection_size Vectors per collection
# TYPE qdrant_collection_size gauge
qdrant_collection_size{collection="axis_main"} 4283
qdrant_collection_size{collection="axis_history"} 18920

# HELP crawler_fetch_total Raw article fetch attempts
# TYPE crawler_fetch_total counter
crawler_fetch_total{source="naver_news_api",status="success"} 1840
crawler_fetch_total{source="naver_news_api",status="http_429"} 12
crawler_fetch_total{source="dart_openapi",status="success"} 21
```

### 카디널리티 가드 (admin_page §3 원칙)

| label | 허용 값 | 제한 |
|---|---|---|
| `model` | gpt-4o / gpt-4o-mini / bge-m3 | ≤ 5 |
| `agent` | 25 agent class name | ≤ 30 |
| `status` | success / error / timeout / rate_limited / filtered | ≤ 6 |
| `supervisor` | ingestion / enrichment / analysis / userquery / weak_signal / briefing | ≤ 6 |
| `source` | naver_news_api / dart_openapi / etnews / ... | ≤ 12 |
| `collection` | axis_main / axis_history | ≤ 3 |
| ❌ user_id / session_id / card_id | **금지** (고카디널리티) | — |

> user_id 별 집계가 필요하면 PG SQL (`usage_logs`) 또는 Langfuse user 탭에서.

## 6. 알고리즘 / 통합

### 6.1 axis-ai FastAPI 통합

```python
# src/observability/metrics.py (신규)
from prometheus_client import Counter, Histogram, Gauge, CollectorRegistry, generate_latest

REGISTRY = CollectorRegistry()

llm_calls_total = Counter(
    "llm_calls_total", "LLM API call count",
    labelnames=["model", "agent", "status"], registry=REGISTRY,
)
llm_tokens_total = Counter(
    "llm_tokens_total", "LLM token usage",
    labelnames=["model", "agent", "direction"], registry=REGISTRY,
)
llm_latency_seconds = Histogram(
    "llm_latency_seconds", "LLM call wall time",
    labelnames=["model", "agent"],
    buckets=(0.5, 1.0, 2.0, 5.0, 10.0, 30.0),
    registry=REGISTRY,
)
pipeline_run_total = Counter(
    "pipeline_run_total", "Pipeline run count",
    labelnames=["supervisor", "trigger", "status"], registry=REGISTRY,
)
pipeline_duration_seconds = Histogram(
    "pipeline_duration_seconds", "Pipeline run wall time",
    labelnames=["supervisor"],
    buckets=(5, 15, 30, 60, 120, 300, 600),
    registry=REGISTRY,
)
qdrant_collection_size = Gauge(
    "qdrant_collection_size", "Vectors per collection",
    labelnames=["collection"], registry=REGISTRY,
)
crawler_fetch_total = Counter(
    "crawler_fetch_total", "Raw article fetch attempts",
    labelnames=["source", "status"], registry=REGISTRY,
)
```

```python
# src/api/router.py 에 endpoint 추가
from fastapi import Response
from src.observability import metrics

@app.get("/metrics", include_in_schema=False)
async def prometheus_metrics():
    if not settings.METRICS_ENABLED:
        return Response("", media_type="text/plain")
    # qdrant size 는 매 scrape 마다 refresh (값은 1초 안에 stale 무관)
    for coll in ["axis_main", "axis_history"]:
        try:
            count = qdrant.count(collection_name=coll, exact=False).count
            metrics.qdrant_collection_size.labels(collection=coll).set(count)
        except Exception:
            pass
    return Response(generate_latest(metrics.REGISTRY), media_type="text/plain; version=0.0.4")
```

### 6.2 TokenBudgetMiddleware 와 연동

호출 후 `budget_record()` 직후 metrics 자동 갱신:

```python
async def budget_record(agent, model, in_tok, out_tok, elapsed_ms, success):
    # 기존 usage_logs INSERT
    await _insert_usage_log(...)
    # Prometheus 갱신
    status = "success" if success else "error"
    metrics.llm_calls_total.labels(model=model, agent=agent, status=status).inc()
    metrics.llm_tokens_total.labels(model=model, agent=agent, direction="input").inc(in_tok)
    metrics.llm_tokens_total.labels(model=model, agent=agent, direction="output").inc(out_tok)
    metrics.llm_latency_seconds.labels(model=model, agent=agent).observe(elapsed_ms / 1000.0)
```

### 6.3 Pipeline supervisor 와 연동

```python
async def run_ingestion_graph(state):
    t0 = time.time()
    status = "success"
    try:
        result = await graph.ainvoke(state)
    except Exception:
        status = "error"; raise
    finally:
        metrics.pipeline_run_total.labels(
            supervisor="ingestion", trigger=state["trigger_type"], status=status
        ).inc()
        metrics.pipeline_duration_seconds.labels(supervisor="ingestion").observe(time.time() - t0)
```

### 6.4 BE 측 (Spring Actuator)

이미 Spring Actuator 가 `/actuator/prometheus` 노출 가능 (의존성: `micrometer-registry-prometheus`).

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health, info, prometheus
  metrics:
    tags:
      application: axis-backend
```

자동 노출 메트릭:
- `http_server_requests_seconds{uri, method, status}` — 모든 HTTP endpoint
- `jvm_memory_used_bytes`, `jvm_threads_live_threads`
- `hikaricp_connections_active` (DB 풀)

추가 커스텀:
- `axis_feedback_submit_total{artifact_type, thumbs}` (FeedbackController 에서 갱신)
- `axis_pipeline_trigger_total{track}` (PipelineController)

### 6.5 Grafana 데이터소스

axis-infra/helm 의 monitoring stack (또는 kube-prometheus-stack) 이 Prometheus + Grafana 운영. 데이터소스 3종 자동 추가:

```yaml
# grafana datasources
- name: Prometheus
  type: prometheus
  url: http://prometheus.monitoring.svc.cluster.local:9090
- name: AxisDB
  type: postgres
  url: axis-postgres.skala3-finalproj-class3-team13.svc.cluster.local:5432
  database: axis
  user: grafana_ro
  # P9+ 분리 시 SET search_path TO analytics, public;
- name: Loki     # 선택 (application logs)
  type: loki
  url: http://loki.monitoring.svc.cluster.local:3100
```

### 6.6 ServiceMonitor (k8s)

```yaml
# axis-infra/k8s/base/servicemonitor-axis-ai.yaml (신규)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: axis-ai
  labels: { release: kube-prometheus-stack }
spec:
  selector:
    matchLabels: { app: axis-ai }
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

## 7. LLM 모델 + token 예산

- LLM 미사용 → ₩0
- Prometheus scrape 자원: ~5KB / 15s × 1 pod = ~30MB/일 (무시 가능)

## 8. 에러 처리

| 시나리오 | 대응 |
|---|---|
| qdrant.count 실패 | 해당 collection gauge 갱신 X + log debug (이전 값 유지) |
| /metrics 호출 시 카디널리티 폭주 (예: 신규 model 30개) | Prometheus rule 로 cardinality alert + 즉시 label 정리 PR |
| METRICS_ENABLED=false | 빈 응답 + 카운터 갱신 X |
| `agent` label 에 None 들어옴 | 'unknown' 으로 정규화 + log |

## 9. 외부 의존성

- **lib (axis-ai)**: `prometheus-client>=0.20`
- **lib (BE)**: `micrometer-registry-prometheus` (이미 Spring Boot 3.x 기본 포함)
- **k8s**: ServiceMonitor (Prometheus Operator CRD), Prometheus + Grafana 자체 (kube-prometheus-stack)

## 10. State 흐름

state 와 무관. middleware 가 부수적으로 counter 증가.

## 11. Provenance + Confidence

- Prometheus 메트릭 자체에 provenance 안 부착 (label 만 카디널리티 제약). 상세 trace 는 Langfuse 가 SoT.
- `_build_provenance()` 의 결과는 그대로 evidence_chain.provenance jsonb 에.

## 12. 테스트 시나리오

| 유형 | 시나리오 | 검증 |
|---|---|---|
| Unit | `llm_calls_total.inc()` × 5 | `/metrics` 응답에 counter=5 |
| Unit | histogram observe (2.3) | bucket le="5.0" 가 1 증가 |
| Unit | METRICS_ENABLED=false | /metrics 빈 응답 |
| Integration | Prometheus scrape | ServiceMonitor 로 자동 발견 + 데이터 유입 |
| Edge | qdrant down | size gauge 갱신 X, 다른 메트릭 정상 |
| Edge | label 에 한글 (예: agent="카드") | UTF-8 OK (Prometheus 가 지원) |

## 13. 모니터링

- KPI:
  - scrape 성공률 ≥ 99% (Prometheus side `up{job="axis-ai"}` gauge)
  - cardinality < 10K timeseries / pod (admin_page 권장 < 100K 전체)
  - `/metrics` 응답 latency ≤ 100ms (p95)
- Grafana 대시보드 (admin_page §5):
  - **A. Overview** — `sum(rate(llm_calls_total[5m]))`, `sum(rate(llm_calls_total{status="error"}[5m]))`
  - **B. LLM API & Quality** — `histogram_quantile(0.95, llm_latency_seconds_bucket)`, by model
  - **C. Cost** — `sum(rate(llm_tokens_total[1h])) * price_const` (env var 가격표)
  - **D. Users & Engagement** — `axis_feedback_submit_total` + user_events 합산 (SQL)
  - **E. System & Security** — `up`, `http_server_requests_seconds`, `hikaricp_connections_active`

## 14. 구현 메모 + Changelog

### 신규 파일

- **axis-ai**: `src/observability/metrics.py` (Counter/Histogram/Gauge 정의)
- **axis-ai**: `src/api/router.py` 의 `/metrics` endpoint
- **k8s**: `axis-infra/k8s/base/servicemonitor-axis-ai.yaml`
- **Grafana**: `axis-infra/helm/observability/grafana/dashboards/*.json` (5 폴더 JSON)

### 의존성

- pyproject.toml: `uv add prometheus-client`
- Spring: `pom.xml` / `build.gradle` 에 `micrometer-registry-prometheus`

### 신규 마이그레이션

- DB 마이그 불필요 (메트릭은 in-memory + Prometheus 별도 저장)
- 단 P9+ `grafana_ro` 계정 생성은 admin_page §10 의 SQL 부록 그대로:
  ```sql
  CREATE ROLE grafana_ro LOGIN PASSWORD '<from-secret>';
  GRANT CONNECT ON DATABASE axis TO grafana_ro;
  GRANT USAGE ON SCHEMA public TO grafana_ro;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
  ```
  (옵션 B = public schema 유지 결정에 맞춤. P9+ analytics schema 분리 시 search_path 변경)

### Backend 연동

- 신규: `GET /metrics` (Spring Actuator 활성화만)
- 신규: `GET /api/admin/dashboards` (Grafana 폴더 URL 반환, admin role 만)

### Changelog

- **v1 (제안, P9)** — admin_page §4.9 + §5 정합. cardinality guard + ServiceMonitor + 5 Grafana 폴더
