# 로컬 K8s overlay

> base (EKS 가정) 의 매니페스트를 로컬 클러스터 (kind / minikube / docker-desktop / k3d) 에서 돌릴 수 있게 patch.
> 이미지는 로컬 빌드, Ingress 대신 NodePort, RWX 대신 RWO + local-path SC.

---

## base 와의 차이 한눈에

| 항목 | base (EKS) | overlays/local |
|---|---|---|
| 이미지 | ECR `<acct>.dkr.ecr.../axis-{svc}:tag` · `pullPolicy: IfNotPresent` | `axis-{svc}:dev` · `pullPolicy: Never` (로컬 빌드 강제) |
| Replicas | frontend 2 · backend 2 · ai 1 | 모두 1 |
| 리소스 | frontend 50m/128Mi · backend 500m/1Gi · ai 1500m/4Gi | 절반으로 축소 (노트북 부담) |
| 외부 진입 | ALB Ingress (TLS) | Service NodePort — frontend 30300 · backend 30880 |
| 이미지 공유 PVC | RWX (EFS) | RWO + `standard` SC (kind/minikube 기본) |
| HPA | 2~4 replica auto | 삭제 (metrics-server 없을 가능성) |
| NetworkPolicy | default-deny + allow × 3 | 삭제 (kindnet/minikube 기본 CNI 미지원) |
| CronJob | 활성 (suspend X 단 weak-signal 만 W7+ 까지 suspend) | 모두 `suspend: true` (수동 trigger 권장) |
| Strategy | RollingUpdate | Recreate (RWO PVC 라 동시 mount 불가) |

---

## 사전 준비

### A. 도구 설치 (택 1)

| 도구 | 설치 |
|---|---|
| **kind** | `brew install kind` (가장 가벼움 · 권장) |
| **minikube** | `brew install minikube` |
| **docker-desktop k8s** | Docker Desktop 설정에서 Kubernetes enable |
| **k3d** | `brew install k3d` |

### B. 클러스터 생성

#### kind (권장)

```bash
# kind-config.yaml — NodePort 매핑 (호스트 ↔ 컨테이너)
cat > /tmp/kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30300
        hostPort: 30300
        protocol: TCP
      - containerPort: 30880
        hostPort: 30880
        protocol: TCP
EOF
kind create cluster --name axis-local --config /tmp/kind-config.yaml
```

#### minikube

```bash
minikube start --cpus=4 --memory=8192 --driver=docker
# NodePort 접근:  minikube ip 로 확인 후 http://<ip>:30300
```

#### docker-desktop

```bash
# Docker Desktop > Settings > Kubernetes > Enable Kubernetes
kubectl config use-context docker-desktop
# NodePort 접근: http://localhost:30300 (자동 매핑)
```

---

## 적용 절차

### 1) 자격증명 채우기

```bash
cd axis-infra/k8s/overlays/local
$EDITOR secret.local.yaml          # OPENAI_API_KEY 등 실값
# (in-cluster postgres 모드면 DB 비밀번호는 그대로 유지 — postgres.yaml 과 동기)
```

### 2) 컨테이너 이미지 빌드

```bash
# 각 레포에서 빌드
cd ../../../axis-frontend && docker build -t axis-frontend:dev .
cd ../axis-backend && docker build -t axis-backend:dev .
cd ../axis-ai && docker build -t axis-ai:dev .
```

### 3) 클러스터에 이미지 로드 (kind/minikube 만 필요)

| 도구 | 명령 |
|---|---|
| kind | `kind load docker-image axis-frontend:dev axis-backend:dev axis-ai:dev --name axis-local` |
| minikube | `minikube image load axis-frontend:dev axis-backend:dev axis-ai:dev` |
| docker-desktop | (불필요 — host docker = k8s docker) |
| k3d | `k3d image import axis-frontend:dev axis-backend:dev axis-ai:dev -c <cluster>` |

### 4) DB 모드 결정

#### 모드 A — Cloud DB (default)

`secret.local.yaml` 에 Supabase + Qdrant Cloud 자격증명 입력. 그대로 apply.

#### 모드 B — In-cluster DB

```bash
# kustomization.yaml 의 resources 주석 해제
sed -i.bak 's|# - postgres.yaml|- postgres.yaml|; s|# - qdrant.yaml|- qdrant.yaml|' kustomization.yaml
# secret.local.yaml 의 DB URL 은 default 값 (jdbc:postgresql://postgres:5432/axis) 그대로 사용
# QDRANT_HOST 도 ConfigMap 에서 patch 또는 그대로 — 아래 §troubleshooting 참조
```

### 5) Apply

```bash
cd /Users/toucan/Documents/workspace/axis/axis-infra
# dry-run 먼저
kubectl kustomize k8s/overlays/local | head -20
# 실제 적용
kubectl apply -k k8s/overlays/local
# 상태 확인
kubectl -n axis get all
kubectl -n axis get pvc
```

### 6) 접근

```bash
# kind / docker-desktop
open http://localhost:30300       # frontend SPA
curl http://localhost:30880/health  # backend health
curl http://localhost:30880/swagger-ui  # API 문서

# minikube
MINIKUBE_IP=$(minikube ip)
open "http://${MINIKUBE_IP}:30300"
```

### 7) 수동 trigger (CronJob suspend 됐으니 직접 호출)

```bash
# 매시간 cron 대신 수동으로
curl -X POST http://localhost:30880/api/pipeline/trigger \
  -H "Authorization: Bearer local-dev-cron-token"
```

또는 Job 1회만 실행:

```bash
kubectl -n axis create job --from=cronjob/axis-cron-ingestion-a manual-run-1
```

---

## In-cluster DB 모드 추가 설정

`postgres.yaml` + `qdrant.yaml` 활성 시 ConfigMap 의 `QDRANT_HOST` 도 cluster-internal URL 로 변경 필요.

```bash
kubectl -n axis edit configmap axis-config
# QDRANT_HOST: http://qdrant:6333
# (기존: https://REPLACE_QDRANT_CLUSTER_ID.qdrant.io)
```

또는 patch 추가:

```yaml
# kustomization.yaml 의 patches: 에 추가
- target:
    kind: ConfigMap
    name: axis-config
  patch: |-
    - op: replace
      path: /data/QDRANT_HOST
      value: http://qdrant:6333
```

---

## 트러블슈팅

| 증상 | 원인 | 대응 |
|---|---|---|
| Pod 가 `ImagePullBackOff` | 이미지 클러스터에 못 올림 | `kind load docker-image ...` (또는 minikube image load) 다시 |
| frontend NodePort 접근 안 됨 | kind 의 extraPortMappings 누락 | kind-config.yaml 의 30300/30880 확인 후 클러스터 재생성 |
| ai 가 `OOMKilled` | BGE-M3 + Reranker 메모리 부족 | deployment-ai patch 의 limits.memory 증가 또는 docker-desktop 메모리 증설 |
| ai 가 5분 후 CrashLoop | huggingface.co 차단 또는 느림 | 인터넷 확인 / 또는 사전 다운로드 후 PVC mount |
| backend `/health` 502 | startup 시간 부족 | startupProbe failureThreshold 증가 |
| PVC `axis-images` Pending | local-path SC 없음 | `kubectl get sc` 확인 후 `standard` 가 default 인지 / 다른 SC 이름이면 patch 갱신 |
| `kubectl apply -k` 가 server fail | 클러스터 미생성 / kubeconfig 잘못 | `kubectl config current-context` 확인, kind/minikube 컨텍스트로 전환 |
| backend 로그 `Flyway Validate failed` | Supabase 의 V1 체크섬과 mismatch | local 모드에서 in-cluster postgres 사용 권장 (clean DB → V1+V2 모두 fresh apply) |

---

## 정리

```bash
# 매니페스트 제거 (PVC 는 보존)
kubectl delete -k k8s/overlays/local

# 클러스터 자체 삭제
kind delete cluster --name axis-local
# 또는
minikube delete
```

---

## EKS 배포 시점에

본 overlay 는 **로컬 검증 전용**. 실 클라우드 배포는 base 그대로 사용 또는 별도 `overlays/staging` · `overlays/prod` 작성.
