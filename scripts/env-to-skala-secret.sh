#!/usr/bin/env bash
# 작성일: 2026-05-08
# 작성자: 최종민
# 변경이력:
#   2026-05-08 최종민 — SKALA overlay 용 K8s Secret 생성 스크립트 신규 작성, 이후 키 목록·구성 지속 갱신(JWT 키 교정·PII 분리·Langfuse Cloud 전환 등)
#   2026-05-18 박지원 — NAVER 클라이언트 키 항목 수정
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
# 그 외 OPENAI_API_KEY / NAVER_* / DART_API_KEY / SMTP_* / AXIS_AUTH_JWT_SECRET / CRON_INTERNAL_TOKEN 는
# 있으면 그대로, 없으면 빈값 (Pod 시작은 가능하지만 해당 외부 호출만 fail).
# ⚠ JWT_SECRET 은 legacy — .env 에 있어도 출력하지 않음 (backend 미참조).
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
#
# ArgoCD 주의:
#   · 이 Secret 들은 git 에 커밋되지 않음 (kustomization.yaml resources 에서 제외).
#   · ArgoCD 가 빌드한 manifest 에는 안 보이지만 cluster 에서는 prune 하면 안 됨.
#   · annotation 'argocd.argoproj.io/sync-options: Prune=false' 로 보호.
---
apiVersion: v1
kind: Secret
metadata:
  name: axis-postgres-bootstrap
  namespace: $NS
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
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
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
  labels:
    app.kubernetes.io/part-of: axis
type: Opaque
stringData:
  DATABASE_URL: "$(yaml_escape "$DATABASE_URL")"
  SPRING_DATASOURCE_URL: "$(yaml_escape "$SPRING_URL")"
  SPRING_DATASOURCE_USERNAME: "$(yaml_escape "$PG_USER")"
  SPRING_DATASOURCE_PASSWORD: "$(yaml_escape "$PG_PW")"
HEADER

# 외부 API / SMTP / 인증 키 / 발송 수신자 PII (있으면 채움, 없으면 빈값).
# BRIEFING_RECIPIENTS 는 개인 이메일 (PII) 이므로 ConfigMap 이 아닌 Secret 경로로 주입한다
# (public repo 전환 시 git tracked ConfigMap 노출 방지).
OTHER_KEYS="
    QDRANT_API_KEY
    OPENAI_API_KEY
    NAVER_CLIENT_ID
    NAVER_CLIENT_SECRET
    NAVER_CLIENT_IDS
    NAVER_CLIENT_SECRETS
    DART_API_KEY
    KIPRIS_API_KEY
    WORK24_API_KEY
    WORK24_RETURN_TYPE
    SMTP_USER
    SMTP_PASSWORD
    AXIS_AUTH_JWT_SECRET
    CRON_INTERNAL_TOKEN
    LANGFUSE_PUBLIC_KEY
    LANGFUSE_SECRET_KEY
    BRIEFING_RECIPIENTS
    SLACK_WEBHOOK_URL
"

for key in $OTHER_KEYS; do
    value=$(get_env "$key")
    escaped=$(yaml_escape "$value")
    printf '  %s: "%s"\n' "$key" "$escaped"
done

# Langfuse Cloud host — .env 의 LANGFUSE_BASE_URL (JS SDK 컨벤션) 그대로
# LANGFUSE_HOST 로 박음. Python SDK (v4+) 는 LANGFUSE_BASE_URL / LANGFUSE_HOST
# 둘 다 인식 — 1 키만 박아도 충분. self-host 폐기 (2026-05-14): v2 chart=OTel
# 미지원, v3 chart=PVC quota 초과 → Cloud SaaS 채택.
LF_HOST=$(get_env LANGFUSE_BASE_URL)
if [ -z "$LF_HOST" ]; then
    LF_HOST=$(get_env LANGFUSE_HOST)
fi
LF_HOST_ESC=$(yaml_escape "$LF_HOST")
printf '  LANGFUSE_HOST: "%s"\n' "$LF_HOST_ESC"
