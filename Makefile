# AXIS — 로컬 K8s 운영 / 매니페스트 검증 Makefile
#
# 핵심 흐름:
#   make local-up        # 클러스터 + 이미지 + apply 한 번에
#   make local-down      # 클러스터 자체 삭제
#   make validate        # 매니페스트 schema 검증 (kubeconform)
#
# 자세한 가이드: k8s/overlays/local/README.md

CLUSTER_NAME ?= axis-local
KIND_CONFIG  := k8s/overlays/local/kind-config.yaml
NS           := axis

# 빌드 컨텍스트 (axis-infra 의 sibling 디렉토리)
FRONTEND_DIR := ../axis-frontend
BACKEND_DIR  := ../axis-backend
AI_DIR       := ../axis-ai

IMAGE_TAG    ?= dev

# 이미지 이름 (overlays/local 의 patch 와 일치 — pullPolicy: Never)
FRONTEND_IMG := axis-frontend:$(IMAGE_TAG)
BACKEND_IMG  := axis-backend:$(IMAGE_TAG)
AI_IMG       := axis-ai:$(IMAGE_TAG)

.PHONY: help cluster-up cluster-down build build-frontend build-backend build-ai \
        load load-frontend load-backend load-ai apply delete logs status \
        local-up local-down secret validate validate-base validate-local \
        clean

help:  ## 명령 목록
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── 단계별 명령 ─────────────────────────────────────────────

cluster-up:  ## kind 클러스터 생성 (NodePort 30300/30880 매핑)
	kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG)

cluster-down:  ## kind 클러스터 삭제 (모든 PVC 데이터 삭제)
	kind delete cluster --name $(CLUSTER_NAME)

build-frontend:  ## frontend 이미지 빌드
	docker build -t $(FRONTEND_IMG) $(FRONTEND_DIR)

build-backend:  ## backend 이미지 빌드
	docker build -t $(BACKEND_IMG) $(BACKEND_DIR)

build-ai:  ## ai 이미지 빌드 (~5분, FlagEmbedding+torch)
	docker build -t $(AI_IMG) $(AI_DIR)

build: build-frontend build-backend build-ai  ## 3 이미지 모두 빌드

load-frontend:  ## frontend 이미지를 kind 에 로드
	kind load docker-image $(FRONTEND_IMG) --name $(CLUSTER_NAME)

load-backend:
	kind load docker-image $(BACKEND_IMG) --name $(CLUSTER_NAME)

load-ai:
	kind load docker-image $(AI_IMG) --name $(CLUSTER_NAME)

load: load-frontend load-backend load-ai  ## 3 이미지 kind 로드

secret:  ## .env (또는 .env.local) 에서 secret.local.yaml 자동 생성
	@if [ -f .env ]; then \
		./scripts/env-to-secret.sh .env > k8s/overlays/local/secret.local.yaml; \
		echo "✓ secret.local.yaml 생성 — source: .env"; \
	elif [ -f .env.local ]; then \
		./scripts/env-to-secret.sh .env.local > k8s/overlays/local/secret.local.yaml; \
		echo "✓ secret.local.yaml 생성 — source: .env.local (in-cluster DB 모드)"; \
	else \
		cp k8s/overlays/local/secret.local.yaml.example k8s/overlays/local/secret.local.yaml; \
		echo "⚠ .env 없음 — secret.local.yaml.example 복사 (placeholder 값)"; \
		echo "  실 동작 위해: cp .env.example .env → 실값 편집 → make secret"; \
	fi

apply:  ## kustomize overlays/local 적용
	kubectl apply -k k8s/overlays/local

delete:  ## kustomize overlays/local 제거 (PVC 보존)
	kubectl delete -k k8s/overlays/local --ignore-not-found

# ── 통합 명령 (자주 쓰는 시나리오) ──────────────────────────

local-up: cluster-up build load secret apply  ## 클러스터 + 빌드 + 로드 + apply 한 번에 (~5~10분)
	@echo ""
	@echo "✅ 적용 완료. Pod 가 ready 될 때까지 watch:"
	@echo "   kubectl -n $(NS) get pods -w"
	@echo ""
	@echo "🌐 접근:"
	@echo "   http://localhost:30300  (frontend SPA)"
	@echo "   http://localhost:30880/health  (backend)"

local-down: delete cluster-down  ## kustomize 제거 + 클러스터 삭제

# ── 운영 보조 명령 ─────────────────────────────────────────

logs:  ## 모든 axis Pod 로그 추적 (label app.kubernetes.io/part-of=axis)
	kubectl -n $(NS) logs -l app.kubernetes.io/part-of=axis --all-containers --max-log-requests 10 -f --tail=100

logs-ai:  ## ai Pod 만 (BGE-M3 다운로드 진행 등)
	kubectl -n $(NS) logs -l app=axis-ai -f --tail=200

logs-backend:
	kubectl -n $(NS) logs -l app=axis-backend -f --tail=200

status:  ## 전체 리소스 상태
	@echo "▸ Pods"
	@kubectl -n $(NS) get pods -o wide
	@echo ""
	@echo "▸ Services"
	@kubectl -n $(NS) get svc
	@echo ""
	@echo "▸ PVC"
	@kubectl -n $(NS) get pvc
	@echo ""
	@echo "▸ CronJob"
	@kubectl -n $(NS) get cronjob

# ── 매니페스트 검증 (CI 와 같은 방식) ───────────────────────

validate-base:  ## kustomize build base + kubeconform schema 검증
	kubectl kustomize k8s/base > /tmp/axis-base.yaml
	docker run --rm -v /tmp/axis-base.yaml:/tmp/all.yaml \
		ghcr.io/yannh/kubeconform:latest -strict -summary /tmp/all.yaml

validate-local: secret  ## kustomize build overlays/local + kubeconform (secret 자동 생성)
	kubectl kustomize k8s/overlays/local > /tmp/axis-local.yaml
	docker run --rm -v /tmp/axis-local.yaml:/tmp/all.yaml \
		ghcr.io/yannh/kubeconform:latest -strict -summary /tmp/all.yaml

validate: validate-base validate-local  ## base + overlays/local schema 검증

clean:  ## 임시 파일 정리
	rm -f /tmp/axis-base.yaml /tmp/axis-local.yaml /tmp/axis-skala.yaml

# ── SKALA EKS 클러스터 운영 ────────────────────────────────
#
# Pre-flight (1회):
#   1) docker login amdp-registry.skala-ai.com   (Harbor 자격증명 — 매니저 발급)
#   2) cp k8s/overlays/skala/secret.skala.yaml.example  k8s/overlays/skala/secret.skala.yaml
#      → 매니저 받은 실값 채움 (DATABASE_URL / OPENAI_API_KEY 등)
#   3) make skala-pull-secret   (Harbor pull secret 생성, 1회)
#   4) Postgres / Qdrant 격리 셋업 (매니저 정책에 따라 외부 명령)
#   5) Flyway migrate (별도 — db/schema.sql 또는 V1~V6 마이그레이션 적용)
#
# 일반 배포 흐름:
#   make skala-build         # 3 이미지 빌드 (~10분)
#   make skala-push          # Harbor push (~5분)
#   make skala-apply         # kubectl apply -k overlays/skala
#   make skala-status        # Pod / Service / PVC / CronJob 확인

SKALA_NS         := skala3-finalproj-class3-team13
HARBOR_HOST      := amdp-registry.skala-ai.com
HARBOR_PROJECT   := skala26a-ai3
SKALA_TAG        ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "dev")
SKALA_FRONTEND   := $(HARBOR_HOST)/$(HARBOR_PROJECT)/axis-frontend:$(SKALA_TAG)
SKALA_BACKEND    := $(HARBOR_HOST)/$(HARBOR_PROJECT)/axis-backend:$(SKALA_TAG)
SKALA_AI         := $(HARBOR_HOST)/$(HARBOR_PROJECT)/axis-ai:$(SKALA_TAG)

.PHONY: skala-build skala-push skala-apply skala-delete skala-status skala-logs \
        skala-pull-secret skala-validate skala-tag skala-secret langfuse-secret

skala-secret:  ## .env 에서 secret.skala.yaml 생성 (axis-postgres-bootstrap + axis-secrets 두 Secret)
	@if [ ! -f .env ]; then \
		echo "❌ .env 없음 — cp .env.example .env 후 실값 채우세요"; exit 1; \
	fi
	@./scripts/env-to-skala-secret.sh .env > k8s/overlays/skala/secret.skala.yaml
	@echo "✓ secret.skala.yaml 생성 (axis-postgres-bootstrap + axis-secrets) — source: .env"

langfuse-secret:  ## .env 에서 langfuse-secret.yaml 생성 (Langfuse pod bootstrap 전용)
	@if [ ! -f .env ]; then \
		echo "❌ .env 없음 — cp .env.example .env 후 실값 채우세요"; exit 1; \
	fi
	@./scripts/env-to-langfuse-secret.sh .env > k8s/base/langfuse-secret.yaml
	@echo "✓ langfuse-secret.yaml 생성 — source: .env"
	@echo "  적용: kubectl apply -f k8s/base/langfuse-secret.yaml"

skala-validate:  ## SKALA overlay schema 검증
	@if [ ! -f k8s/overlays/skala/secret.skala.yaml ]; then \
		echo "❌ secret.skala.yaml 없음 — secret.skala.yaml.example 복사 후 실값 채우세요"; exit 1; \
	fi
	kubectl kustomize k8s/overlays/skala > /tmp/axis-skala.yaml
	docker run --rm -v /tmp/axis-skala.yaml:/tmp/all.yaml \
		ghcr.io/yannh/kubeconform:latest -strict -summary /tmp/all.yaml

skala-build:  ## 3 이미지 SKALA 태그로 빌드 (Harbor 경로 + linux/amd64 강제)
	docker build --platform=linux/amd64 -t $(SKALA_FRONTEND) $(FRONTEND_DIR)
	docker build --platform=linux/amd64 -t $(SKALA_BACKEND)  $(BACKEND_DIR)
	docker build --platform=linux/amd64 -t $(SKALA_AI)       $(AI_DIR)
	@echo "✓ build done — tag=$(SKALA_TAG) (linux/amd64)"

skala-push:  ## 3 이미지 Harbor push (사전 docker login 필요)
	docker push $(SKALA_FRONTEND)
	docker push $(SKALA_BACKEND)
	docker push $(SKALA_AI)
	@echo "✓ push done — tag=$(SKALA_TAG)"

skala-tag:  ## kustomization.yaml 의 newTag 를 현재 git SHA 로 치환
	@if ! grep -q 'newTag: REPLACE_TAG' k8s/overlays/skala/kustomization.yaml; then \
		echo "⚠ kustomization.yaml 에 'newTag: REPLACE_TAG' 가 없음 — 이미 다른 태그로 치환됐거나 형식 변경"; \
	fi
	sed -i.bak 's|newTag: REPLACE_TAG|newTag: $(SKALA_TAG)|g' k8s/overlays/skala/kustomization.yaml
	rm -f k8s/overlays/skala/kustomization.yaml.bak
	@echo "✓ kustomization.yaml newTag → $(SKALA_TAG)  (git checkout 으로 되돌릴 수 있음)"

skala-pull-secret:  ## Harbor imagePullSecret 생성 (1회) — HARBOR_USER / HARBOR_PASS 환경변수 필요
	@if [ -z "$$HARBOR_USER" ] || [ -z "$$HARBOR_PASS" ]; then \
		echo "❌ HARBOR_USER / HARBOR_PASS 환경변수 필요"; \
		echo "   사용 예: HARBOR_USER=team13 HARBOR_PASS=... make skala-pull-secret"; \
		exit 1; \
	fi
	kubectl create secret docker-registry harbor-creds \
		--docker-server=$(HARBOR_HOST) \
		--docker-username=$$HARBOR_USER \
		--docker-password=$$HARBOR_PASS \
		-n $(SKALA_NS) \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✓ harbor-creds secret 적용 (idempotent)"

skala-apply:  ## kustomize overlays/skala 적용
	kubectl apply -k k8s/overlays/skala

skala-delete:  ## overlays/skala 제거 (PVC / Secret 은 별도 정리 필요)
	kubectl delete -k k8s/overlays/skala --ignore-not-found

skala-status:  ## SKALA namespace 의 모든 axis 리소스 상태
	@echo "▸ Pods"
	@kubectl -n $(SKALA_NS) get pods -o wide
	@echo ""
	@echo "▸ Services"
	@kubectl -n $(SKALA_NS) get svc
	@echo ""
	@echo "▸ PVC"
	@kubectl -n $(SKALA_NS) get pvc
	@echo ""
	@echo "▸ CronJob"
	@kubectl -n $(SKALA_NS) get cronjob
	@echo ""
	@echo "▸ Ingress"
	@kubectl -n $(SKALA_NS) get ingress

skala-logs:  ## 모든 axis Pod 로그 (skala namespace)
	kubectl -n $(SKALA_NS) logs -l app.kubernetes.io/part-of=axis --all-containers --max-log-requests 10 -f --tail=100
