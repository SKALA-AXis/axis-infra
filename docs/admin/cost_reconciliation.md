# CostReconciliationJob — Design Plan

## 1. 메타

| 항목 | 값 |
|---|---|
| **이름** | `CostReconciliationJob` (daily ETL — vendor 청구 vs 자체 추정 비교) |
| **Supervisor** | (none — Spring `@Scheduled` 또는 axis-ai cron) |
| **상태** | 🔴 신규 (P9) — admin_page.md §4.5/4.6/4.7 정합. `usage_logs` (자체 추정) 는 V13 이 담당, 본 job 은 **청구 데이터 + 인프라 비용 별도 적재** |
| **Trigger** | Spring `@Scheduled(cron="0 0 3 * * *", zone="Asia/Seoul")` — 매일 03:00 KST |

## 2. 책임

**한 줄**: OpenAI Usage API + AWS Cost Explorer 의 청구 데이터를 `cost_daily_billed` / `infra_cost_daily` 에 적재 후 `usage_logs` 의 자체 추정값과 비교하여 variance > 10% 시 alert.

**구체적**:

1. **OpenAI Usage 동기화** — `GET https://api.openai.com/v1/usage?date=YYYY-MM-DD` 의 daily breakdown → `cost_daily_billed` UPSERT
2. **AWS Cost Explorer 동기화** — `GetCostAndUsage` API (Daily granularity, GroupBy=SERVICE) → `infra_cost_daily` UPSERT
3. **비교 산식** — `usage_logs` 의 추정값 vs `cost_daily_billed` 의 청구값 ÷ 차이 비율 → variance
4. **Alert** — variance > 10% (절대값) 시 운영자에게 이메일 (admin_page §6 의 "비용 스파이크" 룰 변형)
5. **₩ 환산** — billed USD × 환율 스냅샷 (자체 추정과 같은 `KRW_PER_USD=1350`) — 변동성 보존 위해 환율도 컬럼에 저장

## 3. 책임 NOT

- **실시간 cost enforcement** — TokenBudgetMiddleware (호출 직전 차단)
- **자체 추정** — `usage_logs` 가 INSERT (TokenBudget)
- **Prometheus exporter** — `metrics-exporter.md`
- **eval 비용** (feedback) — 분리 추적

## 4. 입력 스펙

```python
class OpenAiUsageRow(TypedDict):
    date: str                        # YYYY-MM-DD
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float

class AwsCostRow(TypedDict):
    date: str
    service: str                     # 'Amazon Elastic Compute Cloud - Compute'
    resource: str | None             # EC2 instance / RDS db / etc.
    cost_usd: float
```

## 5. 출력 스펙

### `cost_daily_billed` (V17 migration)

```sql
CREATE TABLE cost_daily_billed (
    id BIGSERIAL PRIMARY KEY,
    date DATE NOT NULL,
    vendor VARCHAR(40) NOT NULL,                -- 'openai' / 'anthropic' (확장 대비)
    model VARCHAR(60) NOT NULL,
    billed_cost_usd NUMERIC(12,6) NOT NULL,
    billed_input_tokens BIGINT,
    billed_output_tokens BIGINT,
    krw_per_usd NUMERIC(8,2),                   -- 환율 스냅샷
    billed_cost_krw NUMERIC(14,4) GENERATED ALWAYS AS (billed_cost_usd * krw_per_usd) STORED,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    source_uri VARCHAR(200),                    -- 'openai:/v1/usage?date=...'
    raw_payload JSONB,                          -- audit 용 원본 응답
    UNIQUE (date, vendor, model)
);
CREATE INDEX idx_cost_billed_date ON cost_daily_billed(date DESC);
```

### `infra_cost_daily` (V18 migration)

```sql
CREATE TABLE infra_cost_daily (
    id BIGSERIAL PRIMARY KEY,
    date DATE NOT NULL,
    service VARCHAR(80) NOT NULL,               -- AWS service code
    resource VARCHAR(120),
    cost_usd NUMERIC(12,4) NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    raw_payload JSONB,
    UNIQUE (date, service, COALESCE(resource, ''))
);
CREATE INDEX idx_infra_cost_date ON infra_cost_daily(date DESC, service);
```

### Variance report

```python
class CostVarianceReport(TypedDict):
    date: str
    items: list[dict]                # [{model, estimated_krw, billed_krw, variance_pct}]
    alert_triggered: bool
    threshold_pct: float             # 10
```

## 6. 알고리즘

### 6.1 OpenAI Usage sync (Java — Spring 측 권장)

OpenAI Usage API 는 **조직 admin key** 필요. dashboard 의 daily breakdown 을 JSON 으로 가져옴. v2 (2026) 에선 `GET /v1/usage` 가 admin scope 만 허용.

```java
@Service
public class CostSyncService {
    @Scheduled(cron = "0 0 3 * * *", zone = "Asia/Seoul")
    public void syncDaily() {
        LocalDate target = LocalDate.now(ZoneId.of("Asia/Seoul")).minusDays(1);
        try {
            List<OpenAiUsageRow> rows = openAiClient.fetchDailyUsage(target);
            costRepo.upsertBilled(rows, KRW_PER_USD);
        } catch (Exception e) {
            log.error("openai usage sync failed", e);
            alertService.notifyOpsByEmail("cost_sync_failed",
                Map.of("vendor", "openai", "date", target.toString(), "error", e.getMessage()));
        }
        try {
            List<AwsCostRow> awsRows = awsCostClient.fetchDailyCost(target);
            costRepo.upsertInfra(awsRows);
        } catch (Exception e) {
            log.error("aws cost sync failed", e);
            alertService.notifyOpsByEmail("cost_sync_failed",
                Map.of("vendor", "aws", "date", target.toString(), "error", e.getMessage()));
        }
        // variance check
        CostVarianceReport report = compareVariance(target);
        if (report.isAlertTriggered()) {
            alertService.notifyOpsByEmail("cost_variance_high", report.toMap());
        }
    }
}
```

### 6.2 Variance 비교 SQL

```sql
WITH estimated AS (
    SELECT
        :date::date AS date,
        model,
        SUM(input_tokens)  AS in_tok,
        SUM(output_tokens) AS out_tok,
        SUM(cost_krw)      AS est_krw
    FROM usage_logs
    WHERE occurred_date = :date AND success = true
    GROUP BY model
),
billed AS (
    SELECT model, billed_cost_krw AS bill_krw
    FROM cost_daily_billed
    WHERE date = :date AND vendor = 'openai'
)
SELECT
    e.model,
    e.est_krw,
    b.bill_krw,
    CASE WHEN b.bill_krw > 0
         THEN (e.est_krw - b.bill_krw) / b.bill_krw * 100
         ELSE NULL END AS variance_pct
FROM estimated e
LEFT JOIN billed b USING (model);
```

`abs(variance_pct) > 10` 인 row 가 1개 이상이면 alert.

### 6.3 AWS Cost Explorer 호출 (Java — boto3 equivalent)

```java
// boto3 → AWS SDK for Java v2
CostExplorerClient ce = CostExplorerClient.builder().region(Region.AP_NORTHEAST_2).build();
GetCostAndUsageRequest req = GetCostAndUsageRequest.builder()
    .timePeriod(DateInterval.builder().start(target.toString()).end(target.plusDays(1).toString()).build())
    .granularity(Granularity.DAILY)
    .metrics("UnblendedCost")
    .groupBy(GroupDefinition.builder().type(GroupDefinitionType.DIMENSION).key("SERVICE").build())
    .build();
GetCostAndUsageResponse res = ce.getCostAndUsage(req);
```

> IRSA: `cost-explorer-reader-sa` (신규 SA) — AWS IAM Role 에 `ce:GetCostAndUsage` 권한만 (least privilege).

## 7. LLM 모델 + token 예산

- LLM 미사용 → ₩0
- 본 job 자체는 비용 측정 도구이지 LLM 소비자 아님

## 8. 에러 처리

| 시나리오 | 대응 |
|---|---|
| OpenAI API 401 (잘못된 admin key) | sync skip + 이메일 alert + audit_log |
| OpenAI API 429 (rate limit) | 5분 backoff retry × 3 → 실패 시 다음 사이클 |
| AWS API throttle | exponential backoff (boto3 기본) |
| variance 계산 시 billed=0 (vendor 미응답) | NULL 처리 + report 에서 제외 |
| 환율 API down (KRW_PER_USD 갱신 시도 시) | 마지막 캐시값 유지 + 로그 |
| upsert 충돌 (vendor + model + date 중복) | ON CONFLICT DO UPDATE (latest fetched_at 보존) |

## 9. 외부 의존성

- **외부 API**: OpenAI Usage API (org admin key) + AWS Cost Explorer
- **DB**: `cost_daily_billed` (V17), `infra_cost_daily` (V18)
- **AWS IAM**: 신규 IRSA `cost-explorer-reader-sa` (ce:GetCostAndUsage)
- **lib (BE)**: `software.amazon.awssdk:costexplorer`, `okhttp` (OpenAI HTTP)

## 10. State 흐름

state 없음. Spring `@Scheduled` 의 단발성 cron job.

## 11. Provenance + Confidence

- `raw_payload` jsonb 컬럼이 원본 응답 보존 (audit 시 재계산 가능)
- 환율 스냅샷 `krw_per_usd` 컬럼으로 재현성 보장

## 12. 테스트 시나리오

| 유형 | 시나리오 | 검증 |
|---|---|---|
| Unit | variance 계산 (est=1100, bill=1000) | variance_pct=10 → alert 안 함 |
| Unit | variance 계산 (est=1300, bill=1000) | variance_pct=30 → alert |
| Integration | OpenAI mock 응답 → upsert | cost_daily_billed row 1개 |
| Integration | 같은 date 2번 sync | UPSERT — 1 row 만 (latest fetched_at) |
| Edge | OpenAI 401 | DB 변동 없음 + 알람 이메일 1회 |
| Edge | AWS throttle 3회 | retry 후 성공 또는 skip |

## 13. 모니터링

- KPI:
  - sync 성공률 ≥ 99% (월 1회 fail 허용)
  - 평균 variance ≤ 5% (모델 추정값 정확도)
  - sync latency ≤ 30초 (API 응답 + DB upsert)
- Grafana panel (Folder C FinOps):
  - 일별 추정 (`usage_logs`) vs 청구 (`cost_daily_billed`) line × 2
  - variance bar (모델별)
  - 월 누적 budget gauge (₩150K/월 = ₩5K/일 × 30)
  - 인프라 비용 service 별 stacked bar
- Retention: 5년 (회계 audit)

## 14. 구현 메모 + Changelog

### 신규 파일

- **BE**: `axis-backend/src/main/java/com/skala/axis/cost/CostSyncService.java` + `OpenAiUsageClient.java` + `AwsCostExplorerClient.java`
- **axis-ai**: (없음 — 본 job 은 Java 단독)
- **k8s**: `cost-explorer-reader-sa` ServiceAccount + IAM Role (axis-infra/k8s/base/cost-explorer-sa.yaml)

### 신규 마이그레이션

- **V17** — `cost_daily_billed`
- **V18** — `infra_cost_daily`

### 환경변수 (신규)

```bash
OPENAI_ADMIN_API_KEY=sk-admin-...    # org admin scope (개인 key 불가)
AWS_REGION=ap-northeast-2
KRW_PER_USD=1350                      # config (월 1회 PR 로 갱신)
COST_VARIANCE_THRESHOLD=10
```

### Backend 연동

- `AdminController.adminGetUsage()` 응답에 `cost_daily_billed.billed_cost_krw` 도 함께 (admin_page §5 Folder C 의 "추정 vs 청구")
- 신규: `GET /api/admin/usage/billed-vs-estimated?from=&to=` (variance report 직접 조회)

### Changelog

- **v1 (제안, P9)** — admin_page §4.5/4.6/4.7 정합. V17 + V18 마이그레이션 + Spring @Scheduled cron + IRSA SA
