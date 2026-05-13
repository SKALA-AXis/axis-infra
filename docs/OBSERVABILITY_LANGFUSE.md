# Observability — Langfuse Self-Host Integration

## 1. 메타

| 항목 | 값 |
|---|---|
| **이름** | `LangfuseObservability` (LangChain CallbackHandler 통합 + Helm chart) |
| **Supervisor** | (none — middleware) |
| **상태** | 🔴 신규 (P9) — 현재 LLM trace 추적 도구 없음 |
| **Trigger** | 모든 LLM 호출 (LangChain `callbacks=[handler]` 자동 fan-out) |
| **선택 근거** | LangSmith 대비: ① self-host 가능 = 무료 ② SKALA k8s 클러스터에 직접 띄울 수 있음 ③ 기능 (trace tree / cost / prompt mgmt / eval) 동등 ④ LangGraph 의 multi-step 흐름이 native callback 으로 추적됨 |

## 2. 책임

**한 줄**: 모든 LLM 호출의 prompt / response / token / cost / latency / parent span 을 Langfuse 에 send 하여 trace 시각화 + per-agent 디버깅 + RAG 청크 검증 가능하게 함.

**구체적**:

1. **Trace tree** — Supervisor 그래프 = root trace, 각 LangGraph node = span, LLM 호출 = sub-span, tool call = sub-sub-span
2. **Full prompt / response 보존** — 본문 텍스트 그대로 (PG 의 jsonb 에 본문 저장 X)
3. **RAG chunks** — HybridSearch 결과 / Rerank top-10 / Answer context 를 span metadata 에 첨부
4. **Cost auto-calc** — Langfuse 내장 가격표가 USD 환산. KRW 환산은 app side `usage_logs` 에서 별도
5. **User / session metadata** — user_id, session_id, request_id, prompt_version 을 span attribute 로
6. **Eval (선택)** — 사용자 좋아요/싫어요 (`/api/cards/{id}/feedback` 신설 가능) 를 score 로 push

## 3. 책임 NOT

- **비용 envelope enforcement** — TokenBudgetMiddleware (pre-call check + circuit break)
- **변경불가 audit log** — AuditLogMiddleware (admin/user action 별개)
- **메트릭 dashboard** — 공용 Prometheus + Grafana (실시간 호출 수 / 에러율 / p95 latency) — ⏸ P10+ 활성 (`axis-infra/docs/admin/metrics_exporter.md`)
- **실 빌링 정산** — `usage_logs` 의 KRW 집계 (Langfuse 는 분석용이지 SoT 아님)

## 4. 입력 스펙

```python
class LangfuseSpanContext(TypedDict):
    name: str                        # "CardComposerAgent.analyze"
    user_id: int | None              # BE 가 전달 (chat / briefing)
    session_id: str | None           # chat session
    request_id: str                  # FastAPI middleware 가 생성한 UUID
    parent_trace_id: str | None      # supervisor 가 시작한 root
    metadata: dict                   # agent / phase / prompt_version / retrieval_chunks
    tags: list[str]                  # ["ingestion", "card_composer", "phase=summarize"]
```

## 5. 출력 스펙

### Langfuse 가 보존 (Langfuse PG + ClickHouse 내부)

```json
{
  "trace_id": "lf-trace-...",
  "name": "ingestion.hourly",
  "user_id": null,
  "session_id": null,
  "metadata": {"trigger": "scheduled", "company": ["samsung_sds"]},
  "spans": [
    {
      "name": "CardComposerAgent.summarize",
      "model": "gpt-4o-mini",
      "input": "다음 클러스터의 기사들을...",
      "output": "{\"summary_lines\": [...]}",
      "input_tokens": 1800,
      "output_tokens": 280,
      "latency_ms": 2400,
      "cost_usd": 0.000462,
      "metadata": {"prompt_version": "summary-v3.0", "cluster_id": 17},
      "parent_id": "<root>",
      "status": "success"
    },
    ...
  ]
}
```

### app DB 에 흔적

- `usage_logs.langfuse_trace_id` — billing row 가 어느 trace 의 어느 span 인지 pointer
- `evidence_chain.provenance.langfuse_trace_id` — card 1건 → trace tree (Langfuse UI 클릭) 드릴다운

## 6. 알고리즘 / 통합 패턴

### 6.1 LangChain CallbackHandler — 1줄 통합

```python
# src/observability/langfuse_client.py
from langfuse.callback import CallbackHandler
from src.config import settings

_handler = CallbackHandler(
    public_key=settings.LANGFUSE_PUBLIC_KEY,
    secret_key=settings.LANGFUSE_SECRET_KEY,
    host=settings.LANGFUSE_HOST,           # http://langfuse-web.skala3-finalproj-class3-team13.svc.cluster.local:3000
    flush_at=10,                           # batch 10 spans
    flush_interval=2.0,                    # or 2초마다 flush
)

def langfuse_handler(**span_metadata):
    """주입 시점에 metadata 부착해 새 handler 반환."""
    return _handler.copy(metadata=span_metadata)
```

```python
# 각 LangGraph node
from src.observability.langfuse_client import langfuse_handler

async def card_composer_node(state):
    handler = langfuse_handler(
        agent="CardComposerAgent",
        phase="summarize",
        prompt_version=SUMMARY_PROMPT_VERSION,
        cluster_id=state["cluster_id"],
        request_id=state["request_id"],
    )
    response = await llm.ainvoke(messages, config={"callbacks": [handler]})
    # response 의 trace_id 를 state 에 보존 (provenance 부착 시 사용)
    trace_id = handler.get_trace_id()
    return {**state, "card_news": [...], "_langfuse_trace_id": trace_id}
```

LangGraph supervisor 가 root trace 시작 → 각 node 가 sub-span 자동 nesting (LangChain 의 RunnableConfig 가 parent_id 전파).

### 6.2 직접 OpenAI 호출 (LangChain 우회) 의 경우

```python
from langfuse.openai import openai as langfuse_openai

# 기존 from openai import OpenAI → 위로 교체
client = langfuse_openai.OpenAI()
response = client.chat.completions.create(
    model="gpt-4o-mini",
    messages=[...],
    metadata={"agent": "CardComposerAgent", "phase": "summarize"},
    tags=["ingestion"],
)
```

`langfuse.openai` 가 OpenAI SDK 의 drop-in wrapper — 코드 변경 거의 없음.

### 6.3 RAG 청크 첨부 (HybridSearch / Rerank)

```python
async def hybrid_search_node(state):
    handler = langfuse_handler(agent="HybridSearchAgent", request_id=state["request_id"])
    hits = await search_qdrant(state["query"])
    # search 자체는 LLM 아니지만 trace 의 span 으로 기록 (debugging용)
    handler.span(
        name="qdrant.hybrid_rrf",
        input={"query": state["query"], "filters": state.get("filters")},
        output={"hits_count": len(hits), "top_3": [h.title for h in hits[:3]]},
        metadata={"rrf_k": 60, "dense_top": 50, "sparse_top": 50},
    )
    return {**state, "hits": hits}
```

이렇게 하면 Answer span 의 부모로 "어떤 query → 어떤 hits → LLM 답변" 트리가 그대로 보임. 환각 디버깅의 핵심.

### 6.4 Trace ID 전파 (BE → axis-ai)

```python
# axis-ai FastAPI middleware
@app.middleware("http")
async def trace_id_middleware(request: Request, call_next):
    # BE 가 X-Request-Id / X-User-Id 헤더로 전달
    request.state.request_id = request.headers.get("x-request-id") or str(uuid4())
    request.state.user_id = request.headers.get("x-user-id")
    response = await call_next(request)
    response.headers["x-request-id"] = request.state.request_id
    return response
```

```java
// BE AiClientService
HttpHeaders headers = new HttpHeaders();
headers.set("X-Request-Id", MDC.get("request_id"));
headers.set("X-User-Id", SecurityContextHolder.getCurrentUserId().toString());
restTemplate.exchange(..., headers, ...);
```

→ Langfuse trace 가 BE 로그의 request_id 와 일치. application log 와 trace 가 자유롭게 연결됨.

### 6.5 데이터 도구 역할 분담 (v1 vs P10+)

**v1 (Langfuse + DB 만 활성):**

| 도구 | 데이터 종류 | 활용 |
|---|---|---|
| **Langfuse** (self-host) | trace tree (LLM span / prompt / response / RAG chunks) | 디버깅, prompt eval, 환각 추적 |
| **app DB** (`usage_logs`, `audit_logs`, `feedback`) | 비즈니스 데이터 (₩ 빌링, 감사, 사용자 평가) | admin 화면, compliance, 영구 보존 |

**P10+ (Grafana 통합 활성 시):**

| 도구 | 추가 활용 |
|---|---|
| 공용 Prometheus (`remote-rde`) | 카운터 / 히스토그램 / gauge 시각화 (axis-ai `/metrics` + Spring Actuator) |
| 공용 Grafana (`observability`) | dashboard (admin_page §5 5 폴더), datasource 3종 (Prom + Loki + 우리 PG) |
| 공용 Loki (`observability`) | application log 검색 (이미 alloy-logs 가 수집 중) |
| 공용 Tempo / Jaeger (`observability`) | OTLP distributed trace (HTTP→DB→axis-ai 체인) |

> 상세 spec: `axis-infra/docs/admin/metrics_exporter.md` (현재 ⏸ 보류 상태)

**trace_id 호환**: Langfuse v2 는 internal id (영문자 + uuid 변형). BE / axis-ai 의 application log MDC 의 `trace_id` 와는 동일 보장 X — 다만 둘 다 `request_id` (FastAPI middleware 생성 UUID) 를 같이 들고 다녀 grep 으로 매칭 가능.

### 6.6 v1 호출 경로 (TokenBudgetMiddleware 와 동시 사용)

`TokenBudgetMiddleware.budget_record()` 한 번 호출에서:

1. `usage_logs` INSERT (sync) — billing
2. Langfuse 는 LangChain callback 이 별도 fan-out — full trace

(Prometheus counter / histogram 갱신은 ⏸ P10+ metrics_exporter 활성 시 추가)

## 7. LLM 모델 + token 예산

- Langfuse 자체는 LLM 호출 안 함. **Langfuse v2 self-host 기준** 자원:
  - **CPU**: 0.5 core (request) / 2 core (limit)
  - **RAM**: 1.5Gi (request) / 4Gi (limit)
  - **Storage**: **PG 5Gi only** (v2 는 ClickHouse / Redis 불필요. 30일 trace, 일 5,000 span 기준 충분)
  - **Pod 수**: 2 (web + worker) + 내장 PG 1 = 3 pod
  - **PVC 수**: 1 (team13 quota 의 PVC 여유 2개 중 1개 사용)
- Langfuse 비용: ₩0 (self-host)
- **v2 vs v3 선택 이유**: SKALA team13 namespace 의 PVC quota 여유 = 2개. v3 (PG + ClickHouse + Redis = 3 PVC) 는 quota 초과. v2 로 충분 (학생 프로젝트 규모)

## 8. 에러 처리

| 시나리오 | 대응 |
|---|---|
| Langfuse pod down | LangChain handler 가 silently drop (애플리케이션 영향 X) + ERROR 로그 |
| Langfuse PG 디스크 가득 | PVC 수동 expand (5Gi → 10Gi, gp3 는 online resize 지원). team13 PVC quota 한도 = 5개 |
| Trace 전송 timeout | flush queue 누적 → 5분 후 drop (메모리 누수 방지) |
| OpenAI response 에 trace_id 없음 | best-effort metadata 만 기록 |
| LANGFUSE_* env 미설정 | handler 가 no-op 로 동작 (개발/CI 환경에서 부담 없이) |

## 9. 외부 의존성

- **Langfuse OSS v2.x** (안정 + 자원 최소 + maintenance mode 이지만 보안 패치 받음. v3 는 PVC quota 초과로 SKALA 환경 부적합)
- **Helm chart**: `langfuse/langfuse-k8s` (공식) — v2 호환 버전 (image tag 2.94)
- **lib**:
  ```toml
  langfuse = ">=2.50"     # Python SDK (v2 호환)
  ```
- **k8s 리소스** (SKALA 환경 기준):
  - Namespace: **`skala3-finalproj-class3-team13`** (team13, 학생 권한 admin 가능. 공용 observability namespace 는 매니저 권한 필요라 제외)
  - Service: `langfuse-web.skala3-finalproj-class3-team13.svc.cluster.local:3000`
  - Ingress: `langfuse.skala25a.project.skala-ai.com` (host pattern 은 클러스터 기존 loki/tempo/jaeger 와 동일 — `public-nginx` ingress class + ALB)
  - PVC: **5Gi gp3 (PG only)** — ClickHouse / Redis 불필요 (v2)
- **env** (axis-ai pod 에 주입):
  ```yaml
  LANGFUSE_HOST: http://langfuse-web.skala3-finalproj-class3-team13.svc.cluster.local:3000
  LANGFUSE_PUBLIC_KEY: pk-lf-...
  LANGFUSE_SECRET_KEY: sk-lf-...   # External Secrets Operator 또는 kubectl create secret 으로 주입
  ```

- **인증 / 권한**:
  - 신규 namespace 만들 필요 X (team13 내 설치 → cluster-admin 권한 없이 진행 가능)
  - Langfuse 자체 인증: 초기 admin email + signupDisabled=true (자기 가입 차단)
  - 매니저에게 ingress host 등록 신청 필요 (public-nginx 의 ALB target 추가)

## 10. State 흐름

axis-ai 의 state 에는 영향 없음. Side-effect 만 발생.

다만 `_langfuse_trace_id` (private key, "_" prefix) 를 state 에 임시 보존 → EvidenceAgent 가 `evidence_chain.provenance.langfuse_trace_id` 에 저장.

## 11. Provenance + Confidence

- **Provenance 연동** — ProvenanceTracker (`@with_provenance`) 가 trace_id 를 `evidence_chain.provenance.langfuse_trace_id` 로 기록. 그러면 card → trace tree 클릭 한 번으로 드릴다운.
- **Confidence 연동** — Langfuse score API 로 사용자 feedback (좋아요/싫어요) 를 trace 에 부착 가능. 이후 prompt eval 의 GT 로 활용.

## 12. 테스트 시나리오

| 유형 | 시나리오 | 검증 |
|---|---|---|
| Integration | 매시 ingestion 1 cycle | Langfuse UI 에 root trace + sub-spans (crawl / parse / classify / card_news / evidence) 트리 표시 |
| Integration | gen-search 호출 | trace 에 hybrid_search span + LLM span (SC ×3) 표시, RAG chunks metadata 보임 |
| Integration | chat turn (user_id 포함) | Langfuse 의 User 탭 에 user_id 별 trace 필터 가능 |
| Edge | Langfuse pod 정지 | LLM 호출 정상 + ERROR 로그 1줄/min (silent drop) |
| Edge | OPENAI 호출 fail | trace 가 status=error 로 마감 + error message 기록 |
| Edge | 1초당 100 span | flush_at=10 batch 로 정상 처리, drop 0 |

## 13. 모니터링

- KPI:
  - Langfuse 자체 health (Grafana 의 langfuse pod readiness)
  - trace 누락률 (예상 호출 수 vs 실제 trace 수) ≤ 1%
  - p95 trace flush latency ≤ 200ms (application 영향 측정)
- Retention 정책:
  - **trace** — 30일 (Langfuse v2 의 PG 에서 cleanup cron 으로 제거 — 본 design 의 후속 cron job 으로 구현 필요)
  - **usage_logs** (app PG) — **1년** (billing 영수)
  - **audit_logs** (app PG) — 1년 (compliance)

## 14. 구현 메모 + Changelog

### Helm 설치 (team13 namespace, v2)

```bash
# axis-infra/helm/langfuse/values.yaml 작성 후
helm repo add langfuse https://langfuse.github.io/langfuse-k8s
helm install langfuse langfuse/langfuse \
  -n skala3-finalproj-class3-team13 \
  -f axis-infra/helm/langfuse/values.yaml
```

> namespace 가 이미 존재 (team13). `--create-namespace` 불필요. ArgoCD 사용 시 별도 `Application` CR 작성 (skala-argocd 공용 사용 패턴 — `axis-infra/k8s/argocd/applications/langfuse.yaml`).

values.yaml 핵심 (v2, ClickHouse / Redis 비활성):

```yaml
# axis-infra/helm/langfuse/values.yaml (신규)
image:
  tag: "2.94"                        # v2 안정 버전. v3 는 PVC quota 초과로 미사용
postgresql:
  enabled: true                      # 내장 PG 사용 (별도 axis-postgres 와 분리)
  primary:
    persistence: { size: 5Gi, storageClass: gp3 }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 1Gi }
# clickhouse / redis : v2 에선 chart 가 deploy 안 함 (해당 섹션 자체 없음)
ingress:
  enabled: true
  className: public-nginx            # 클러스터 기존 loki/tempo/jaeger 패턴 일치
  hosts:
    - host: langfuse.skala25a.project.skala-ai.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts: [langfuse.skala25a.project.skala-ai.com]
      # ACM 또는 cert-manager 발급 인증서 (기존 ingress 와 동일)
auth:
  signupDisabled: true               # 초기 admin 1명 가입 후 회원가입 차단
env:
  - name: TELEMETRY_ENABLED
    value: "false"                   # Langfuse 내부 telemetry 끄기
  - name: NEXTAUTH_URL
    value: https://langfuse.skala25a.project.skala-ai.com
resources:
  limits:   { cpu: 2, memory: 4Gi }
  requests: { cpu: 500m, memory: 1Gi }
```

**예상 자원 사용**: 3 pod (web + worker + 내장 PG) + 1 PVC (5Gi) → team13 quota 잔여 (pods 23, PVC 2) 안에 fit ✓

### 신규 파일 (axis-ai)

- `src/observability/langfuse_client.py` (handler factory)
- `src/observability/__init__.py`
- pyproject.toml 의 dependencies 에 `langfuse>=2.50` 추가 (`uv add langfuse`)

### 신규 파일 (axis-backend)

- (선택) `AdminController.adminGetTraceLink(traceId)` → Langfuse URL 으로 302 redirect — UI 의 "trace 보기" 버튼이 이걸 통해 외부 Langfuse 로 이동

### 신규 파일 (axis-infra)

- `axis-infra/helm/langfuse/{Chart.yaml, values.yaml, README.md}` (namespace = team13)
- `axis-infra/k8s/argocd/applications/langfuse.yaml` (ArgoCD Application CR — skala-argocd 공용 사용 패턴)
- `axis-infra/argocd/applications/langfuse.yaml` (ArgoCD Application)
- `axis-infra/docs/OBSERVABILITY.md` (운영 가이드 — 트레이스 검색 / 비용 분석 / prompt eval)

### vs LangSmith

| 항목 | LangSmith (SaaS) | **Langfuse self-host (선택)** |
|---|---|---|
| 비용 | 호출당 과금 (월 ~$0.005/trace × 10K = $50/월) | ₩0 (자원 비용만, k8s 내 ~₩5K/월) |
| 기능 | Trace / eval / prompt mgmt / playground | 동등 + LLM Cost 자동 계산 |
| 데이터 보안 | OpenAI / LangChain 외부 SaaS 로 prompt 전송 | in-cluster only — SK 데이터 외부 유출 없음 |
| 통합 | LangChain native | LangChain native (callback handler 동일 패턴) + OpenAI drop-in |

### Changelog

- **v1 (제안, P9)** — Langfuse self-host + LangChain handler + provenance 연동 + 30일 retention 정책
