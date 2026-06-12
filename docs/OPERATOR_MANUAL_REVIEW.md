# 운영자 매뉴얼 v0.2 — 인프라 관점 검토 (2026-06-12)

> 대상: `13조_[AXIS]_700. 운영자매뉴얼_초안_v0.2.docx` (6/8 작성) · 검토: 인프라
> 골격(8장 구성)은 좋음. 아래는 ①사실 정정 ②6/9~12 변경 미반영분 ③인프라 관점 누락 절 ④복붙 템플릿 실질화 — 반영용 문안 포함.

## ① 사실 정정 (필수)

| 위치 | 현재 | 정정 |
|---|---|---|
| 2장 서버 목록 | postgres **StatefulSet** | **Deployment** (postgres-{hash} 패턴, 34d) |
| 2장 구성요소 | Slack Webhook = "Job/Pod 장애 알림" | 절반만 맞음 — failure-notifier 가 사용하나 **SLACK_WEBHOOK_URL 미설정 시 조용히 skip(정상 종료)**. 운영 인수 시 "알림이 실제로 어디로 가는지" 확인 절차 필수. 서비스 알림(브리핑/인증 메일)은 SES 단일 |
| 2장 ai 확인 포인트 | "/health, model-cache cold start" | probe 기준은 **/healthz**(경량). cold start 는 6/11부로 **PVC 캐시+initContainer 워밍업**으로 해소 — "model-warmup init 통과(캐시 적중 시 수 초)" 로 교체 |
| 5장 배치 시간표 | ingestion-d 03:30, ingestion-a 매시 00분 등 | **6/10 PR #59 로 전면 이동** — 노드 야간 셧다운(23–07 KST) 회피. 최신: a=07–22시 매시 :10 / d=07:15 / global-trend=07:40 / sector-pulse=월 07:50 / weekly-digest=일 21:55 / **pg-dump=21:30 (배치표에 누락됨 — 추가)** / evaluator·notifier·postprocess=07–22시 한정. 정본: `k8s/base/cronjob-*.yaml` |

## ② 인프라 관점 누락 절 — 신설 권고 (반영용 문안)

### (3장에 추가) 클러스터 운영 제약 — 가장 중요

> **노드 야간 셧다운**: skala-2025 워커 노드는 매일 23:00 KST 다운, 07:00 KST 복귀(플랫폼 정책).
> ① 야간에는 전 서비스 다운이 **정상**이다 ② CronJob 은 07:00–22:59 만 허용(CI 가드 `scripts/validate-cron-window.py`)
> ③ 매일 07:00–07:12 기동 출렁임(Pending→Running→Ready)은 자가 치유되므로 그 시간대 빨간 표시에 조치 금지.
> **request 포화**: 공용 클러스터의 타 팀 과예약으로 노드별 CPU 여유 ~300–500m. 새 워크로드 request 는 보수적으로(axis-ai 는 400m/limit 2000m). 스케줄 불가 시 노드 증설은 매니저 요청.

### (신설) 배포·롤백 운영 (GitOps)

> 모든 변경은 git 경유: 서비스 레포 develop 머지 → CI → Harbor → axis-infra deploy 커밋 → ArgoCD sync(≤3분 폴링).
> **수동 kubectl 변경은 다음 sync 때 증발**한다(6/11 실증) — 긴급 패치도 반드시 git 에 박을 것.
> 문서만 바뀐 push 는 CI/배포가 자동 skip 된다(paths-ignore).
> **axis-ai 무중단 롤링**: maxSurge=1/maxUnavailable=0 + minReadySeconds=180 — 새 포드가 Ready 를 180초 유지해야 구포드 종료. 클러스터 포화로 새 포드가 Pending 이어도 구포드가 계속 서빙(정상 동작이니 기다릴 것).
> **롤백**: `git revert <deploy commit>` → ArgoCD 자동 복원(P6 drill 23초 검증). 단 **Harbor retention(아래) 때문에 롤백 가능 창 = 최근 ~10회 배포분** — 그보다 오래된 커밋으로 롤백 시 `gh workflow run build-and-push.yml --ref <sha>` 재빌드 선행.

### (신설) 이미지 레지스트리 운영

> Harbor(amdp-registry, project skala26a-ai3, 타 팀 공유) retention: **artifact 최근 10개 + develop/buildcache 각 3개, 매일 정리**.
> → 옛 태그 404 는 **정상**. 점검은 "현재 배포 핀 4태그 존재"만: `docker manifest inspect ...axis-{ai,ai-cron,backend,frontend}:<kustomization 핀>`
> 이미지 실측(6/11): axis-ai 0.84GB / axis-ai-cron 0.08GB / 아침 노드 재생성 후 풀 수 분 내.

### (신설) 백업·복원

> `axis-pg-dump` CronJob 이 **매일 21:30**(셧다운 전) S3(axis-team13-backups/pg) 업로드, IRSA(axis-backup-sa).
> 복원: `make skala-restore` (scale-down → restore Job → scale-up 자동). 상세: `k8s/overlays/skala/README.md`.

### (6장에 추가) 실전 장애 케이스북 — 6월 실사례 기반

| 증상 | 원인 | 조치 |
|---|---|---|
| 아침 7시 전후 포드/잡 대량 실패 표시 | 야간 셧다운 후 일제 기동 | **조치 불요** — 07:12 까지 대기. cron 이 야간 창에 스케줄됐는지만 확인 |
| 배포 핀 태그 ImagePullBackOff | Harbor retention 으로 purge (롤백 창 밖) | 해당 SHA 재빌드 후 재시도 |
| ArgoCD SyncError "more than 1 volume type" 류 | 과거 수동 kubectl 적용이 남긴 SSA fieldManager 충돌 | 충돌 필드 1회 json patch 로 정리 후 재sync (6/11 사례: model-cache) |
| 새 포드 장기 Pending + 구포드 정상 | 클러스터 request 포화 | 정상 대기 동작. 장기화 시 request 인하 PR 또는 매니저 노드 증설 |
| 배포 직후 AI 일시 무응답 | (6/12 이전 빌드) readiness 플랩 | minReadySeconds=180 + to_thread 격리(#147)로 해소 — 재발 시 probe Unhealthy 이벤트와 처리 중 요청 로그 대조 |
| 장애 알림이 안 옴 | SLACK_WEBHOOK_URL 미설정 시 notifier 가 조용히 skip | 인수 시 webhook 실효성 확인, 비울 거면 "알림 무음" 임을 명시 |

## ③ 복붙 템플릿 실질화 (4장)

컴포넌트별 표가 동일 문안 반복 + 일부는 무의미(`get pod | grep secret`, ingress 는 pod 없음). 컴포넌트별 실제 명령으로 교체 권고:

- **secret/config**: `kubectl get secret axis-secrets -o jsonpath='{.data}' | jq 'keys'` (키 목록만 — 값 출력 금지), `kubectl get cm axis-config -o yaml | head`
- **ingress/cert**: `kubectl get ingress axis -o wide` + ALB DNS 200 확인 `curl -sI http://<ALB>/` (pod 아님)
- **pvc/storage**: `kubectl get pvc` (5/5 quota 주의 — 6번째 PVC 는 quota 증설 선행), EFS 류는 용량 무제한이라 사용률 점검 불요
- **ai**: `/healthz` 200 + `kubectl get pod -l app=axis-ai` (init: model-warmup 통과 여부) + 단일 replica 이므로 NotReady = 전면 영향
- **qdrant**: `curl -s qdrant:6333/collections` 로 axis_main/axis_documents point 수
- **장애 처리(6장)**: 유형별 6단계가 전부 동일 — 유형별 "가장 흔한 원인 1줄 + 전용 확인 명령 1개"라도 차별화 (위 케이스북 활용)

## ④ 기타

- 부록에 **정본 링크 절** 추가 권고: CLAUDE.md(마스터), HANDOVER.md(PAT 등), ADR 0007(야간 셧다운), ci-cd-plan.md, 본 검토서
- "이미지 필요" 플레이스홀더 중 인프라 몫: ArgoCD UI 트리 캡처, kubectl get pods 정상 상태 캡처, Harbor retention 설정 화면 — 요청 주시면 캡처용 명령/화면 안내 제공
