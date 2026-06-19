#!/usr/bin/env bash
# 작성일: 2026-05-04
# 작성자: 최종민
# 변경이력:
#   2026-05-04 최종민 — .env SSoT 기반 K8s Secret YAML 자동 생성 스크립트 신규 작성, 이후 SECRET_KEYS 목록 갱신(WORK24 키 교체 등)
#   2026-05-18 박지원 — NAVER 클라이언트 키 항목 수정
#
# .env (or .env.local) 에서 K8s Secret YAML 을 생성한다.
# stdout 으로 출력 — Makefile 의 secret target 에서 redirect 로 파일 저장.
#
# 사용:
#   ./scripts/env-to-secret.sh .env       > k8s/overlays/local/secret.local.yaml
#   ./scripts/env-to-secret.sh .env.local > k8s/overlays/local/secret.local.yaml
#
# 동작:
#   · .env 의 KEY=VALUE 라인 파싱 (주석/빈 줄 무시)
#   · 미리 정의된 SECRET_KEYS 화이트리스트 만 추출 (ConfigMap 키 제외)
#   · K8s Secret stringData 형식으로 출력
#
# 미정의 키는 빈 문자열로 채움 — Pod 시작 자체는 가능하지만 해당 외부 호출은 fail.
#
# bash 3.x 호환 (macOS default).
set -eu

ENV_FILE="${1:-.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE not found" >&2
    echo "Hint: cp .env.example .env (또는 .env.local.example .env.local)" >&2
    exit 1
fi

# Secret 으로 가야 할 키 목록 (secret.local.yaml.example 과 일치).
# ConfigMap 키 (SPRING_PROFILES_ACTIVE · QDRANT_HOST · SMTP_HOST 등) 는 제외.
SECRET_KEYS="
    SPRING_DATASOURCE_URL
    SPRING_DATASOURCE_USERNAME
    SPRING_DATASOURCE_PASSWORD
    DATABASE_URL
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
    AXIS_AUTH_JWT_SECRET
    CRON_INTERNAL_TOKEN
"

# 한 키 값을 .env 에서 추출. 양 끝 따옴표 제거.
get_env() {
    key="$1"
    # ^KEY= 매칭 라인 마지막 (여러 번 등장 시 마지막 우선) → = 이후 부분
    value=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    # 양 끝 큰따옴표 제거
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
    esac
    # 양 끝 작은따옴표 제거
    case "$value" in
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

# YAML 출력
cat <<HEADER
# Auto-generated from $ENV_FILE by scripts/env-to-secret.sh — DO NOT EDIT manually.
# .env 를 수정한 후 'make secret' 으로 재생성.
apiVersion: v1
kind: Secret
metadata:
  name: axis-secrets
  namespace: axis
type: Opaque
stringData:
HEADER

for key in $SECRET_KEYS; do
    value=$(get_env "$key")
    # YAML double-quoted scalar — backslash + double quote escape
    escaped=$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '  %s: "%s"\n' "$key" "$escaped"
done
