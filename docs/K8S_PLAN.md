# AXIS Kubernetes 통합 운영 계획서 (v0 — 초안)

> Docker Compose → K8s 마이그레이션 1차 계획.
> 현재 상태: docker-compose 기반 4 컨테이너 (frontend / backend / ai + DB·Qdrant 는 cloud 관리형).
> 목표 상태: 단일 K8s 클러스터에서 통합 운영 + Ingress · NetworkPolicy · CronJob · Secret 관리 일원화.

---

## 0. 결정 필요 사항 (먼저 합의)

이 문서는 **계획서 v0** 이라 아래 항목은 아직 가정값이다 — 본격 매니페스트 작성 전 한 번 합의해야 한다.

| 항목 | 가정값 | 대안 / 비고 |
|---|---|---|
| 클러스터 종류 | **AWS EKS** | GKE / 자체 kubeadm / k3s — architecture View 3 가 EKS 가정 |
| 노드 수 | t3.large × 2 (2 AZ) | AI 메모리 4~6Gi 필요, frontend/backend 는 작음 |
| 네임스페이스 분리 | 단일 `axis` | dev/staging/prod 분리는 후속 (현재 9주 프로젝트, 환경 분리 부담) |
| Ingress Controller | **AWS ALB Ingress Controller** | nginx-ingress (cloud-agnostic) — 운영팀 친숙도로 결정 |
| 외부 노출 범위 | 사내망 only (internal ALB) | 발주처 데모 시 ACM cert + public ALB 로 일시 전환 |
| 도메인 / TLS | `axis.skax.internal` 가정 | ACM 인증서 ARN 필요 |
| Scheduler 위치 | **K8s CronJob** (4개) | 현재 Spring `@Scheduled` 유지도 가능 — 아래 §7 비교 |
| BGE-M3 모델 캐시 | emptyDir (Pod 재시작마다 재다운) | PVC RWX (EFS) 로 공유 — 모델 ~3GB, 재다운 1~2분 |
| Secret 관리 | K8s Secret (수동) | External Secrets Operator → AWS SSM (architecture 문서 §6 권장) |
| GitOps | 없음 (kubectl apply 직접) | ArgoCD + axis-gitops repo (architecture 문서 권장, 현재 미구현) |
| HPA | backend/frontend only | AI 는 콜드스타트 1~2분이라 HPA 부적합 |

---

## 1. 큰 그림

```
                                 ┌───────────────┐
        사용자 (전략팀 PM)     →  │ AWS ALB       │ ← ACM TLS, internal
                                 │ Ingress       │
                                 └───────┬───────┘
                                         │
                ┌────────────────────────┼────────────────────────┐
                ▼                        ▼                        │
        ┌──────────────┐         ┌──────────────┐                │
        │ axis-frontend│         │ axis-backend │                │
        │ Deploy ×2    │         │ Deploy ×2    │                │
        │ Svc ClusterIP│         │ Svc ClusterIP│                │
        │ :80          │         │ :8080        │                │
        └──────────────┘         └──────┬───────┘                │
                                        │ HTTP /search /pipeline │
                                        ▼                        │
                                 ┌──────────────┐                │
                                 │ axis-ai      │ ← NetworkPolicy│
                                 │ Deploy ×1    │   from=backend │
                                 │ Svc ClusterIP│   only         │
                                 │ :8001        │                │
                                 └──────┬───────┘                │
                                        │                        │
                  ┌─────────────────────┼─────────────────┐      │
                  ▼                     ▼                 ▼      ▼
          ┌──────────────┐     ┌──────────────┐    ┌──────────────┐
          │ Supabase     │     │ Qdrant Cloud │    │ OpenAI/SMTP  │
          │ Postgres     │     │              │    │ DART/Naver   │
          │ (managed)    │     │ (managed)    │    │ ...외부 API  │
          └──────────────┘     └──────────────┘    └──────────────┘

CronJob × 4   ── kubectl 안 → backend trigger endpoint 호출
  ingestion-A : 0 * * * *
  ingestion-B : 0 2 * * *
  delivery    : 30 8 * * 1-5
  weak-signal : 0 9 * * 1   (W7+)
```

---

## 2. Namespace · ResourceQuota · LimitRange

### 2.1 Namespace
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: axis
  labels:
    app.kubernetes.io/part-of: axis
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
```

### 2.2 ResourceQuota (네임스페이스 총량 상한)
```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: axis-quota, namespace: axis }
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    pods: "30"
    persistentvolumeclaims: "5"
```

### 2.3 LimitRange (default · 명시 안 한 Pod 의 fallback)
```yaml
apiVersion: v1
kind: LimitRange
metadata: { name: axis-defaults, namespace: axis }
spec:
  limits:
  - type: Container
    default:        { cpu: "500m", memory: "512Mi" }
    defaultRequest: { cpu: "100m", memory: "128Mi" }
```

---

## 3. Workload 별 상세

### 3.1 axis-frontend (React + nginx)

| 항목 | 값 |
|---|---|
| Replicas | 2 (rolling update) |
| Image | `<account>.dkr.ecr.<region>.amazonaws.com/axis-frontend:<git-sha>` |
| 컨테이너 포트 | 80 (nginx serves Vite build) |
| Resources req | 50m / 128Mi |
| Resources limit | 200m / 256Mi |
| Liveness | `GET / :80` (200 OK) |
| Readiness | 동일 |
| Strategy | RollingUpdate (maxSurge=1, maxUnavailable=0) |
| HPA | 2~4 replicas, CPU 70% |

```yaml
# axis-infra/k8s/base/frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: axis-frontend, namespace: axis }
spec:
  replicas: 2
  selector: { matchLabels: { app: axis-frontend } }
  template:
    metadata: { labels: { app: axis-frontend, tier: presentation } }
    spec:
      containers:
      - name: web
        image: <account>.dkr.ecr.ap-northeast-2.amazonaws.com/axis-frontend:GIT_SHA
        ports: [{ containerPort: 80 }]
        env:
        - name: VITE_API_BASE_URL
          valueFrom: { configMapKeyRef: { name: axis-config, key: VITE_API_BASE_URL } }
        resources:
          requests: { cpu: 50m,  memory: 128Mi }
          limits:   { cpu: 200m, memory: 256Mi }
        livenessProbe:
          httpGet: { path: /, port: 80 }
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet: { path: /, port: 80 }
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata: { name: axis-frontend, namespace: axis }
spec:
  type: ClusterIP
  selector: { app: axis-frontend }
  ports: [{ port: 80, targetPort: 80 }]
```

### 3.2 axis-backend (SpringBoot 3 + Java 17)

| 항목 | 값 |
|---|---|
| Replicas | 2 |
| Image | `axis-backend:<git-sha>` |
| 포트 | 8080 |
| Resources req | 500m / 1Gi |
| Resources limit | 1000m / 2Gi |
| JVM 옵션 | `-XX:MaxRAMPercentage=75 -XX:+UseG1GC` |
| Liveness | `GET /actuator/health/liveness :8080` |
| Readiness | `GET /actuator/health/readiness :8080` |
| HPA | 2~4 replicas, CPU 70% |
| Profile | `SPRING_PROFILES_ACTIVE=prod` |

```yaml
# k8s/base/backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: axis-backend, namespace: axis }
spec:
  replicas: 2
  selector: { matchLabels: { app: axis-backend } }
  template:
    metadata: { labels: { app: axis-backend, tier: business } }
    spec:
      serviceAccountName: axis-backend-sa
      containers:
      - name: api
        image: <account>.dkr.ecr.ap-northeast-2.amazonaws.com/axis-backend:GIT_SHA
        ports: [{ containerPort: 8080 }]
        envFrom:
        - configMapRef: { name: axis-config }
        - secretRef:    { name: axis-secrets }
        env:
        - name: JAVA_TOOL_OPTIONS
          value: "-XX:MaxRAMPercentage=75 -XX:+UseG1GC"
        resources:
          requests: { cpu: 500m,  memory: 1Gi }
          limits:   { cpu: 1000m, memory: 2Gi }
        livenessProbe:
          httpGet: { path: /actuator/health/liveness, port: 8080 }
          initialDelaySeconds: 60
          periodSeconds: 30
          failureThreshold: 3
        readinessProbe:
          httpGet: { path: /actuator/health/readiness, port: 8080 }
          initialDelaySeconds: 30
          periodSeconds: 10
        startupProbe:    # SpringBoot 부팅 30~60초 — startup 분리해서 liveness 안 죽이기
          httpGet: { path: /actuator/health, port: 8080 }
          failureThreshold: 30
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata: { name: axis-backend, namespace: axis }
spec:
  type: ClusterIP
  selector: { app: axis-backend }
  ports: [{ port: 8080, targetPort: 8080 }]
```

> **TODO**: SpringBoot 의 `@Scheduled` 가 2 replicas 모두에서 실행되면 중복 트리거. 해결책 — (A) ShedLock 도입, (B) 스케줄러를 K8s CronJob 으로 이전 (§7 권장).

### 3.3 axis-ai (FastAPI + Python 3.11 + BGE-M3)

| 항목 | 값 |
|---|---|
| Replicas | **1** (메모리 비용 + 모델 캐시 단일성) |
| Image | `axis-ai:<git-sha>` |
| 포트 | 8001 (NEVER expose externally) |
| Resources req | 1500m / 4Gi |
| Resources limit | 2000m / 6Gi |
| Liveness | `GET /health :8001` |
| Readiness | `GET /health :8001` (모델 로드 후만 Ready) |
| Strategy | RollingUpdate (maxSurge=0, maxUnavailable=1) |
| HPA | **불사용** — 콜드스타트 1~2분 |

```yaml
# k8s/base/ai-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: axis-ai, namespace: axis }
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 0, maxUnavailable: 1 }   # 메모리 절약 — 동시 2 Pod 띄우지 않음
  selector: { matchLabels: { app: axis-ai } }
  template:
    metadata: { labels: { app: axis-ai, tier: business } }
    spec:
      serviceAccountName: axis-ai-sa
      containers:
      - name: ai
        image: <account>.dkr.ecr.ap-northeast-2.amazonaws.com/axis-ai:GIT_SHA
        ports: [{ containerPort: 8001 }]
        envFrom:
        - configMapRef: { name: axis-config }
        - secretRef:    { name: axis-secrets }
        resources:
          requests: { cpu: 1500m, memory: 4Gi }
          limits:   { cpu: 2000m, memory: 6Gi }
        livenessProbe:
          httpGet: { path: /health, port: 8001 }
          initialDelaySeconds: 120     # BGE-M3 로딩 시간 확보
          periodSeconds: 30
          failureThreshold: 5
        readinessProbe:
          httpGet: { path: /health, port: 8001 }
          initialDelaySeconds: 60
          periodSeconds: 10
        startupProbe:
          httpGet: { path: /health, port: 8001 }
          failureThreshold: 60         # 5분까지 모델 로드 허용
          periodSeconds: 5
        volumeMounts:
        - { name: model-cache, mountPath: /root/.cache/huggingface }
      volumes:
      - name: model-cache
        emptyDir: { sizeLimit: 8Gi }    # 첫 부팅 시 BGE-M3 + Reranker 다운로드, Pod 재시작 시 재다운
---
apiVersion: v1
kind: Service
metadata: { name: axis-ai, namespace: axis }
spec:
  type: ClusterIP
  selector: { app: axis-ai }
  ports: [{ port: 8001, targetPort: 8001 }]
```

> **모델 캐시 옵션**: emptyDir 가 v0 권장 — 단순. 향후 ai 가 ×2 로 늘어나거나 Pod 재시작 빈도 높아지면 EFS PVC (RWX) 로 전환.

---

## 4. Ingress 설계

### 4.1 ALB Ingress (단일 호스트 기준)

```yaml
# k8s/base/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: axis
  namespace: axis
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal           # 사내망만
    alb.ingress.kubernetes.io/target-type: ip            # Pod IP 직접 (faster failover)
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-2:ACCOUNT:certificate/UUID
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '15'
spec:
  rules:
  - host: axis.skax.internal
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend: { service: { name: axis-backend, port: { number: 8080 } } }
      - path: /actuator
        pathType: Prefix
        backend: { service: { name: axis-backend, port: { number: 8080 } } }
      - path: /
        pathType: Prefix
        backend: { service: { name: axis-frontend, port: { number: 80 } } }
```

### 4.2 라우팅 정책

| 경로 | 백엔드 서비스 | 비고 |
|---|---|---|
| `/api/*` | `axis-backend:8080` | REST API |
| `/actuator/*` | `axis-backend:8080` | health · metrics (사내 only) |
| `/` (그 외 전부) | `axis-frontend:80` | SPA — nginx 가 fallback `index.html` |

**axis-ai (8001) 는 Ingress 에 절대 등록하지 않는다** — 외부 차단.

---

## 5. NetworkPolicy (필수)

axis-ai 가 인터넷에 노출되면 안 되므로 NetworkPolicy 강제.

### 5.1 default-deny ingress
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: axis }
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

### 5.2 frontend ← ALB controller
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-frontend-from-ingress, namespace: axis }
spec:
  podSelector: { matchLabels: { app: axis-frontend } }
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
      podSelector: { matchLabels: { app.kubernetes.io/name: aws-load-balancer-controller } }
    ports: [{ protocol: TCP, port: 80 }]
```

### 5.3 backend ← ALB + 같은 네임스페이스의 CronJob
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-backend, namespace: axis }
spec:
  podSelector: { matchLabels: { app: axis-backend } }
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
    - podSelector: { matchLabels: { app.kubernetes.io/component: cron } }
    ports: [{ protocol: TCP, port: 8080 }]
```

### 5.4 ai ← backend ONLY
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-ai-from-backend, namespace: axis }
spec:
  podSelector: { matchLabels: { app: axis-ai } }
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: { matchLabels: { app: axis-backend } }
    ports: [{ protocol: TCP, port: 8001 }]
```

### 5.5 egress 정책
모든 Pod 의 egress 는 기본 허용 (Supabase / Qdrant Cloud / OpenAI / SMTP / DART API 등 외부 호출 필요). 차단하려면 별도 NetworkPolicy 추가.

---

## 6. ConfigMap · Secret

### 6.1 ConfigMap (비밀이 아닌 설정)

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: axis-config, namespace: axis }
data:
  # backend
  SPRING_PROFILES_ACTIVE: prod
  AI_SERVER_URL: http://axis-ai:8001
  MAIL_HOST: smtp.sendgrid.net
  MAIL_PORT: "587"
  MAIL_BRIEFING_RECIPIENTS: "pm@example.co.kr,executive@example.co.kr"
  # ai
  QDRANT_HOST: <cluster>.qdrant.io
  QDRANT_PORT: "6333"
  AI_SERVER_PORT: "8001"
  # frontend
  VITE_API_BASE_URL: https://axis.skax.internal
```

### 6.2 Secret (자격증명)

```yaml
apiVersion: v1
kind: Secret
metadata: { name: axis-secrets, namespace: axis }
type: Opaque
stringData:
  # DB (Supabase pooler)
  SPRING_DATASOURCE_URL: jdbc:postgresql://<pooler>.supabase.com:6543/postgres?sslmode=require
  SPRING_DATASOURCE_USERNAME: postgres.xxxx
  SPRING_DATASOURCE_PASSWORD: <secret>
  DATABASE_URL: postgresql://postgres.xxxx:<secret>@<pooler>.supabase.com:6543/postgres?sslmode=require
  # vector
  QDRANT_API_KEY: <secret>
  # LLM
  OPENAI_API_KEY: sk-...
  # crawl
  NAVER_CLIENT_ID: <secret>
  NAVER_CLIENT_SECRET: <secret>
  DART_API_KEY: <secret>
  KIPRIS_API_KEY: <secret>
  SARAMIN_API_KEY: <secret>
  # email
  SENDGRID_API_KEY: <secret>
  # auth
  AXIS_AUTH_JWT_SECRET: <secret>
```

> **운영 권장**: 위 Secret 을 직접 매니페스트에 두지 않고 **External Secrets Operator + AWS SSM Parameter Store** 로 sync. architecture 문서 §6 의 권장사항.

---

## 7. CronJob × 4 (스케줄러)

### 결정: Spring `@Scheduled` 제거, K8s CronJob 으로 이전

| 비교 | Spring `@Scheduled` (현재) | K8s CronJob (제안) |
|---|---|---|
| 멀티 replica 안전성 | 필요 (ShedLock 도입) | 자동 (CronJob 은 Job 1개 생성) |
| 관측성 | Spring 로그에 묻힘 | `kubectl get jobs` 로 직접 확인 |
| 실패 재시도 | 코드에서 수동 | `backoffLimit` 으로 K8s 가 처리 |
| 환경별 스케줄 변경 | application.yml 변경 → 재배포 | overlay 의 CronJob 만 수정 |

### 7.1 Track A 인제스션 — 매시간

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: axis-cron-ingestion-a, namespace: axis }
spec:
  schedule: "0 * * * *"
  concurrencyPolicy: Forbid          # 직전 Job 안 끝났으면 새 Job 안 만듦
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 1800     # 30분 안에 못 끝나면 timeout
      template:
        metadata: { labels: { app.kubernetes.io/component: cron, cron: ingestion-a } }
        spec:
          restartPolicy: OnFailure
          containers:
          - name: trigger
            image: curlimages/curl:8.5.0
            command:
            - sh
            - -c
            - |
              curl -fsSL --max-time 60 \
                -X POST \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $JWT_TOKEN" \
                "http://axis-backend:8080/api/pipeline/trigger?track=A"
            env:
            - name: JWT_TOKEN
              valueFrom: { secretKeyRef: { name: axis-cron-token, key: token } }
```

### 7.2 Track B 인제스션 — 02:00
`schedule: "0 2 * * *"` · `activeDeadlineSeconds: 3600` (재무 PDF 파싱 1시간 허용)

### 7.3 Delivery — 평일 08:30
`schedule: "30 8 * * 1-5"` · `activeDeadlineSeconds: 600`

### 7.4 Weak Signal — 월 09:00 (W7+)
`schedule: "0 9 * * 1"` · `suspend: true` (지금은 일시 중단, W7 활성 시 false)

---

## 8. Storage

| 용도 | 선택 | 비고 |
|---|---|---|
| BGE-M3 모델 캐시 | **emptyDir** (v0) | 첫 부팅 1~2분 다운로드. ai replica 수 늘어나면 EFS PVC 로 전환 |
| postgres 데이터 | — | Supabase 가 관리 (K8s 안 사용) |
| qdrant 데이터 | — | Qdrant Cloud 가 관리 |
| 로그 / 임시 파일 | emptyDir | stdout 으로만 — 영속화 X |

PVC 가 필요해질 시점:
- ai replica ≥ 2 → 모델 캐시 공유 위해 EFS RWX
- pipeline_logs 가 PG 외에 파일로도 보관해야 한다면 → 보통은 CloudWatch Logs 로 충분

---

## 9. 옵저버빌리티

### 9.1 로깅
- 모든 컨테이너 stdout / stderr → CloudWatch Logs (EKS 기본 fluent-bit 데몬셋)
- 구조화 로그 권장: backend = JSON Layout, ai = `python-json-logger`

### 9.2 메트릭
- backend Spring Actuator: `/actuator/prometheus` (별도 ServiceMonitor 필요)
- ai FastAPI: `prometheus-fastapi-instrumentator` 추가 후 `/metrics` 노출
- 권장: Prometheus + Grafana (operator 설치) — v1 후속

### 9.3 헬스체크 정리
| 서비스 | path | startup | liveness | readiness |
|---|---|---|---|---|
| frontend | `/` | — | 30s 간격 | 10s |
| backend | `/actuator/health/*` | 30 × 5s | 30s | 10s |
| ai | `/health` | 60 × 5s (5분) | 30s, fail 5 | 10s |

ai 의 startupProbe 가 핵심 — BGE-M3 다운로드·로드 1~2분 걸리는데 liveness 가 죽이면 Pod 가 영원히 부팅 못 함.

---

## 10. 보안

| 항목 | 정책 |
|---|---|
| Pod Security Standards | `baseline` enforce, `restricted` warn |
| ServiceAccount | 워크로드별 분리 (`axis-frontend-sa` / `axis-backend-sa` / `axis-ai-sa` / `axis-cron-sa`) |
| RBAC | 모두 default — Kube API 호출 권한 없음 |
| Image scanning | ECR scan-on-push 활성 |
| Secret rotation | External Secrets + SSM (운영 시 도입) |
| TLS | ALB termination · 내부 통신은 HTTP (mTLS 후속 검토) |
| NetworkPolicy | §5 — ai 는 backend 만 접근 가능 |
| readOnlyRootFilesystem | 가능한 곳 (frontend) 적용, ai 는 모델 캐시 때문에 false |

---

## 11. CI/CD 통합

### 11.1 변경 사항
현재 4 레포 CI 는 **빌드·테스트만**. K8s 배포 위해 추가:

1. **Docker 이미지 빌드 + ECR push** — main/develop 머지 시
2. **매니페스트 image tag 갱신** — 새 SHA 로 patch
3. **kubectl apply** (또는 ArgoCD sync)

### 11.2 axis-ai 예시 추가 (.github/workflows/cd.yml 신설)
```yaml
name: CD
on:
  push: { branches: [main] }
jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions: { id-token: write, contents: read }
    steps:
    - uses: actions/checkout@v4
    - name: Configure AWS via OIDC
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: arn:aws:iam::ACCOUNT:role/gha-axis-ai
        aws-region: ap-northeast-2
    - run: aws ecr get-login-password | docker login --username AWS --password-stdin ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
    - run: docker build -t axis-ai:${{ github.sha }} .
    - run: docker tag axis-ai:${{ github.sha }} ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/axis-ai:${{ github.sha }}
    - run: docker push ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/axis-ai:${{ github.sha }}
    - name: Update manifest
      run: |
        # 추후 axis-gitops 레포 또는 axis-infra/k8s/overlays/prod/kustomization.yaml 의 image tag 갱신
```

### 11.3 GitOps 도입 시 (후속)
- `axis-gitops` 레포 신설 — `manifests/{env}/{service}/kustomization.yaml`
- ArgoCD Application 5개 (frontend / backend / ai / ingress / cron)
- 자동 sync (sync-policy.automated.prune=true)

---

## 12. 매니페스트 디렉토리 구조 (제안)

```
axis-infra/
└── k8s/
    ├── base/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── configmap.yaml
    │   ├── secret.example.yaml         ← 실값 X, 예시만
    │   ├── frontend-deployment.yaml
    │   ├── frontend-service.yaml
    │   ├── backend-deployment.yaml
    │   ├── backend-service.yaml
    │   ├── ai-deployment.yaml
    │   ├── ai-service.yaml
    │   ├── ingress.yaml
    │   ├── networkpolicy.yaml
    │   ├── hpa-frontend.yaml
    │   ├── hpa-backend.yaml
    │   ├── cronjob-ingestion-a.yaml
    │   ├── cronjob-ingestion-b.yaml
    │   ├── cronjob-delivery.yaml
    │   ├── cronjob-weak-signal.yaml
    │   └── serviceaccounts.yaml
    └── overlays/
        ├── staging/
        │   └── kustomization.yaml      ← 이미지 tag · replicas · 호스트 override
        └── prod/
            └── kustomization.yaml
```

---

## 13. Docker Compose → K8s 마이그레이션 단계

| 단계 | 작업 | 검증 |
|---|---|---|
| 1 | EKS 클러스터 + ECR 리포지토리 3개 생성 | `kubectl get nodes` |
| 2 | ALB Controller + ExternalDNS 설치 | helm 설치 후 `kubectl get pods -n kube-system` |
| 3 | namespace + ConfigMap + Secret 생성 | `kubectl get configmap,secret -n axis` |
| 4 | ai Deployment 만 먼저 배포 (단일 컨테이너 검증) | `kubectl exec` 로 `/health` 확인 |
| 5 | backend Deployment 추가, AI_SERVER_URL=http://axis-ai:8001 | backend → ai 통신 확인 |
| 6 | frontend Deployment + Ingress 추가 | 브라우저로 SPA 접근 |
| 7 | NetworkPolicy 적용 | `kubectl exec` 로 외부 → ai 차단 확인 |
| 8 | CronJob 4개 배포 (W7+ 는 suspend) | `kubectl get cronjob -n axis` |
| 9 | Spring `@Scheduled` 제거 + ShedLock 의존성 정리 | backend redeploy |
| 10 | docker-compose.prod.yml 폐기 (compose 는 로컬 only) | 운영 trafic 전환 |

---

## 14. 미해결 질문 / 후속 결정 항목

1. **클러스터 종류 확정** — EKS 가정 맞는지? (예산, 사내 보안 정책)
2. **Public vs Internal ALB** — 발주처 데모 시 외부 노출 일시 허용?
3. **도메인 / 인증서** — `axis.skax.internal` 가정. 실제 도메인과 ACM ARN 확정 필요
4. **GitOps 도입 시점** — v0 는 kubectl 직접, v1 에서 ArgoCD?
5. **External Secrets Operator** — SSM 사용 권한 + IRSA 설정 필요
6. **Spring `@Scheduled` 제거 여부** — CronJob 으로 이전 시 backend 코드 변경 필요
7. **모델 캐시 PVC 전환 시점** — ai 가 단일 replica 인 한 emptyDir 면 충분
8. **HPA 상한** — backend 4, frontend 4 가정. 실제 트래픽 측정 후 조정
9. **로그 보관 정책** — CloudWatch Logs retention 며칠? (기본 무제한 → 비용)
10. **failure mode** — Supabase / Qdrant Cloud / OpenAI 외부 의존성 down 시 대응 룰

---

## 15. v0 → v1 로드맵

| 버전 | 범위 |
|---|---|
| **v0 (이 문서)** | 위 §1~§13 — 매니페스트 작성 + EKS 단일 환경 + kubectl 직배포 |
| v1 | ArgoCD GitOps + External Secrets + Prometheus/Grafana + staging overlay 분리 |
| v2 | mTLS (Istio?) + 멀티 AZ HPA 튜닝 + 모델 캐시 EFS PVC + DR runbook |
| v3 | (만약 트래픽 ↑) ai 멀티 replica + Qdrant 사이드카 캐시 검토 |

---

## 부록 A — 환경변수 매트릭스

| 변수 | frontend | backend | ai | 출처 |
|---|---|---|---|---|
| `VITE_API_BASE_URL` | ✓ | | | ConfigMap |
| `SPRING_PROFILES_ACTIVE` | | ✓ | | ConfigMap |
| `AI_SERVER_URL` | | ✓ | | ConfigMap |
| `SPRING_DATASOURCE_*` | | ✓ | | Secret |
| `DATABASE_URL` | | | ✓ | Secret |
| `QDRANT_HOST` / `_PORT` | | | ✓ | ConfigMap |
| `QDRANT_API_KEY` | | | ✓ | Secret |
| `OPENAI_API_KEY` | | | ✓ | Secret |
| `NAVER_CLIENT_*` | | | ✓ | Secret |
| `DART_API_KEY` | | | ✓ | Secret |
| `KIPRIS_API_KEY` | | | ✓ | Secret |
| `SARAMIN_API_KEY` | | | ✓ | Secret |
| `MAIL_HOST` / `_PORT` | | ✓ | | ConfigMap |
| `MAIL_BRIEFING_RECIPIENTS` | | ✓ | | ConfigMap |
| `SENDGRID_API_KEY` | | ✓ | | Secret |
| `AXIS_AUTH_JWT_SECRET` | | ✓ | | Secret |

---

## 부록 B — 포트 매핑 정리

| 서비스 | 컨테이너 포트 | Service 포트 | Ingress 노출 | 외부 도달 |
|---|---|---|---|---|
| axis-frontend | 80 | 80 | `/` | ✓ (사내망) |
| axis-backend | 8080 | 8080 | `/api`, `/actuator` | ✓ (사내망) |
| axis-ai | 8001 | 8001 | — | ✗ (NetworkPolicy 차단) |
