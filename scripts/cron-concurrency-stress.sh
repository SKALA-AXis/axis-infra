#!/usr/bin/env bash
# 작성일: 2026-06-09
# 작성자: 최종민
# 변경이력:
#   2026-06-09 최종민 — Cron 동시 실행 겹침/병목 스트레스 테스트 스크립트 추가
# pg-dump + ingestion-a + ingestion-d 동시 트리거 — Cron 겹침/병목 스트레스 테스트.
# Usage: ./scripts/cron-concurrency-stress.sh
set -euo pipefail
NS="${NAMESPACE:-skala3-finalproj-class3-team13}"
STAMP=$(date +%s)
JOBS=(
  "axis-pg-dump:pg-dump-stress-${STAMP}"
  "axis-cron-ingestion-a:ing-a-stress-${STAMP}"
  "axis-cron-ingestion-d:ing-d-stress-${STAMP}"
)

echo "==> Creating ${#JOBS[@]} jobs concurrently in ${NS}"
for spec in "${JOBS[@]}"; do
  cj=${spec%%:*}
  job=${spec#*:}
  kubectl create job "$job" --from="cronjob/${cj}" -n "$NS" &
done
wait
echo "==> Jobs created. Watching up to 15m..."
for spec in "${JOBS[@]}"; do
  job=${spec#*:}
  kubectl wait --for=condition=complete "job/${job}" -n "$NS" --timeout=900s &
done
wait || true

echo ""
echo "==> Results"
for spec in "${JOBS[@]}"; do
  job=${spec#*:}
  kubectl get job "$job" -n "$NS" -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason,DURATION:.status.completionTime
  echo "--- logs (${job}) ---"
  kubectl logs "job/${job}" -n "$NS" --all-containers --tail=8 2>&1 || true
  echo ""
done
