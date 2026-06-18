#!/usr/bin/env bash
# 작성일: 2026-06-08
# 작성자: 최종민
# 변경이력:
#   2026-06-08 최종민 — 클러스터 axis-secrets 의 legacy JWT_SECRET 키 제거 스크립트 추가
# 클러스터 axis-secrets 에서 legacy JWT_SECRET 키 제거.
# backend 는 AXIS_AUTH_JWT_SECRET 만 읽음 — JWT_SECRET 은 0-byte legacy drift.
#
# Usage:
#   NAMESPACE=skala3-finalproj-class3-team13 ./scripts/remove-legacy-jwt-secret-key.sh
set -euo pipefail

NS="${NAMESPACE:-skala3-finalproj-class3-team13}"
SECRET="${SECRET_NAME:-axis-secrets}"

if ! kubectl get secret "$SECRET" -n "$NS" >/dev/null 2>&1; then
  echo "secret $SECRET not found in namespace $NS"
  exit 1
fi

HAS_JWT=$(kubectl get secret "$SECRET" -n "$NS" -o json \
  | python3 -c "import json,sys; print('JWT_SECRET' in json.load(sys.stdin).get('data',{}))")

if [ "$HAS_JWT" != "True" ]; then
  echo "JWT_SECRET key absent — nothing to do"
  exit 0
fi

echo "Removing legacy JWT_SECRET from $SECRET (namespace=$NS)..."
kubectl patch secret "$SECRET" -n "$NS" --type=json \
  -p='[{"op":"remove","path":"/data/JWT_SECRET"}]'
echo "Done. Verify: kubectl get secret $SECRET -n $NS -o json | jq '.data | keys'"
