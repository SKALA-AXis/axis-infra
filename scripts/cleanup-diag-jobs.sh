#!/usr/bin/env bash
# 수동 디버그 Job(diag-*) 정리 — suspend 된 CronJob 에서 kubectl create job --from=cronjob 로
# 만든 실패 Job 이 ArgoCD Degraded 를 유발할 때 사용.
#
# Usage:
#   NAMESPACE=skala3-finalproj-class3-team13 ./scripts/cleanup-diag-jobs.sh
#   ./scripts/cleanup-diag-jobs.sh --all-failed   # diag-* 외 Failed Job 도 삭제
set -euo pipefail

NS="${NAMESPACE:-skala3-finalproj-class3-team13}"
ALL_FAILED=false
if [ "${1:-}" = "--all-failed" ]; then
  ALL_FAILED=true
fi

if [ "$ALL_FAILED" = true ]; then
  mapfile -t JOBS < <(kubectl get jobs -n "$NS" -o json \
    | jq -r '.items[] | select((.status.conditions // []) | any(.type=="Failed" and .status=="True")) | .metadata.name')
else
  mapfile -t JOBS < <(kubectl get jobs -n "$NS" -o json \
    | jq -r '.items[] | select(.metadata.name | startswith("diag-")) | .metadata.name')
fi

if [ "${#JOBS[@]}" -eq 0 ]; then
  echo "no jobs to delete (namespace=$NS)"
  exit 0
fi

echo "Deleting ${#JOBS[@]} job(s) in $NS: ${JOBS[*]}"
kubectl delete job -n "$NS" "${JOBS[@]}"
echo "Done."
