# 0007. 노드 야간 셧다운 창(23:00–07:00 KST)과 CronJob 스케줄 정책

- **날짜**: 2026-06-10
- **상태**: Accepted

## 배경

"매일 아침 7시쯤 포드와 CronJob이 한꺼번에 터진다"는 현상이 수 주간 반복됐고,
그동안의 대응(#49 card-evaluator activeDeadlineSeconds, #53 pg-dump 3-phase + 스케줄 분산,
#56 cron hygiene, failure-notifier 신설, harbor pre-pull secret)은 모두 증상 완화였을 뿐
재발을 막지 못했다.

2026-06-10 조사에서 확인한 사실 (모두 클러스터 API 타임스탬프 기준):

```
워커 노드 6대 생성 시각:   2026-06-09T22:00:43~54Z  = 06-10 07:00:43~54 KST (11초 안에 6대)
메인 포드 생성 시각:       2026-06-09T14:00:20~33Z  = 06-09 23:00:20~33 KST
메인 포드 실제 시작 시각:  2026-06-09T22:01:02~13Z  = 06-10 07:01 KST
→ postgres/qdrant/backend/ai/frontend 전부 23:00에 재생성된 뒤 8시간 동안 Pending,
  07:00 노드 복귀와 동시에 일제히 스케줄됨.
axis-pg-dump (02:10 KST):  Failed — 밤사이 스케줄할 노드가 없어 매일 실패
```

즉 **skala-2025 공용 클러스터의 워커 노드는 매일 23:00 KST에 내려가고 07:00 KST에
올라온다** (플랫폼 차원의 야간 절감 정책으로 추정, 팀이 제어 불가). "아침 7시의 폭발"은
장애의 원인이 아니라 **밤새 쌓인 실패(야간 cron 전부 실패 + 8시간 Pending)가 노드 복귀와
함께 한꺼번에 드러나는 복구 시점**이었다.

## 결정

1. **CronJob은 07:00–22:59 KST 안에만 스케줄한다.** 야간 배치 의도였던 작업은 저녁
   (셧다운 전) 또는 아침(노드 복귀 직후)으로 옮긴다.
2. 매시/매분류 반복 cron은 hour 필드를 `7-22` 로 제한한다 — 밤에는 서비스 포드 자체가
   없으므로 야간 실행은 어차피 무의미하며, 실패 잡 8시간치가 쌓이는 것만 막으면 된다.
3. 07:00 정각은 노드 기동 경합 구간이므로 일 배치의 첫 실행은 07:10 이후로 둔다.
4. 모든 CronJob 은 `timeZone: Asia/Seoul` 을 명시한다.
5. CI(`validate.yml`)의 `scripts/validate-cron-window.py` 가 이 규칙을 강제한다.
   suspend 된 cron 도 검사한다 (해제 시점에 터지는 것 방지).

### 이번에 옮긴 스케줄

| CronJob | 변경 전 | 변경 후 |
|---|---|---|
| axis-pg-dump | 02:10 매일 | **21:30 매일** (셧다운 전 당일 데이터 백업) |
| axis-cron-global-trend | 02:30 매일 | 07:40 매일 |
| axis-cron-ingestion-d | 04:25 매일 | 07:15 매일 |
| axis-cron-sector-pulse | 월 02:00 | 월 07:50 |
| axis-cron-capability-evolution | 매월 1일 03:00 | 매월 1일 10:00 |
| axis-cron-profile-refresh | 분기 1일 03:00 | 분기 1일 10:30 |
| axis-cron-weekly-digest | 일 23:55 | **일 21:55** (셧다운 직전이 아닌 안전 구간) |
| axis-cron-ingestion-a | 매시 :00 | 07–22시 :10 |
| axis-cron-card-evaluator | 매 5분 | 07–22시 매 5분 |
| axis-cron-failure-notifier | 매 10분 | 07–22시 매 10분 |
| axis-cron-news-cluster-postprocess | 매시 :25 | 07–22시 :25 |

## 결과

- 야간 cron 실패가 사라져 아침 7시의 실패 잡 폭발·notifier 스팸이 없어진다.
- 23:00 직전(weekly-digest 21:55, pg-dump 21:30)과 07:00 직후(07:10+)에 버퍼를 둬
  드레인/기동 경합을 피한다.
- 한계: 23:00–07:00 사이 서비스 다운 자체는 플랫폼 정책이라 이 레포에서 해결 불가.
  운영 전환 시(실 고객 트래픽 발생 시) 매니저에게 노드 상시 운영 또는 전용 노드그룹을
  요청해야 한다. 아침 8:10/8:30 브리핑 체인(today-insight → delivery)은 07:00 복귀
  후 충분한 여유가 있어 영향 없음 (오늘 기준 전 서비스 Ready 07:11).

## 같이 보기

- [0004. 수집/전달 파이프라인 분리](0004-pipeline-separation.md)
- `scripts/validate-cron-window.py` — CI 강제 가드
