# AXIS 인프라 구축 계획서 (v0)

> **목적**: 현재 docker-compose 기반 로컬 운영을 K8s 기반 통합 운영으로 옮기기 위한 **결정 항목 · 선결 조건 · 마이그레이션 단계** 정리.
>
> **이 문서가 답하지 않는 것**: 실제 매니페스트 YAML 풀세트 (선결 조건이 합의된 후 별도 작성).
>
> **현재 상태 (실측)**:
> - 인프라: Docker Compose (cloud 모드 / local 모드 2개), 4 서비스
> - DB: Supabase (managed) · Vector: Qdrant Cloud (managed)
> - CI: GitHub Actions × 4 레포 (빌드·테스트만, 이미지 push 없음)
> - CD: 없음 — 누군가 수동으로 `docker compose up`
> - 클러스터: 없음 (EKS 미생성)

---

## §1 · 핵심 결정 사항 — 의사결정 매트릭스

이 표의 모든 항목은 **다음 회의에서 답이 나와야 매니페스트 작성 시작 가능**.

| # | 항목 | 옵션 | 권장 | 결정 시점 | 결정자 |
|---|---|---|---|---|---|
| D1 | **클러스터 종류** | (a) AWS EKS · (b) GCP GKE · (c) 자체 kubeadm · (d) k3s 단일 노드 | EKS (architecture View 3 가정) | 즉시 | PM + Backend Lead |
| D2 | **노드 사양** | (a) t3.large × 2 · (b) t3.xlarge × 2 · (c) m5.xlarge × 2 | t3.xlarge × 2 (AI 메모리 4~6Gi 안전) | D1 직후 | Backend Lead |
| D3 | **AZ 배치** | (a) 단일 AZ · (b) 2 AZ · (c) 3 AZ | 2 AZ (architecture 가정) | D1 직후 | Backend Lead |
| D4 | **외부 노출 범위** | (a) Public ALB · (b) Internal ALB only · (c) Public + IP allowlist | Internal + 발주처 데모 시 일시 Public | 1주차 | PM |
| D5 | **도메인 / TLS** | 사내 도메인? · 외부 도메인? · ACM 인증서 ARN? | `axis.skax.internal` 가정 (실제 미정) | 1주차 | PM |
| D6 | **CronJob 위치** | (a) Spring `@Scheduled` 유지 + ShedLock · (b) K8s CronJob 으로 이전 | (b) — 환경별 스케줄 변경 용이 | 1주차 | Backend Lead |
| D7 | **CronJob 인증** | (a) 내부 토큰 (Secret) · (b) Service Mesh mTLS · (c) NetworkPolicy 만 | (a) — 가장 단순 | D6 결정 후 | Backend Lead |
| D8a | **메일 서비스 (어디로)** | (a) SendGrid · (b) Gmail SMTP · (c) AWS SES | SendGrid (production) / Gmail (개발) | 1주차 | PM |
| D8b | **메일 발송 주체 (누가)** | (a) axis-ai (DeliverySupervisor.EmailAgent) · (b) axis-backend (BriefingService) | (a) — architecture/04 §4.5 와 일치, SMTP 자격증명을 ai pod 에만 주입 | 1주차 | AI Lead + Backend Lead |
| D9 | **Slack webhook** | (a) 완전 폐기 · (b) 옵션으로 유지 | (a) 폐기 — 코드의 잔재 정리 | 즉시 | AI Lead |
| D10 | **BGE-M3 모델 캐시** | (a) emptyDir (Pod 마다 다운로드) · (b) EFS PVC RWX (공유) · (c) 이미지에 baked in | (a) v0 · (b) 가 v1 | 즉시 | AI Lead |
| D11 | **HuggingFace 다운로드 경로** | (a) 직접 huggingface.co · (b) S3 미러 · (c) 사내 PyPI/Mirror | (a) 가능 여부 사내망 정책 확인 | 1주차 | DevOps |
| D12 | **Frontend 환경변수** | (a) 빌드타임 baked in (Vite 기본) · (b) 런타임 config.js fetch 패턴 | (b) — 한 이미지로 모든 환경 운영 | 2주차 | Frontend |
| D13 | **GitOps 도입** | (a) v0: kubectl 직접 · (b) ArgoCD + axis-gitops repo 신설 | (a) v0 → (b) v1 | 2주차 | Backend Lead |
| D14 | **Secret 관리** | (a) K8s Secret manual · (b) Sealed Secrets · (c) External Secrets + AWS SSM | (c) — architecture 권장 | 2주차 | DevOps |
| D15 | **이미지 레지스트리** | (a) AWS ECR · (b) GitHub Container Registry · (c) Docker Hub | (a) ECR (EKS 와 IAM 통합) | D1 직후 | DevOps |
| D16 | **로그 보관** | (a) CloudWatch Logs (retention?) · (b) ELK · (c) Grafana Loki | (a) 14일 retention | 2주차 | DevOps |
| D17 | **모니터링** | (a) CloudWatch metrics 만 · (b) Prometheus + Grafana · (c) Datadog | (a) v0 · (b) v1 | 2주차 | DevOps |

---

## §2 · 선결 조건 — 코드 변경 (배포 전 반드시 처리)

K8s 매니페스트 적용 전에 각 레포에서 아래 변경이 끝나야 함. **현재 코드 그대로 K8s 에 올리면 5번 항목에서 깨진다**.

### 2.1 axis-backend (Spring Boot)

| # | 변경 | 이유 | 파일 |
|---|---|---|---|
| B1 | `/api/pipeline/trigger` 가 `?track=A\|B` 쿼리 받도록 | CronJob 이 Track A/B 분기 호출 | [`PipelineController.java`](../../axis-backend/src/main/java/com/skala/axis/controller/PipelineController.java) |
| B2 | `triggerPipeline(List.of("samsung_sds", "lg_cns"))` hardcoded → 4사 전체 | 현재 2사만 호출 — 현대오토에버·포스코DX 누락 | [`PipelineController.java:23`](../../axis-backend/src/main/java/com/skala/axis/controller/PipelineController.java#L23) |
| B3 | `@Scheduled` 어노테이션 제거 (D6=b 시) | 멀티 replica 중복 트리거 방지 | [`SchedulerConfig.java`](../../axis-backend/src/main/java/com/skala/axis/config/SchedulerConfig.java) |
| ~~B4~~ | ~~`application.yml` 에 mail 설정 추가~~ | D8b=a 결정 시 backend 가 메일 안 보냄 — 변경 불필요 (취소) | — |
| B5 | `slack.webhook-url` 설정 제거 (D9=a 시) | "Slack 폐기" 라고 docs 에 적어둔 잔재 | [`application.yml:36-38`](../../axis-backend/src/main/resources/application.yml#L36-L38) |
| B6 | Spring Actuator probes 활성 (선택) | `/actuator/health/liveness/readiness` 사용하려면 — 안 할 거면 `/health` 그대로 | `application.yml` |
| B7 | `/api/pipeline/trigger` 에 내부 토큰 헤더 검증 추가 | CronJob 이 외부 사용자처럼 호출되지 않도록 | 신규 SecurityFilter |
| B8 | `/api/pipeline/delivery` endpoint 신설 (D6=b 시) | CronJob → backend → ai `/pipeline/delivery` 위임. backend 는 트리거만, 실제 SMTP 는 ai 측 EmailAgent (D8b=a) | `PipelineController.java` + `AiClientService.java` |

### 2.2 axis-ai (FastAPI)

| # | 변경 | 이유 | 파일 |
|---|---|---|---|
| A1 | `/pipeline/run` 이 `track` 쿼리 파라미터 받기 | Track A/B 분기 (architecture View 4 §4.7) | [`router.py:55`](../../axis-ai/src/api/router.py#L55) |
| A2 | ingestion_graph 가 `track` 으로 분기 (Track A: FinancialLink skip / Track B: 활성) | architecture 설계 반영 — supervisor 패턴은 후순위, 단순 if 분기로 시작 가능 | [`ingestion_graph.py`](../../axis-ai/src/pipeline/ingestion_graph.py) |
| A3 | BGE-M3 다운로드 폴백 경로 (D11 결정 후) | 사내망 huggingface.co 차단 시 InitContainer + S3 미러 | `Dockerfile` 또는 K8s InitContainer |

### 2.3 axis-frontend (Vite + React)

| # | 변경 | 이유 | 파일 |
|---|---|---|---|
| F1 | nginx.conf 의 `/api → http://backend:8080` proxy 제거 또는 K8s Service 이름으로 | 현재 docker-compose 의 backend 서비스명 의존. K8s 에서는 Ingress 가 라우팅 | [`nginx.conf:11-15`](../../axis-frontend/nginx.conf#L11-L15) |
| F2 | 런타임 설정 패턴 도입 (D12=b 시) | `VITE_API_BASE_URL` 빌드타임 → 런타임 `/config.js` 동적 로드 | `index.html` + 신규 `config.js` |
| F3 | nginx serve 포트 명시: `EXPOSE 3000` (이미 OK) | 변경 없음 — K8s Service targetPort 도 3000 | [`Dockerfile:9`](../../axis-frontend/Dockerfile#L9) ✓ |

### 2.4 axis-infra (specs + manifests)

| # | 변경 | 이유 |
|---|---|---|
| I1 | `k8s/base/*.yaml` 매니페스트 작성 | 본 계획서 §4~§7 따라 |
| I2 | `.env.example` ↔ `application.yml` ↔ Python 코드 환경변수 이름 정합성 (`SMTP_*` vs `MAIL_*`) | 현재 불일치 — 부록 A 참조 |
| I3 | OpenAPI 스펙에 `/api/pipeline/trigger?track=` 반영 | B1 변경 동반 |

---

## §3 · 선결 조건 — 인프라

K8s 클러스터 띄우기 전 AWS 리소스 준비. 일정상 **D-7 ~ D-3** 작업.

| # | 작업 | 도구 | 비고 |
|---|---|---|---|
| N1 | EKS 클러스터 생성 (1.29+) | eksctl 또는 Terraform | 노드 그룹 t3.xlarge × 2 (D2/D3) |
| N2 | ECR 리포지토리 3개 (`axis-frontend`, `axis-backend`, `axis-ai`) | aws cli | 이미지 push 대상 |
| N3 | Route53 호스팅 영역 + 레코드 (`axis.skax.internal`) | aws cli | D5 결정 후 |
| N4 | ACM 인증서 발급 + 검증 | aws cli | ALB TLS termination 용 |
| N5 | IAM 역할 — IRSA 3개 (frontend / backend / ai) | aws cli | ServiceAccount 와 1:1 매핑 |
| N6 | IAM 역할 — GHA OIDC (push to ECR) | aws cli | 각 레포의 CD workflow 가 사용 |
| N7 | AWS Load Balancer Controller 설치 | helm | ALB Ingress 동작 전제 |
| N8 | metrics-server 설치 | helm 또는 manifest | HPA 동작 전제 |
| N9 | NetworkPolicy 지원 CNI 활성 | EKS 콘솔 또는 Calico/Cilium 설치 | VPC CNI + NetworkPolicy enable |
| N10 | External Secrets Operator (D14=c 시) | helm | SSM Parameter Store 연동 |
| N11 | SSM Parameter Store 에 secret 적재 | aws cli | 코드 변경 없는 secret rotation |
| N12 | (선택) ArgoCD 설치 + axis-gitops repo (D13=b 시) | helm + GitHub | v1 단계 |
| N13 | CloudWatch Logs 그룹 생성 + retention 설정 | aws cli | D16 결정값 (예: 14일) |

---

## §4 · 워크로드 설계 (실제 코드와 일치)

> 모든 port · service 이름 · env var 는 **부록 A 의 통일 매트릭스를 단일 진실원** 으로 한다.

### 4.1 axis-frontend

| 항목 | 값 | 출처 |
|---|---|---|
| 컨테이너 포트 | **3000** | [`nginx.conf:2`](../../axis-frontend/nginx.conf#L2) `listen 3000`, [`Dockerfile:9`](../../axis-frontend/Dockerfile#L9) `EXPOSE 3000` |
| Service port | 3000 | targetPort = 3000 |
| Replicas | 2 | rolling update |
| Resources | req 50m/128Mi · limit 200m/256Mi | nginx + 정적 자원 |
| Probes | `GET /` :3000 (200 OK) | nginx 가 항상 응답 |
| HPA | 2~4, CPU 70% | metrics-server 필요 |
| Strategy | RollingUpdate (maxSurge=1, maxUnavailable=0) | |
| 환경변수 | `VITE_API_BASE_URL` (런타임 또는 빌드타임 — D12) | |

### 4.2 axis-backend

| 항목 | 값 | 출처 |
|---|---|---|
| 컨테이너 포트 | **8080** | [`Dockerfile:14`](../../axis-backend/Dockerfile#L14) `EXPOSE 8080` |
| Service port | 8080 | |
| Replicas | 2 (D6=b 시) / 1 (D6=a 시) | `@Scheduled` 중복 방지 |
| Resources | req 500m/1Gi · limit 1000m/2Gi | JVM heap 75% |
| JVM | `-XX:MaxRAMPercentage=75 -XX:+UseG1GC` | |
| Liveness | `GET /health` :8080 | [`HealthController.java:11`](../../axis-backend/src/main/java/com/skala/axis/controller/HealthController.java#L11) (custom, NOT actuator) |
| Readiness | 동일 | |
| Startup | `GET /health` :8080, failureThreshold=30, periodSeconds=5 | Spring Boot 부팅 30~60초 |
| HPA | 2~4 (D6=b 시) | |
| 환경변수 | §6.1 ConfigMap + §6.2 Secret | |

> **주의**: `/actuator/health/liveness/readiness` 는 [`application.yml:46-50`](../../axis-backend/src/main/resources/application.yml#L46-L50) 에 probes config 가 없어서 **현재 동작 안 함**. K8S_PLAN v0 의 잘못된 가정. B6 으로 활성하거나 단순 `/health` 사용.

### 4.3 axis-ai

| 항목 | 값 | 출처 |
|---|---|---|
| 컨테이너 포트 | **8001** | [`Dockerfile:31`](../../axis-ai/Dockerfile#L31) `EXPOSE 8001` |
| Service port | 8001 | |
| Replicas | **1** (절대 ×2 금지 — emptyDir 모델 캐시 + 메모리 비용) | |
| Resources | req 1500m/4Gi · limit 2000m/6Gi | BGE-M3 (~2Gi) + Reranker (~1Gi) + FastAPI 워킹셋 |
| Liveness | `GET /health` :8001 | [`router.py:42`](../../axis-ai/src/api/router.py#L42) |
| Readiness | 동일 | 모델 로드 후만 200 |
| Startup | `GET /health` :8001, failureThreshold=60, periodSeconds=5 | 첫 부팅 BGE-M3 다운로드 1~3분 |
| Strategy | RollingUpdate (maxSurge=0, maxUnavailable=1) | 동시 2 Pod 메모리 8Gi 회피 |
| HPA | **불사용** | 콜드스타트 1~3분 |
| Volume | `emptyDir: { sizeLimit: 8Gi }` mount `/root/.cache/huggingface` | D10=a |
| 외부 노출 | **불가** (Ingress 미등록 + NetworkPolicy 차단) | Backend pod 만 접근 가능 |
| 환경변수 | §6.1 ConfigMap + §6.2 Secret | |

---

## §5 · Ingress · 라우팅 · NetworkPolicy

### 5.1 Ingress 라우팅

```
ALB → Ingress Controller → 두 Service 만 라우팅 (axis-ai 는 등록 X)

axis.skax.internal/api/*       → axis-backend:8080   (REST API)
axis.skax.internal/swagger-ui  → axis-backend:8080   (개발 시만)
axis.skax.internal/api-docs    → axis-backend:8080   (개발 시만)
axis.skax.internal/            → axis-frontend:3000  (SPA — fallback /index.html)
```

`/health` 는 ALB target group 의 healthcheck-path 로 사용 → **axis-backend:8080/health**.

### 5.2 NetworkPolicy 매트릭스 (default-deny-ingress 베이스)

| Source → Target | 허용 포트 | 비고 |
|---|---|---|
| ALB Controller → axis-frontend | 3000/TCP | `kube-system` ns 의 ALB controller pod |
| ALB Controller → axis-backend | 8080/TCP | |
| axis-backend → axis-ai | 8001/TCP | **유일한 ai 접근 경로** |
| axis-cron-* → axis-backend | 8080/TCP | 같은 ns, label `app.kubernetes.io/component=cron` |
| 그 외 모두 → axis-ai | 차단 | NetworkPolicy default-deny |

egress 는 모두 허용 (외부 SaaS 호출 필요: Supabase · Qdrant Cloud · OpenAI · DART · Naver · KIPRIS · Saramin · SMTP · S3).

---

## §6 · ConfigMap · Secret 분류

### 6.1 ConfigMap (`axis-config`) — 비밀 아닌 설정

| 키 | 값 | 사용 워크로드 |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | `prod` | backend |
| `AI_SERVER_URL` | `http://axis-ai:8001` | backend |
| `QDRANT_HOST` | `https://<cluster>.qdrant.io` | ai |
| `QDRANT_PORT` | `6333` | ai |
| `AI_SERVER_PORT` | `8001` | ai |
| `SMTP_HOST` | `smtp.sendgrid.net` (D8a=a) | ai (D8b=a) |
| `SMTP_PORT` | `587` | ai |
| `SMTP_FROM` | `axis-briefing@sk.com` | ai |
| `BRIEFING_RECIPIENTS` | `pm@example.co.kr,exec@example.co.kr` | ai |
| `BRIEFING_TIME` | `08:30` | ai (참조용 — 실제 schedule 은 K8s CronJob) |
| `VITE_API_BASE_URL` | `https://axis.skax.internal` | frontend (D12=a 시 빌드타임 / b 시 ConfigMap volumeMount) |

### 6.2 Secret (`axis-secrets`) — 자격증명 (D14=c 면 ESO 가 SSM 에서 sync)

| 키 | 출처 | 사용 워크로드 |
|---|---|---|
| `DATABASE_URL` | Supabase | ai |
| `SPRING_DATASOURCE_URL` | Supabase | backend |
| `SPRING_DATASOURCE_USERNAME` | Supabase | backend |
| `SPRING_DATASOURCE_PASSWORD` | Supabase | backend |
| `QDRANT_API_KEY` | Qdrant Cloud | ai |
| `OPENAI_API_KEY` | OpenAI | ai |
| `NAVER_CLIENT_ID` | Naver Dev | ai |
| `NAVER_CLIENT_SECRET` | Naver Dev | ai |
| `DART_API_KEY` | DART OpenAPI | ai |
| `KIPRIS_API_KEY` | KIPRIS | ai |
| `SARAMIN_API_KEY` | Saramin | ai |
| `SMTP_USER` | SendGrid (또는 Gmail app password) | ai (D8b=a) |
| `SMTP_PASSWORD` | 동일 | ai |
| `JWT_SECRET` | 자체 생성 | backend |
| `CRON_INTERNAL_TOKEN` | 자체 생성 (B7 / D7) | backend (검증) + cron (전송) |

> **현재 코드의 `SLACK_WEBHOOK_URL` 환경변수 (application.yml:37) 는 D9=a 결정 시 제거**. 매니페스트에는 포함 X.

---

## §7 · CronJob 4개 (D6=b 시)

스케줄 · 타임아웃 · 호출 endpoint 정리.

| 이름 | schedule (cron) | endpoint | activeDeadline | 상태 |
|---|---|---|---|---|
| `axis-cron-ingestion-a` | `0 * * * *` | `POST /api/pipeline/trigger?track=A` | 1800s | 활성 |
| `axis-cron-ingestion-b` | `0 2 * * *` | `POST /api/pipeline/trigger?track=B` | 3600s | 활성 (B1, A1 완료 후) |
| `axis-cron-delivery` | `30 8 * * 1-5` | `POST /api/pipeline/delivery` | 600s | 활성 (B8 완료 후) |
| `axis-cron-weak-signal` | `0 9 * * 1` | `POST /api/weak-signal/trigger` | 600s | `suspend: true` (W7+ 활성) |

공통:
- `concurrencyPolicy: Forbid` (이전 Job 안 끝나면 새 Job 미생성)
- `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3`
- 컨테이너: `curlimages/curl:8.5.0`
- header: `Authorization: Bearer ${CRON_INTERNAL_TOKEN}` (B7 검증)
- label: `app.kubernetes.io/component=cron` (NetworkPolicy 매칭)

---

## §8 · 옵저버빌리티

### 8.1 로깅
- 모든 Pod stdout/stderr → CloudWatch Logs (EKS 기본 fluent-bit 데몬셋)
- 그룹: `/aws/eks/axis/{frontend,backend,ai,cron}`
- Retention: 14일 (D16 결정)
- 구조화 로그 권장:
  - backend: Logback JSON encoder
  - ai: `python-json-logger`

### 8.2 메트릭
- v0: CloudWatch Container Insights (CPU/Memory) 만
- v1: Prometheus + Grafana (helm operator)
  - backend: `/actuator/prometheus` 노출 (별도 의존성 추가 필요)
  - ai: `prometheus-fastapi-instrumentator` 추가 후 `/metrics`

### 8.3 알람 (CloudWatch Alarm 기준)
| 알람 | 임계값 | 액션 |
|---|---|---|
| backend CPU > 80% (5분) | warn | 이메일 (운영자 그룹) |
| ai memory > 90% | crit | OOMKilled 임박 |
| ai pod restart > 3회/시간 | crit | 모델 로드 실패 가능성 |
| CronJob 실패 | crit | 즉시 알림 |
| ALB 5xx > 1%/5분 | warn | |

---

## §9 · CI/CD 통합 (현재 → 목표)

### 9.1 현재 CI (변경 없음)
- 4 레포 각각 빌드/테스트 — 그대로 유지

### 9.2 추가할 CD 워크플로우 (각 레포의 main 브랜치 머지 시)

```yaml
# axis-{frontend,backend,ai}/.github/workflows/cd.yml
on: { push: { branches: [main] } }
permissions: { id-token: write, contents: read }

jobs:
  build-and-push:
    steps:
    - uses: actions/checkout@v4
    - uses: aws-actions/configure-aws-credentials@v4
      with: { role-to-assume: arn:aws:iam::ACCOUNT:role/gha-axis-{service}, aws-region: ap-northeast-2 }
    - run: aws ecr get-login-password | docker login --username AWS --password-stdin ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com
    - run: docker build -t axis-{service}:${{ github.sha }} .
    - run: docker tag axis-{service}:${{ github.sha }} ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/axis-{service}:${{ github.sha }}
    - run: docker push ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/axis-{service}:${{ github.sha }}
  deploy:
    needs: build-and-push
    steps:
    # D13=a (kubectl 직접):
    - run: aws eks update-kubeconfig --name axis-cluster
    - run: kubectl set image deployment/axis-{service} {service}=ACCOUNT.dkr.ecr.ap-northeast-2.amazonaws.com/axis-{service}:${{ github.sha }} -n axis
    # D13=b (ArgoCD): axis-gitops 의 kustomization.yaml 의 image tag 갱신 PR 자동 생성
```

### 9.3 axis-infra 의 변경
- `k8s/base/*.yaml` 매니페스트 추가 (I1)
- 매니페스트 변경 PR 시 `kubectl apply --dry-run=client` 검증 워크플로우 추가

---

## §10 · 단계별 마이그레이션 (10 steps)

| 단계 | 분류 | 작업 | Owner | 검증 방법 |
|---|---|---|---|---|
| **0** | 의사결정 | §1 의 D1~D17 답 결정 | PM + Lead | 회의록 |
| **1** | 코드 (axis-ai) | A1 (track 파라미터) | AI Lead | unit test |
| **2** | 코드 (axis-backend) | B1, B2 (track 전달, 4사 호출) | Backend Lead | integration test |
| **3** | 코드 (axis-backend) | B7 (내부 토큰 인증) | Backend Lead | curl 검증 |
| **4** | 인프라 | N1~N6 (EKS · ECR · IAM · Route53 · ACM) | DevOps | `kubectl get nodes` 정상 |
| **5** | 인프라 | N7~N9 (ALB · metrics-server · NetworkPolicy CNI) | DevOps | helm list |
| **6** | 매니페스트 | I1 — k8s/base 작성 + ai Deployment 만 먼저 적용 | Backend Lead | `kubectl exec ai -- curl localhost:8001/health` |
| **7** | 매니페스트 | backend + frontend Deployment 추가, Ingress 활성 | Backend Lead | 브라우저로 SPA 접근 |
| **8** | 매니페스트 | NetworkPolicy 적용 → 외부 ai 접근 차단 검증 | DevOps | 외부 pod 에서 `curl axis-ai:8001` 차단 확인 |
| **9** | 코드 + 매니페스트 | B3 (Spring `@Scheduled` 제거) + CronJob 4개 배포 | Backend Lead | `kubectl get cronjob` |
| **10** | 운영 전환 | docker-compose.prod.yml 폐기, traffic 전환 | PM | 발주처 데모 |

각 단계는 **이전 단계 완료 후** 시작. 단계 간 추정 소요: 0.5 ~ 2일.

---

## §11 · 비용 추정 (월간, AWS Seoul region 기준 — D2=t3.xlarge × 2)

| 항목 | 단가 | 수량 | 월 비용 |
|---|---|---|---|
| EKS 컨트롤 플레인 | $0.10/시간 | 1 | $73 |
| t3.xlarge 노드 | $0.166/시간 | 2 | $242 |
| ALB | $0.0225/시간 + LCU | 1 | ~$30 |
| Route53 호스팅 영역 | $0.50/zone | 1 | $1 |
| ACM 인증서 | 무료 | 1 | $0 |
| ECR storage | $0.10/GB | ~10 GB | $1 |
| CloudWatch Logs | $0.50/GB ingestion | ~5 GB | $3 |
| NAT Gateway (egress) | $0.045/시간 + 데이터 | 1 | ~$45 |
| **합계 (인프라)** | | | **~$395/월** |
| Supabase (외부, 변경 없음) | Pro | 1 | ~$25 |
| Qdrant Cloud (외부, 변경 없음) | 1 GB | 1 | ~$30 |
| OpenAI API (외부, 변경 없음) | gpt-4o | usage | ~$60 (LLM 비용 §성능 목표) |
| **합계 (전체)** | | | **~$510/월** |

> **단일 노드 (k3s) 옵션** (D1=d): t3.large 1대 + ALB 없이 NodePort = ~$70/월. 기능 제약 (HPA 안전성 ↓, 단일 장애점). 9주 발주 프로젝트라면 검토 가치 있음.

---

## §12 · 리스크 · 미해결 이슈

| 리스크 | 영향 | 완화 |
|---|---|---|
| 사내망 huggingface.co 차단 | ai pod 부팅 실패 | D11 결정 후 S3 미러 + InitContainer |
| Supabase pooler 연결 한도 초과 | DB 통신 실패 | HikariCP `maximum-pool-size: 10` 유지, ai 측 `pool_size` 제한 |
| BGE-M3 모델 캐시 손실 (Pod 재시작) | 1~3분 다운타임 | D10=b 로 PVC 전환 시 해결 |
| `@Scheduled` 와 K8s CronJob 동시 활성 | 중복 트리거 → DB 중복 INSERT | B3 코드 변경이 CronJob 배포보다 먼저 |
| Frontend 빌드타임 환경변수 의존 | staging/prod 이미지 분리 필요 | D12=b (런타임 config) 채택 |
| OpenAI / DART / Naver API rate limit | 파이프라인 부분 실패 | agent 별 retry × 3 (이미 구현) |
| CronJob → backend 인증 메커니즘 부재 | 외부에서 trigger 호출 가능 | B7 (내부 토큰 검증) 필수 |
| ALB 비용 / Route53 비용 발주 후 누가 결제? | 운영 중단 위험 | D5 결정 시 비용 분담 명시 |
| ai 단일 replica → 단일 장애점 | API 잠시 중단 | architecture 의 weak signal / search 잠시 fail. Brief retry 1회 |

---

## §13 · 역할 분담 (제안)

| Phase | Owner | 협업 |
|---|---|---|
| §2.1 코드 변경 (axis-backend) | 박지원 | 박진 (테스트) |
| §2.2 코드 변경 (axis-ai) | 김가은 | 박진 |
| §2.3 코드 변경 (axis-frontend) | 안가은 / 최종민 | — |
| §3 인프라 (AWS) | 박지원 (DevOps 임시) | 외부 컨설팅 검토 |
| §4~§7 매니페스트 | 박지원 | 김가은 (ai Deployment 검토) |
| §10 운영 전환 | 김가은 (PM) | 박지원 |

---

## §14 · v0 → v1 → v2 로드맵

| 버전 | 범위 | 시점 |
|---|---|---|
| **v0 (이 문서)** | §10 의 단계 0~10. kubectl 직배포 + 단일 namespace `skala3-finalproj-class3-team13` (SKALA 공유 클러스터 정책 — 별도 namespace 생성 금지) + 수동 secret. | W6 ~ W7 |
| v1 | ArgoCD GitOps + External Secrets + Prometheus/Grafana + staging overlay 분리 + CardSelectorAgent / supervisor 패턴 구현 반영 | W8 |
| v2 | mTLS · 멀티 AZ HPA 튜닝 · 모델 캐시 EFS PVC · DR runbook · WeakSignal 활성 | 발주 후 |

---

## 부록 A · 단일 진실원: Port · Service 이름 · 환경변수 매트릭스

> 매니페스트 작성 시 이 표가 **유일한 정답**. 어디든 다르면 이 표를 따른다.

### A.1 Port 통일

| 서비스 | 컨테이너 포트 | K8s Service port | targetPort | Ingress 노출 |
|---|---|---|---|---|
| axis-frontend | 3000 | 3000 | 3000 | `/` |
| axis-backend | 8080 | 8080 | 8080 | `/api`, `/swagger-ui`, `/api-docs` |
| axis-ai | 8001 | 8001 | 8001 | — (NetworkPolicy 차단) |
| (외부) Supabase | — | — | — | EKS 밖 |
| (외부) Qdrant Cloud | 6333 | — | — | EKS 밖 |

### A.2 Service / Deployment 이름

| 리소스 | 이름 | 라벨 (selector) |
|---|---|---|
| Namespace | `axis` | — |
| Deployment / Service / SA (frontend) | `axis-frontend` | `app: axis-frontend` |
| Deployment / Service / SA (backend) | `axis-backend` | `app: axis-backend` |
| Deployment / Service / SA (ai) | `axis-ai` | `app: axis-ai` |
| ConfigMap | `axis-config` | — |
| Secret | `axis-secrets` | — |
| Ingress | `axis` | — |
| CronJob | `axis-cron-{ingestion-a, ingestion-b, delivery, weak-signal}` | `app.kubernetes.io/component: cron` |

### A.3 Healthcheck path

| 서비스 | Liveness/Readiness/Startup | 비고 |
|---|---|---|
| axis-frontend | `GET /` :3000 | nginx 가 `/index.html` 반환 |
| axis-backend | `GET /health` :8080 | [`HealthController.java:11`](../../axis-backend/src/main/java/com/skala/axis/controller/HealthController.java#L11) — Actuator 아님 |
| axis-ai | `GET /health` :8001 | [`router.py:42`](../../axis-ai/src/api/router.py#L42) |

### A.4 환경변수 매트릭스

| 변수 | frontend | backend | ai | 출처 | 비고 |
|---|---|---|---|---|---|
| `VITE_API_BASE_URL` | ✓ | | | ConfigMap | D12 결정에 따라 빌드/런타임 |
| `SPRING_PROFILES_ACTIVE` | | ✓ | | ConfigMap | `prod` |
| `AI_SERVER_URL` | | ✓ | | ConfigMap | `http://axis-ai:8001` |
| `SPRING_DATASOURCE_URL` | | ✓ | | Secret | Supabase pooler |
| `SPRING_DATASOURCE_USERNAME` | | ✓ | | Secret | |
| `SPRING_DATASOURCE_PASSWORD` | | ✓ | | Secret | |
| `DATABASE_URL` | | | ✓ | Secret | Python psycopg2 형식 |
| `QDRANT_HOST` | | | ✓ | ConfigMap | Cloud URL |
| `QDRANT_PORT` | | | ✓ | ConfigMap | 6333 |
| `QDRANT_API_KEY` | | | ✓ | Secret | |
| `OPENAI_API_KEY` | | | ✓ | Secret | |
| `NAVER_CLIENT_ID` | | | ✓ | Secret | |
| `NAVER_CLIENT_SECRET` | | | ✓ | Secret | |
| `DART_API_KEY` | | | ✓ | Secret | |
| `KIPRIS_API_KEY` | | | ✓ | Secret | |
| `SARAMIN_API_KEY` | | | ✓ | Secret | |
| `SMTP_HOST` | | | ✓ | ConfigMap | D8b=a (ai 가 메일 발송) |
| `SMTP_PORT` | | | ✓ | ConfigMap | `587` |
| `SMTP_USER` | | | ✓ | Secret | |
| `SMTP_PASSWORD` | | | ✓ | Secret | |
| `SMTP_FROM` | | | ✓ | ConfigMap | |
| `BRIEFING_RECIPIENTS` | | | ✓ | ConfigMap | 콤마 구분 |
| `BRIEFING_TIME` | | | ✓ | ConfigMap | `08:30` (참조) |
| `JWT_SECRET` | | ✓ | | Secret | |
| `CRON_INTERNAL_TOKEN` | | ✓ (검증) | | Secret | CronJob 도 같은 값 (전송) |
| `JAVA_TOOL_OPTIONS` | | ✓ | | Deployment env (literal) | `-XX:MaxRAMPercentage=75 -XX:+UseG1GC` |

### A.5 `.env.example` ↔ K8s 매니페스트 매핑 (현재 불일치 정리)

`.env.example` 의 `SMTP_*` 와 backend [`application.yml`](../../axis-backend/src/main/resources/application.yml) 에 **mail 설정 자체가 없음** (B4). 결정 (D8b=a) 에 따라:
- 메일 발송은 axis-ai 의 EmailAgent 가 담당 (architecture/04 §4.5 와 일치)
- backend 의 `BriefingService` 와 `application.yml` 의 mail 설정은 작성 불필요 (B4 무산)
- `SMTP_*` 환경변수는 ai pod 만 수신 (Secret 도 ai SA 만 접근)
- backend 는 `/api/pipeline/delivery` 트리거 endpoint 만 신설 (B8) — 실제 SMTP 안 건드림

---

## 부록 B · 미사용 / 폐기 예정 항목

K8s 전환 시 정리할 잔재:

| 항목 | 위치 | 처리 |
|---|---|---|
| `SLACK_WEBHOOK_URL` env var | [`application.yml:36-38`](../../axis-backend/src/main/resources/application.yml#L36-L38) | 제거 (D9=a) |
| Frontend nginx 의 `/api → http://backend:8080` proxy | [`nginx.conf:11-15`](../../axis-frontend/nginx.conf#L11-L15) | K8s 에서는 Ingress 가 라우팅. 제거 또는 Service 이름 변경 (`http://axis-backend:8080`) |
| `docker-compose.prod.yml` | [axis-infra/docker-compose.prod.yml](../docker-compose.prod.yml) | K8s 전환 후 보관용으로 유지, 운영에서는 사용 X |
| Spring `@Scheduled` 메서드 | [`SchedulerConfig.java`](../../axis-backend/src/main/java/com/skala/axis/config/SchedulerConfig.java) | D6=b 시 제거 (B3) |
| Hardcoded `["samsung_sds", "lg_cns"]` | [`PipelineController.java:23`](../../axis-backend/src/main/java/com/skala/axis/controller/PipelineController.java#L23) | 4사 전체로 변경 (B2) |

---

> **최종 확인**: 본 문서의 모든 port · 이름 · 환경변수는 부록 A 와 일치해야 한다. 매니페스트 작성 중 다른 값 발견 시 부록 A 갱신 후 진행.
