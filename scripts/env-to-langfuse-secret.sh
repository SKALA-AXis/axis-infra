#!/usr/bin/env bash
#
# .env → langfuse-postgresql secret 생성 (stdout YAML).
#
# Chart 0.8.0 (v2) 가 사용하는 Bitnami PostgreSQL subchart 의 password 주입용.
# Bitnami 가 hardcoded 로 'langfuse-postgresql' 이름의 secret 을 찾음
# (release-{subchart} naming convention) + key 이름은 Bitnami default
# (postgres-password / password).
#
# NEXTAUTH_SECRET / SALT 는 chart 가 자체 처리 (random helm + plain "changeme") —
# 본 스크립트는 LANGFUSE_POSTGRES_PASSWORD 만 사용. .env 의 LANGFUSE_NEXTAUTH_SECRET
# / LANGFUSE_SALT 는 v1 미사용 (P10+ ExternalSecrets 도입 시 활성).
#
# 사용:
#   ./scripts/env-to-langfuse-secret.sh .env > k8s/base/langfuse-secret.yaml
#   kubectl apply -f k8s/base/langfuse-secret.yaml
#
# 입력 .env 에 필수 키:
#   LANGFUSE_POSTGRES_PASSWORD
#
# bash 3.x 호환 (macOS default).
set -eu

ENV_FILE="${1:-.env}"
NS="skala3-finalproj-class3-team13"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE not found" >&2
    echo "Hint: cp .env.example .env (실값 채움)" >&2
    exit 1
fi

# .env 에서 키 추출. 양 끝 따옴표 제거. (env-to-skala-secret.sh 와 동일 helper)
get_env() {
    key="$1"
    value=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
    esac
    case "$value" in
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

yaml_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

LF_PG_PW=$(get_env LANGFUSE_POSTGRES_PASSWORD)

if [ -z "$LF_PG_PW" ]; then
    echo "Error: $ENV_FILE 에 LANGFUSE_POSTGRES_PASSWORD 누락" >&2
    echo "Hint: .env.example 의 'Langfuse self-host' 섹션 참조. 생성 명령:" >&2
    echo "  openssl rand -base64 24 | tr -d '/+='" >&2
    exit 1
fi

# placeholder / 명령어 literal 값 감지 (실값 미주입 사고 방지)
case "$LF_PG_PW" in
    change-me-*|REPLACE_*|*"openssl"*)
        echo "Error: LANGFUSE_POSTGRES_PASSWORD 가 placeholder 또는 명령어 literal ($LF_PG_PW)" >&2
        echo "Hint: 명령어를 실행한 *출력값* 을 박아야 함:" >&2
        echo "  openssl rand -base64 24 | tr -d '/+='     # 이 출력을 복사해서 .env 의 값으로" >&2
        exit 1
        ;;
esac

cat <<HEADER
# Auto-generated from $ENV_FILE by scripts/env-to-langfuse-secret.sh — DO NOT EDIT manually.
# 재생성: ./scripts/env-to-langfuse-secret.sh .env > k8s/base/langfuse-secret.yaml
#
# ArgoCD 주의:
#   · 본 Secret 은 git 미커밋 (.gitignore 에 k8s/base/langfuse-secret.yaml 등록).
#   · k8s/argocd/langfuse-application.yaml 의 ignoreDifferences 가 stringData drift 무시.
#   · Prune=false annotation 으로 ArgoCD 가 실수로 삭제 못 하게 보호.
---
# Bitnami PostgreSQL subchart 가 'langfuse-postgresql' 이름을 hardcoded 로 찾음
# (release-{subchart} naming). key 이름은 Bitnami convention.
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-postgresql
  namespace: $NS
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
  labels:
    app.kubernetes.io/part-of: axis
    app.kubernetes.io/component: observability
type: Opaque
stringData:
  postgres-password: "$(yaml_escape "$LF_PG_PW")"
  password:          "$(yaml_escape "$LF_PG_PW")"
HEADER
