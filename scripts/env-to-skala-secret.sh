#!/usr/bin/env bash
#
# .env → SKALA overlay 의 두 K8s Secret 을 생성한다. stdout 으로 출력.
#
#   1) axis-postgres-bootstrap — postgres pod 의 POSTGRES_DB/USER/PASSWORD 환경변수 주입용
#   2) axis-secrets            — 앱 컨테이너 (frontend·backend·ai) 가 쓰는 DATABASE_URL /
#                                SPRING_DATASOURCE_* / OPENAI_API_KEY / 외부 API 키 등
#
# 사용:
#   ./scripts/env-to-skala-secret.sh .env > k8s/overlays/skala/secret.skala.yaml
#   (Makefile 의 skala-secret target 이 이걸 호출)
#
# 입력 .env 에 필수 키:
#   POSTGRES_DB
#   POSTGRES_USER
#   POSTGRES_PASSWORD
# 그 외 OPENAI_API_KEY / NAVER_* / DART_API_KEY / SMTP_* / JWT_SECRET / CRON_INTERNAL_TOKEN 는
# 있으면 그대로, 없으면 빈값 (Pod 시작은 가능하지만 해당 외부 호출만 fail).
#
# 본 스크립트는 .env 의 DATABASE_URL / SPRING_DATASOURCE_* (Supabase·로컬 등) 는 무시하고,
# POSTGRES_* 에서 in-namespace 'postgres' service 기반 URL 을 자동 derive 한다.
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

# 한 키 값을 .env 에서 추출. 양 끝 따옴표 제거.
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

# YAML double-quoted scalar escape — backslash + double quote
yaml_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Postgres bootstrap (필수)
PG_DB=$(get_env POSTGRES_DB)
PG_USER=$(get_env POSTGRES_USER)
PG_PW=$(get_env POSTGRES_PASSWORD)

if [ -z "$PG_DB" ] || [ -z "$PG_USER" ] || [ -z "$PG_PW" ]; then
    echo "Error: $ENV_FILE 에 POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD 모두 필요" >&2
    echo "Hint: .env.example 의 SKALA EKS 섹션 참조" >&2
    exit 1
fi

# DB URL auto-derive — postgres service 는 같은 namespace 의 'postgres'
DATABASE_URL="postgresql://${PG_USER}:${PG_PW}@postgres:5432/${PG_DB}"
SPRING_URL="jdbc:postgresql://postgres:5432/${PG_DB}"

cat <<HEADER
# Auto-generated from $ENV_FILE by scripts/env-to-skala-secret.sh — DO NOT EDIT manually.
# 재생성: make skala-secret
---
apiVersion: v1
kind: Secret
metadata:
  name: axis-postgres-bootstrap
  namespace: $NS
  labels:
    app: postgres
    app.kubernetes.io/part-of: axis
type: Opaque
stringData:
  POSTGRES_DB: "$(yaml_escape "$PG_DB")"
  POSTGRES_USER: "$(yaml_escape "$PG_USER")"
  POSTGRES_PASSWORD: "$(yaml_escape "$PG_PW")"
---
apiVersion: v1
kind: Secret
metadata:
  name: axis-secrets
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: axis
type: Opaque
stringData:
  DATABASE_URL: "$(yaml_escape "$DATABASE_URL")"
  SPRING_DATASOURCE_URL: "$(yaml_escape "$SPRING_URL")"
  SPRING_DATASOURCE_USERNAME: "$(yaml_escape "$PG_USER")"
  SPRING_DATASOURCE_PASSWORD: "$(yaml_escape "$PG_PW")"
HEADER

# 외부 API / SMTP / 인증 키 (있으면 채움, 없으면 빈값)
OTHER_KEYS="
    QDRANT_API_KEY
    OPENAI_API_KEY
    NAVER_CLIENT_ID
    NAVER_CLIENT_SECRET
    DART_API_KEY
    KIPRIS_API_KEY
    SARAMIN_API_KEY
    SMTP_USER
    SMTP_PASSWORD
    JWT_SECRET
    CRON_INTERNAL_TOKEN
"

for key in $OTHER_KEYS; do
    value=$(get_env "$key")
    escaped=$(yaml_escape "$value")
    printf '  %s: "%s"\n' "$key" "$escaped"
done
