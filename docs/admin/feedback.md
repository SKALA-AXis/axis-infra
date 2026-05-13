# FeedbackAgent — Design Plan

## 1. 메타

| 항목 | 값 |
|---|---|
| **이름** | `FeedbackAgent` (BE primary write + Langfuse score push + axis-ai eval batch read) |
| **Supervisor** | (cross-cutting — admin observability) |
| **상태** | 🔴 신규 (P9) — frontend / BE / Langfuse 모두 미구현. admin_page.md §4.3 정합 |
| **Trigger** | (1) 사용자 클릭 (👍/👎, ⭐ rating, 코멘트, "검토 필요" 신고) (2) periodic eval batch (W10+) |

## 2. 책임

**한 줄**: 사용자의 카드/브리핑/믹서/인사이트/챗 응답에 대한 평가를 `feedback` 테이블에 적재 + Langfuse trace 의 score 로 push 하여 prompt eval 의 ground truth 제공.

**구체적**:

1. **수신** — frontend `POST /api/cards/{id}/feedback`, `POST /api/briefings/{id}/feedback`, `POST /api/insights/{id}/feedback`, `POST /api/mixer/{id}/feedback`, `POST /api/chat/turns/{turn_id}/feedback`
2. **이중 적재** — `feedback` 테이블 (영구 비즈니스 데이터) + Langfuse score API (analytics drill-down)
3. **링크** — `feedback.langfuse_trace_id` 가 `evidence_chain.provenance.langfuse_trace_id` 또는 chat_sessions.turns[i].langfuse_trace_id 와 일치
4. **batch eval (W10+)** — `news_quality_eval` job 이 prompt_version 별 thumbs_up / down 집계 → 약한 prompt 식별

## 3. 책임 NOT

- **자동 평가** — LLM-as-judge eval 별도 (Langfuse 의 evaluator 기능 활용, W10+)
- **사용자 행동 추적** — UserEventTracker (`feedback_submit` 이벤트는 거기서)
- **콘텐츠 수정** — feedback 은 read-only 평가, 카드/브리핑 본문은 immutable

## 4. 입력 스펙

```python
class FeedbackInput(TypedDict):
    artifact_type: Literal["card", "briefing", "insight", "mixer", "chat_turn"]
    artifact_id: str                # CN-... / BR-... / IN-... / MX-... / chat_session_id:turn_idx
    thumbs: Literal["up", "down"] | None
    rating: int | None              # 1~5 (옵션)
    comment: str | None             # 자유 텍스트 (≤ 1000 chars)
    reported_issue: str | None      # "hallucination" / "outdated" / "irrelevant" / "low_quality" / "other"
    # user_id, occurred_at 은 BE 가 세팅
```

## 5. 출력 스펙

신규 DB 테이블 `feedback` (V16 migration):

```sql
CREATE TABLE feedback (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id BIGINT NOT NULL,
    artifact_type VARCHAR(20) NOT NULL,         -- card / briefing / insight / mixer / chat_turn
    artifact_id VARCHAR(80) NOT NULL,
    thumbs VARCHAR(4),                          -- up / down / null
    rating INT CHECK (rating BETWEEN 1 AND 5),
    comment TEXT,
    reported_issue VARCHAR(40),                 -- enum 위 §4 reported_issue
    langfuse_trace_id VARCHAR(80),              -- Langfuse trace pointer (eval drill-down)
    langfuse_score_id VARCHAR(80),              -- Langfuse 가 발급한 score id (멱등성)
    metadata JSONB                              -- {prompt_version, llm_model, agent}
);
CREATE INDEX idx_feedback_artifact ON feedback(artifact_type, artifact_id, created_at DESC);
CREATE INDEX idx_feedback_user ON feedback(user_id, created_at DESC);
CREATE INDEX idx_feedback_issue ON feedback(reported_issue, created_at DESC) WHERE reported_issue IS NOT NULL;
```

## 6. 알고리즘

### 6.1 BE 처리 (Spring)

```java
@PostMapping("/api/cards/{id}/feedback")
@Auditable(action = "feedback.card", resource = "card")
public ApiResponse submitCardFeedback(@PathVariable String id, @RequestBody FeedbackInput input) {
    long userId = SecurityContextHolder.getCurrentUserId();

    // 1) artifact 의 langfuse_trace_id 조회
    String traceId = cardNewsService.getLangfuseTraceId(id);  // evidence_chain.provenance.langfuse_trace_id

    // 2) DB INSERT
    Feedback fb = feedbackService.save(userId, "card", id, input, traceId);

    // 3) Langfuse score push (async, fail tolerant)
    if (traceId != null) {
        langfuseClient.scoreAsync(
            traceId,
            "user_feedback",
            mapThumbsToScore(input.getThumbs(), input.getRating()),
            input.getComment()
        ).thenAccept(scoreId -> feedbackService.updateScoreId(fb.getId(), scoreId));
    }

    // 4) reported_issue == "hallucination" 이면 즉시 alert
    if ("hallucination".equals(input.getReportedIssue())) {
        alertService.notifyOpsByEmail("hallucination_report",
            Map.of("card_id", id, "trace_id", traceId, "user_id", userId));
    }

    return ApiResponse.ok();
}

double mapThumbsToScore(String thumbs, Integer rating) {
    if (rating != null) return rating / 5.0;       // 0.2 ~ 1.0
    if ("up".equals(thumbs)) return 1.0;
    if ("down".equals(thumbs)) return 0.0;
    return 0.5;  // neutral
}
```

### 6.2 axis-ai eval batch (W10+, scheduled 주 1회)

```python
# src/analytics/feedback_eval.py (신규, W10+)
async def weekly_prompt_quality_report():
    """prompt_version 별 thumbs_down 비율 계산. > 20% 면 alert."""
    rows = db.execute("""
        SELECT
            metadata->>'prompt_version' AS prompt_version,
            metadata->>'agent' AS agent,
            COUNT(*) FILTER (WHERE thumbs='down') * 1.0 / COUNT(*) AS down_rate,
            COUNT(*) AS n
        FROM feedback
        WHERE created_at > NOW() - INTERVAL '7 days'
          AND metadata->>'prompt_version' IS NOT NULL
        GROUP BY 1, 2
        HAVING COUNT(*) >= 5
        ORDER BY down_rate DESC
    """).fetchall()

    weak = [r for r in rows if r.down_rate > 0.20]
    if weak:
        send_email_alert(
            subject=f"[axis] 약한 prompt {len(weak)}개 발견",
            body=render_weak_prompt_table(weak),
        )
```

### 6.3 멱등성 (중복 클릭 방지)

같은 user + 같은 artifact 에 30분 내 재제출 → 기존 row UPDATE (override, latest wins). BE 가 처리:

```sql
INSERT INTO feedback (user_id, artifact_type, artifact_id, ...)
VALUES (...)
ON CONFLICT (user_id, artifact_type, artifact_id)
WHERE created_at > NOW() - INTERVAL '30 min'
DO UPDATE SET thumbs = EXCLUDED.thumbs, rating = EXCLUDED.rating, ...;
```

> Partial unique index 도입 후 가능. V16 migration 에 포함.

## 7. LLM 모델 + token 예산

- 본 agent 자체 LLM 미사용 → ₩0
- W10+ eval batch 는 LLM-as-judge 옵션 시 ~₩100/주 (gpt-4o-mini 로 down 케이스 자동 분류). 본 design v1 에선 산식만.

## 8. 에러 처리

| 시나리오 | 대응 |
|---|---|
| artifact_id 가 존재하지 않음 | 404 |
| user_id null (게스트) | 401 (feedback 은 인증 필수) |
| Langfuse push 실패 | DB 는 정상 적재 + `langfuse_score_id=null` + 로그 (sync 차단 X) |
| 같은 artifact 6회 연속 thumbs_down (1 user) | rate-limit 후 자동 차단 + audit_log |
| comment > 1000 chars | 400 BadRequest |
| hallucination 신고 처리 실패 (이메일 전송 fail) | DB 적재는 정상 + retry 1회 |

## 9. 외부 의존성

- **DB**: `feedback` (V16 신규)
- **BE → Langfuse**: `langfuse-java` SDK 의 score API (또는 HTTP raw POST `/api/public/scores`)
- **lib (axis-ai)**: SQLAlchemy (eval batch 만)
- **외부 API**: 없음 (LLM-as-judge eval 은 옵션)

## 10. State 흐름

LangGraph state 와 무관. BE controller 의 단발성 처리.

## 11. Provenance + Confidence

- 본 테이블 자체가 *외부 평가* — provenance 무관
- 대신 `langfuse_trace_id` 가 평가 대상 trace 로 backlink → admin UI 의 "이 평가가 어떤 prompt/응답에 대한 건지" 클릭 한 번

## 12. 테스트 시나리오

| 유형 | 시나리오 | 검증 |
|---|---|---|
| Unit | thumbs=up | rating 없으면 score=1.0 push |
| Unit | rating=3 | score=0.6 push |
| Integration | POST /api/cards/{id}/feedback × 2 (같은 user, 30분 내) | row 1개 (UPSERT 동작) |
| Integration | reported_issue=hallucination | alert 이메일 발송 1회 |
| Edge | Langfuse 다운 | DB 적재 OK + langfuse_score_id=null |
| Edge | comment 1500 chars | 400 |
| Edge | 1 user 가 1 card 에 6회 thumbs_down | rate-limit 발화 |

## 13. 모니터링

- KPI:
  - 일 feedback 수 (DAU 의 ~10% 가 1건 이상 제출 expected)
  - thumbs_up : thumbs_down 비율 ≥ 4 : 1
  - reported_issue=hallucination 비율 ≤ 1%
  - Langfuse push 성공률 ≥ 95%
- Grafana panel (Folder B Quality):
  - prompt_version 별 thumbs ratio
  - hallucination 신고 시계열
  - 평균 rating
- Retention: 영구 (eval ground truth 로 가치)

## 14. 구현 메모 + Changelog

### 신규 파일

- **BE**: `FeedbackController.java` + `FeedbackService.java` + `Feedback.java` entity + `LangfuseClient.java` (score API wrapper)
- **axis-ai (W10+)**: `src/analytics/feedback_eval.py` (cron)
- **Frontend**: 카드/브리핑/믹서/인사이트 detail 화면에 👍/👎 + ⭐ + comment textarea

### 신규 마이그레이션

- **V16** — `feedback` 테이블 + partial unique index for upsert

### API surface 추가 (`axis-infra/docs/API_SURFACE.md` 와 정합)

- `POST /api/cards/{id}/feedback`
- `POST /api/briefings/{id}/feedback`
- `POST /api/insights/{id}/feedback`
- `POST /api/mixer/{id}/feedback`
- `POST /api/chat/turns/{turn_id}/feedback`

### Langfuse score push

Langfuse 의 score API (`POST /api/public/scores`) — payload:

```json
{
  "traceId": "lf-trace-...",
  "name": "user_feedback",
  "value": 1.0,
  "comment": "정확한 시사점",
  "dataType": "NUMERIC"
}
```

### Changelog

- **v1 (제안, P9)** — admin_page §4.3 정합 + 5 artifact_type + Langfuse score 이중 적재
