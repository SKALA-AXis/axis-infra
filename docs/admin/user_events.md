# UserEventTracker — Design Plan

## 1. 메타

| 항목 | 값 |
|---|---|
| **이름** | `UserEventTracker` (BE 주도, axis-ai read-only) |
| **Supervisor** | (none — BE controller + frontend SDK) |
| **상태** | 🔴 신규 (P9) — frontend / BE 모두 미구현. admin_page.md §4.2 의 `user_events` 테이블 + tracker SDK 정합 |
| **Trigger** | 모든 frontend 인터랙션 (page_view / search / card_click / feedback / regenerate / login / logout / alert_read / export) |

## 2. 책임

**한 줄**: 사용자 행동 이벤트를 timestamp 단위로 기록하여 DAU/WAU/MAU + 기능 사용률 + zero-result 비율 + 사용자별 호출 Top N 측정의 데이터 기반 제공.

**구체적**:

1. **Frontend SDK** — `tracker.track('event_type', props)` API. 페이지 마운트 / 클릭 / 검색 시 자동 호출
2. **BE 적재** — `POST /api/events` (batch 권장, 5개씩 또는 10초 마다 flush) → `user_events` INSERT
3. **PII 가드** — event_props 의 검색어 / 입력값은 200자 + raw 보존 OK (admin_page §7 의 PII 정책: jsonb 자체에 PII 직저장 금지). 추후 sensitive 키 필터링
4. **axis-ai 활용** — 추후 (W9+) 사용자 검색 패턴 분석 / 트렌딩 키워드 추출의 입력. 본 design 단계에선 read-only

## 3. 책임 NOT

- **LLM 호출 trace** — `usage_logs` + Langfuse
- **관리자 / 시스템 액션** — `audit_logs` (변경불가)
- **콘텐츠 평가** — `feedback` (FeedbackAgent 별도)
- **시계열 메트릭** — Prometheus (`page_view_total{route}` counter 도 같이 push 가능하나 단위가 다름)

## 4. 입력 스펙

```python
# axis-ai 가 직접 INSERT 하지 않음. BE 가 contract 소비. 다만 axis-ai 의 추후 분석 batch 가 SELECT.

class UserEventInput(TypedDict):
    user_id: int | None              # None = 미인증 (게스트, login 이벤트만)
    session_id: str                  # frontend localStorage UUID
    event_type: str                  # 아래 표
    event_props: dict                # 자유 형식 (route, query, card_id 등)
    ip: str                          # request IP (BE 가 세팅)
    user_agent: str                  # BE 가 세팅
    occurred_at: str                 # ISO8601 (frontend timestamp, BE 시계 보정 옵션)
```

### Event Type 카탈로그 (v1 — 10종)

| event_type | 발화 시점 | 핵심 props |
|---|---|---|
| `page_view` | 화면 진입 (route push) | `{route, referrer}` |
| `search` | SearchView 또는 FloatingAiChat 의 검색 trigger | `{query, mode: 'hybrid'\|'gen', result_count, zero_result: bool}` |
| `card_click` | CardNews / Briefing 카드 클릭 | `{card_id, peer_id, position}` |
| `card_share` | 공유 버튼 | `{card_id, target: 'link'\|'email'}` |
| `bookmark_add` / `bookmark_remove` | 북마크 토글 | `{card_id}` |
| `feedback_submit` | 👍/👎 / rating 제출 | `{artifact_id, artifact_type, thumbs}` (실 내용은 `feedback` 테이블) |
| `regenerate` | "재생성" 버튼 (Mixer / Insight / Briefing) | `{artifact_type, artifact_id, reason?}` |
| `chat_message` | FloatingAiChat 메시지 전송 | `{session_id, intent?}` |
| `login` / `logout` / `login_fail` | Auth | `{method: 'password'}` (실 결과는 audit_logs) |
| `export` | PDF / Excel export | `{artifact_type, artifact_id, format}` |

## 5. 출력 스펙

신규 DB 테이블 `user_events` (V15 migration, public schema — P9+ analytics schema 분리 고려):

```sql
CREATE TABLE user_events (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id BIGINT,                              -- nullable: 게스트 (login 이벤트 등)
    session_id UUID,
    event_type VARCHAR(40) NOT NULL,
    event_props JSONB NOT NULL DEFAULT '{}'::jsonb,
    ip INET,
    user_agent TEXT,
    request_id UUID                              -- BE MDC trace id
);
CREATE INDEX idx_user_events_type_time ON user_events(event_type, occurred_at DESC);
CREATE INDEX idx_user_events_user_time ON user_events(user_id, occurred_at DESC) WHERE user_id IS NOT NULL;
CREATE INDEX idx_user_events_props ON user_events USING GIN (event_props);
```

> P9+ 확장 (volume > 500K/일 시): 월 RANGE 파티셔닝 도입 + `analytics` schema 분리 + grafana_ro 계정 read 권한.

## 6. 알고리즘

### 6.1 Frontend SDK (TypeScript)

```typescript
// axis-frontend/src/lib/tracker.ts (신규)
import { v4 as uuid } from "uuid";

const SESSION_ID = (() => {
  let s = localStorage.getItem("axis_session_id");
  if (!s) { s = uuid(); localStorage.setItem("axis_session_id", s); }
  return s;
})();

let queue: any[] = [];
let flushTimer: any = null;

export function track(event_type: string, props: object = {}) {
  queue.push({
    event_type,
    event_props: props,
    session_id: SESSION_ID,
    occurred_at: new Date().toISOString(),
  });
  if (queue.length >= 5) flush();
  else if (!flushTimer) flushTimer = setTimeout(flush, 10_000);
}

async function flush() {
  if (queue.length === 0) return;
  const batch = queue.splice(0);
  clearTimeout(flushTimer); flushTimer = null;
  try {
    await fetch("/api/events", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ events: batch }),
      credentials: "include",
    });
  } catch { /* silent — drop 허용 */ }
}

window.addEventListener("beforeunload", flush);
```

### 6.2 BE 적재 (Spring)

```java
@PostMapping("/api/events")
public ApiResponse trackEvents(@RequestBody EventBatch batch, HttpServletRequest req) {
    long userId = SecurityContextHolder.getCurrentUserIdOrNull();
    String ip = WebUtils.getClientIp(req);
    String ua = req.getHeader("User-Agent");
    eventService.saveBatch(batch.getEvents(), userId, ip, ua);
    return ApiResponse.ok();
}
```

**Sync INSERT 유지** (Q2=B 결정). 일 호출 < 50K 수준이면 PG 직접 적재 충분. P9+ 에서 Redis Stream 도입 고려 (admin_page §3 의 async 원칙).

### 6.3 axis-ai 의 활용 (W9+ 분석 batch)

```python
# 예시 — 추후 SearchSuggestAgent 가 zero-result query top 20 추출
SELECT event_props->>'query' AS q, COUNT(*) AS cnt
FROM user_events
WHERE event_type = 'search'
  AND (event_props->>'zero_result')::bool = true
  AND occurred_at > NOW() - INTERVAL '7 days'
GROUP BY q
ORDER BY cnt DESC LIMIT 20;
```

이런 batch 가 SearchSuggestAgent / KeywordExtractionAgent 의 보조 입력으로 활용 가능. 본 design 단계에선 schema 만.

## 7. LLM 모델 + token 예산

- LLM 미사용 → ₩0

## 8. 에러 처리

| 시나리오 | 대응 |
|---|---|
| Frontend offline → flush fail | localStorage 에 max 100건 캐싱 후 재시도 |
| BE INSERT 실패 (DB busy) | retry 1회 → log + drop (track 은 best-effort) |
| event_props 가 100KB 초과 | BE 가 400 거절 + `event_too_large` 로그 |
| 게스트 (user_id null) + session_id null | BE 가 새 session_id 생성하여 응답 헤더로 전달 |
| 비정상 event_type (카탈로그 외) | accept + log 경고 (확장 여지 유지) |

## 9. 외부 의존성

- **DB**: `user_events` (V15 신규)
- **BE**: Spring, JPA
- **Frontend**: localStorage / fetch
- **lib (axis-ai 분석)**: SQLAlchemy 만

## 10. State 흐름

axis-ai LangGraph state 와 무관. BE 가 sync INSERT.

## 11. Provenance + Confidence

- 본 테이블 자체가 *원시 이벤트* — provenance 무관
- 다만 `request_id` (BE MDC) 보존 → audit_logs / usage_logs 와 join 가능

## 12. 테스트 시나리오

| 유형 | 시나리오 | 검증 |
|---|---|---|
| Unit | `tracker.track('search', {query: 'AX'})` | 큐 길이 1 |
| Unit | 5개 push | flush 자동 발화 |
| Unit | 1개 push 후 10초 | flush 자동 발화 |
| Integration | FE → BE POST /api/events × 5 | DB 에 5 row INSERT |
| Edge | offline → online 복귀 | 누적 캐시 flush |
| Edge | event_props 200KB | BE 400 거절 |
| Edge | 게스트 첫 방문 | session_id 발급 |

## 13. 모니터링

- KPI:
  - 일 이벤트 수 (DAU 사용자 × 평균 30~50 이벤트)
  - flush 실패율 ≤ 1%
  - p95 BE 적재 latency ≤ 50ms
- Grafana panel (Folder D Users & Engagement):
  - DAU / WAU / MAU timeseries
  - event_type 별 stack bar
  - zero_result 검색 비율
  - 사용자별 호출 Top 10 (anomaly 감지)
- Retention: 13개월 (admin_page §7 일치)

## 14. 구현 메모 + Changelog

### 신규 파일

- **Frontend**: `axis-frontend/src/lib/tracker.ts`
- **BE**: `EventController.java` + `EventService.java` + `UserEvent.java` entity
- **axis-ai**: (없음 — 추후 분석 batch 추가 시 `src/analytics/event_query.py`)

### 신규 마이그레이션

- **V15** — `user_events` 테이블 (위 §5 schema)

### Backend 연동

- 신규: `POST /api/events` (Spring controller)
- API 01-surface §2.14 (admin/observability events) 에 등록

### Changelog

- **v1 (제안, P9)** — admin_page §4.2 정합 + 10 event_type 카탈로그 확정
