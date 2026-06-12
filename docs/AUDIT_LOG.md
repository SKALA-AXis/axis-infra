# AuditLogMiddleware — Design Plan

## 1. 메타

| 항목 | 값 |
|---|---|
| **이름** | `AuditLogMiddleware` (cross-cutting — BE 측 + axis-ai 측 양쪽) |
| **Supervisor** | (none — BE controller interceptor + axis-ai middleware) |
| **상태** | 🔴 신규 — `/api/admin/audit-logs` 가 BE fixture 만 반환. 실제 audit_logs 테이블 / 기록 로직 없음 |
| **Trigger** | (1) BE 의 모든 admin / settings 변경 + 로그인 / (2) axis-ai 의 pipeline_run / weak_signal_run / briefing_generate 같은 의도적 이벤트 |

### RBAC 3-tier (admin_page §2 정합)

| role | 권한 | 보는 영역 |
|---|---|---|
| `super_admin` | 전체 audit_logs READ + PII 마스킹 해제 | 모든 row |
| `ops_admin` | 시스템 / 파이프라인 action 만 READ, PII 마스킹 유지 | actor_kind in ('scheduler','admin') 한정 |
| `viewer` | 본인 row 만 READ (`/api/settings/access-logs`) | user_id=self |

BE Spring Security `@PreAuthorize("hasRole('SUPER_ADMIN')")` 등으로 강제.

## 2. 책임

**한 줄**: 사용자 / 시스템 / 운영자의 의도적 액션을 변경 불가능한 로그로 기록하여 보안 감사 + 사고 조사 + compliance 충족.

**구체적**:

1. **BE 측 (Java AOP)**
   - `@Auditable` annotation 또는 `AuditInterceptor` 가 admin / settings / auth controller 감싸기
   - 캡처 항목: user_id, action_type, resource_type, resource_id, ip, user_agent, payload_summary, ts
2. **axis-ai 측 (Python decorator)**
   - `@audit("pipeline_run", "company_list")` 식 명시적 marker
   - 캡처 항목: caller (BE 호출 또는 schedule), trigger_type, input_summary, run_id, completed_at, outcome
3. **DB write-once** — append-only, UPDATE/DELETE 금지 (트리거로 protect)
4. **Read** — `/api/admin/audit-logs` (필터: user / action / date / resource) + `/api/settings/access-logs` (개인 본인 로그인 이력)
5. **Retention** — 1년 (이후 cold storage 옮김, S3 access logs 와 동일 정책)

## 3. 책임 NOT

- **시스템 메트릭** — V30 이후 active `pipeline_logs` 테이블 없음. 필요 시 Prometheus 또는 `legacy_records` archive 별도 조회
- **LLM token usage** — usage_logs (TokenBudgetMiddleware)
- **에러 trace** — application logs (Loki / OpenSearch)
- **personally identifiable information masking** — 본 middleware 가 마킹만 (`sensitive=true`), 마스킹은 SettingsController 의 read 시점

## 4. 입력 스펙

```python
# axis-ai 측 (BE 는 Java AOP 패턴, 별도)
class AuditContext(TypedDict):
    user_id: int | None              # axis-ai 는 보통 None (BE 가 호출)
    actor_kind: Literal["user", "system", "scheduler", "admin"]
    actor_label: str                 # "scheduler:weak_signal" or "user_email"
    action_type: str                 # "pipeline_run" / "briefing_generate"
    resource_type: str | None        # "card_news" / "weak_signal_card"
    resource_id: str | None
    payload_summary: dict            # 요청의 핵심 (PII 제외)
    ip: str | None
    user_agent: str | None
```

## 5. 출력 스펙

신규 DB 테이블 `audit_logs` (V14 migration):

```sql
CREATE TABLE audit_logs (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor_kind VARCHAR(20) NOT NULL,           -- user / system / scheduler / admin
    actor_label VARCHAR(200),                  -- email or scheduler-name
    user_id BIGINT REFERENCES users(id),       -- nullable (system actions)
    action_type VARCHAR(80) NOT NULL,          -- pipeline_run / settings_update / login / ...
    resource_type VARCHAR(40),                 -- card_news / alert_rule / peer / ...
    resource_id VARCHAR(80),
    ip INET,
    user_agent TEXT,
    payload JSONB,                              -- {filters: {...}, before: {...}, after: {...}}
    request_id UUID,                            -- trace id (BE 측 MDC)
    outcome VARCHAR(20) NOT NULL DEFAULT 'success',  -- success / fail / denied
    error_message TEXT,
    CONSTRAINT audit_logs_no_update CHECK (true)
);
CREATE INDEX idx_audit_user_date ON audit_logs(user_id, occurred_at DESC);
CREATE INDEX idx_audit_action_date ON audit_logs(action_type, occurred_at DESC);
CREATE INDEX idx_audit_resource ON audit_logs(resource_type, resource_id);
-- INSERT-only trigger
CREATE OR REPLACE FUNCTION audit_logs_block_change() RETURNS TRIGGER AS $$
BEGIN RAISE EXCEPTION 'audit_logs is append-only'; END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_logs_block_change
BEFORE UPDATE OR DELETE ON audit_logs
FOR EACH ROW EXECUTE FUNCTION audit_logs_block_change();
```

## 6. 알고리즘

### 6.1 BE 측 — Spring AOP

```java
@Aspect
@Component
public class AuditAspect {
    @Around("@annotation(auditable)")
    public Object audit(ProceedingJoinPoint pjp, Auditable auditable) throws Throwable {
        var ctx = AuditContext.builder()
            .userId(SecurityContextHolder.getCurrentUserId())
            .actorKind("user")
            .actionType(auditable.action())
            .resourceType(auditable.resource())
            .ip(WebUtils.getClientIp())
            .userAgent(WebUtils.getUserAgent())
            .payloadSummary(redactPii(pjp.getArgs()))
            .requestId(MDC.get("request_id"))
            .build();
        try {
            Object result = pjp.proceed();
            auditService.write(ctx.success());
            return result;
        } catch (Throwable e) {
            auditService.write(ctx.fail(e.getMessage()));
            throw e;
        }
    }
}

// 사용
@Auditable(action = "alert_rule.update", resource = "alert_rule")
@PutMapping("/api/alerts/rules/{ruleId}")
public Map<String, Object> updateAlertRule(...) { ... }
```

### 6.2 axis-ai 측 — Python decorator

```python
def audit(action_type: str, resource_type: str | None = None):
    def deco(func):
        @wraps(func)
        async def wrapper(*args, **kwargs):
            req = kwargs.get("request_meta", {})
            ctx = AuditContext(
                user_id=req.get("user_id"),
                actor_kind=req.get("actor_kind", "scheduler"),
                actor_label=req.get("actor_label", "system"),
                action_type=action_type,
                resource_type=resource_type,
                resource_id=kwargs.get("resource_id"),
                payload_summary=_summarize(kwargs),
                ip=req.get("ip"),
                user_agent=req.get("user_agent"),
            )
            outcome, err = "success", None
            try:
                result = await func(*args, **kwargs)
                return result
            except Exception as e:
                outcome, err = "fail", str(e)[:500]
                raise
            finally:
                await save_audit_log(ctx, outcome=outcome, error_message=err)
        return wrapper
    return deco

# 사용
@audit(action_type="pipeline_run", resource_type="ingestion")
async def run_pipeline(payload: PipelineRunRequest, request_meta: dict): ...
```

### 6.3 Payload PII redaction

```python
PII_KEYS = {"password", "email", "phone", "token", "refresh_token"}

def _summarize(kwargs: dict, max_depth=2) -> dict:
    def redact(v, depth=0):
        if isinstance(v, dict):
            if depth >= max_depth: return "...truncated"
            return {k: ("***" if k.lower() in PII_KEYS else redact(x, depth+1))
                    for k, x in v.items()}
        if isinstance(v, list):
            return f"<list len={len(v)}>"
        if isinstance(v, str) and len(v) > 200:
            return v[:200] + "...truncated"
        return v
    return redact(kwargs)
```

## 7. LLM 모델 + token 예산

- LLM 미사용 → ₩0

## 8. 에러 처리

| 시나리오 | 대응 |
|---|---|
| audit_logs INSERT 실패 | application 동작은 정상 + ERROR 로그 + Grafana alert |
| user_id 미해석 (anonymous) | actor_kind="user", user_id=null, actor_label="anonymous" |
| payload 너무 큼 (> 16KB) | top-level keys 만 + `_truncated=true` |
| Audit trigger 가 UPDATE 시도 차단 (정상) | 호출자가 잘못 — alert |

## 9. 외부 의존성

- BE: Spring AOP, MDC (trace id)
- axis-ai: none (pure Python + asyncpg)
- DB: `audit_logs` (V14 신규)

## 10. State 흐름

state 무관. middleware 가 부수적으로 DB INSERT.

## 11. Provenance + Confidence

- Audit 자체가 provenance 의 일부 — ProvenanceTracker 의 `request_id` 를 audit_logs.request_id 와 join 하면 "card_news.id → evidence.provenance.request_id → audit_logs (누가 trigger 했는지)" 추적 가능.

## 12. 테스트 시나리오

| 유형 | 시나리오 | 검증 |
|---|---|---|
| Unit | redact (password 포함 dict) | password 키 값 "***" |
| Unit | summarize (long string) | 200 char + "...truncated" |
| Unit | summarize (large list) | "<list len=N>" |
| Integration | BE PUT /api/alerts/rules/{id} | audit_logs row INSERT 됨 (action=alert_rule.update) |
| Integration | axis-ai POST /pipeline/run | audit_logs row INSERT (actor_kind=scheduler 또는 admin) |
| Edge | UPDATE audit_logs WHERE id=N | trigger 가 raise (정상) |
| Edge | INSERT 실패 (DB down) | application 응답은 정상 + ERROR 로그 |
| Edge | anonymous /api/auth/login fail | user_id=null + outcome=fail + error_message="invalid credentials" |

## 13. 모니터링

- KPI:
  - audit_logs INSERT 실패율 ≤ 0.1%
  - login fail 비율 (sliding 1h) — 5% 초과 시 alert (credential stuffing 의심)
  - admin action 누락 0% (sampling 검증)
- **Alert 채널**: **이메일 + in_app 알림만** (Slack 폐기 2026-05-10, project_slack_deprecation 정책). admin/admin_page.md §6 의 "Slack #ops / #security" 참조는 본 프로젝트에서 이메일 + in_app 으로 매핑됨
- Grafana panel (admin_page §5 Folder E System & Security):
  - 일일 audit row 수 (분당 평균)
  - top action_type
  - fail / denied 비율
  - login fail 시계열 (IP top N)
- Retention: 1년 후 `axis-cold-storage` S3 bucket 이동 + DB 삭제 (별도 cron). admin_page §7 의 5년 retention 권장은 compliance 가 강화될 때까지 보류 (현 1년 = 개인정보보호법 §29 최소치)
- **Schema 분리 (P9+ 옵션)** — 현재 V1 = `public.audit_logs`. admin_page §10 의 `analytics.audit_logs` 분리 + `grafana_ro` 읽기 전용 계정은 P9+ 확장 시 도입 (Q1=B 결정: v1 은 public schema 단순화)

## 14. 구현 메모 + Changelog

### 핵심 파일 (신규 P9)

- **BE**: `axis-backend/src/main/java/com/skala/axis/audit/AuditAspect.java` + `Auditable.java` annotation + `AuditService.java`
- **axis-ai**: `src/middleware/audit.py` decorator + `src/db/audit_logs.py` DAO

### 신규 마이그레이션

- **V14** — `audit_logs` 테이블 + insert-only trigger (위 §5 schema)

### Backend 연동

- `AdminController.adminGetAuditLogs()` — fixture 제거 → `AuditService.search(filter)` 실 구현
- `SettingsController.getMyAccessLogs()` — fixture 제거 → `AuditService.searchByUser(self, action=['login','logout','login_fail'])` 실 구현
- 모든 admin / settings PUT/POST/DELETE endpoint 에 `@Auditable` 부착
- AuthController.login() / logout() 에 `@Auditable(action="auth.login")`

### Compliance 노트

- 회사 정보보안 정책 §4.2 (변경 불가 audit log 보관 1년 이상) 충족
- 개인정보보호법 §29 (접근기록 보관) 충족 — access_logs 도 audit_logs 의 view

### Changelog

- **v1 (제안, P9)** — V14 신설 + AOP/decorator + admin endpoint 활성. 현재는 fixture 만 존재
