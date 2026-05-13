#!/usr/bin/env bash
#
# .env → Langfuse self-host 용 langfuse-secret 생성. stdout 으로 출력.
#
# axis-secrets / axis-postgres-bootstrap 과 별개 (Langfuse pod 의 bootstrap 전용):
#   · POSTGRES_PASSWORD — Langfuse 내장 PG 의 user/admin password (한 값으로 둘 다 사용)
#   · NEXTAUTH_SECRET   — session token 서명 / 암호화 키
#   · SALT              — DB 안의 sensitive value salt
#
# 사용:
#   ./scripts/env-to-langfuse-secret.sh .env > k8s/base/langfuse-secret.yaml
#   kubectl apply -f k8s/base/langfuse-secret.yaml
#
# 입력 .env 에 필수 키 (.env.example 의 "Langfuse self-host" 섹션 참조):
#   LANGFUSE_POSTGRES_PASSWORD
#   LANGFUSE_NEXTAUTH_SECRET
#   LANGFUSE_SALT
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
LF_NEXTAUTH=$(get_env LANGFUSE_NEXTAUTH_SECRET)
LF_SALT=$(get_env LANGFUSE_SALT)

missing=""
[ -z "$LF_PG_PW" ]    && missing="$missing LANGFUSE_POSTGRES_PASSWORD"
[ -z "$LF_NEXTAUTH" ] && missing="$missing LANGFUSE_NEXTAUTH_SECRET"
[ -z "$LF_SALT" ]     && missing="$missing LANGFUSE_SALT"

if [ -n "$missing" ]; then
    echo "Error: $ENV_FILE 에 다음 키 누락:$missing" >&2
    echo "Hint: .env.example 의 'Langfuse self-host' 섹션 참조. 생성 명령:" >&2
    echo "  openssl rand -hex 32                          # NEXTAUTH_SECRET / SALT" >&2
    echo "  openssl rand -base64 24 | tr -d '/+='         # POSTGRES_PASSWORD" >&2
    exit 1
fi

# placeholder 값 검출 (실값 미주입 사고 방지)
case "$LF_PG_PW" in
    change-me-*|REPLACE_*) echo "Error: LANGFUSE_POSTGRES_PASSWORD 가 placeholder 값 ($LF_PG_PW). 실값 채움 후 재실행." >&2; exit 1 ;;
esac
case "$LF_NEXTAUTH" in
    change-me-*|REPLACE_*) echo "Error: LANGFUSE_NEXTAUTH_SECRET 가 placeholder 값. 실값 채움 후 재실행." >&2; exit 1 ;;
esac
case "$LF_SALT" in
    change-me-*|REPLACE_*) echo "Error: LANGFUSE_SALT 가 placeholder 값. 실값 채움 후 재실행." >&2; exit 1 ;;
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
apiVersion: v1
kind: Secret
metadata:
  name: langfuse-secret
  namespace: $NS
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
  labels:
    app.kubernetes.io/part-of: axis
    app.kubernetes.io/component: observability
type: Opaque
stringData:
  POSTGRES_PASSWORD: "$(yaml_escape "$LF_PG_PW")"
  NEXTAUTH_SECRET: "$(yaml_escape "$LF_NEXTAUTH")"
  SALT: "$(yaml_escape "$LF_SALT")"
HEADER
