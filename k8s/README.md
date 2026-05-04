# AXIS Kubernetes 매니페스트

> 실행 X · **target architecture 매니페스트만 미리 작성**.
> docker-compose 로 운영하다가 클라우드 (EKS) 로 옮길 때 본 디렉토리의 매니페스트를 적용한다.
>
> 설계 근거: [`docs/INFRASTRUCTURE_PLAN.md`](../docs/INFRASTRUCTURE_PLAN.md)
> 데이터 계약: [`docs/DB_METADATA.md`](../docs/DB_METADATA.md) · [`docs/IMAGE_PIPELINE_CONTRACT.md`](../docs/IMAGE_PIPELINE_CONTRACT.md)

---

## 디렉토리 구조

```
k8s/
└── base/
    ├── kustomization.yaml         # 모든 리소스 단일 인덱스
    ├── namespace.yaml             # axis ns + ResourceQuota + LimitRange
    ├── serviceaccounts.yaml       # 워크로드별 SA × 4
    ├── configmap.yaml             # 비밀 X 설정 (axis-config)
    ├── secret.example.yaml        # 자격증명 템플릿 — secret.yaml 로 복사 후 채움
    ├── axis-images-pvc.yaml       # 카드 뉴스 이미지 RWX 볼륨
    ├── frontend-{deployment,service}.yaml
    ├── hpa-frontend.yaml
    ├── backend-{deployment,service}.yaml
    ├── hpa-backend.yaml
    ├── ai-{deployment,service}.yaml         # ai 는 HPA 없음 (콜드스타트 1~3분)
    ├── ingress.yaml                # AWS ALB Ingress (internal)
    ├── networkpolicy.yaml          # default-deny + 명시적 allow
    └── cronjob-{ingestion-a,ingestion-b,delivery,weak-signal}.yaml
```

---

## Placeholder 일람 (apply 전 모두 치환)

| Placeholder | 의미 | 출처 |
|---|---|---|
| `REPLACE_ACCOUNT` | AWS 계정 ID (12자리) | AWS 콘솔 |
| `REPLACE_TAG` | 컨테이너 이미지 태그 (예: git SHA) | CI/CD pipeline |
| `REPLACE_QDRANT_CLUSTER_ID` | Qdrant Cloud cluster URL | Qdrant Cloud 콘솔 |
| `REPLACE_CERT_UUID` | ACM 인증서 UUID | AWS ACM |
| `REPLACE_RWX_STORAGE_CLASS` | RWX StorageClass 이름 (예: efs-sc) | CSI driver 설치 |
| `REPLACE_*` (secret.example.yaml) | 자격증명 실값 | 1Password / SSM |

검증 명령:
```bash
grep -rn "REPLACE_" k8s/base/ | grep -v "secret.example.yaml" | grep -v "# "
# (출력이 0 이어야 apply 가능 — secret.example.yaml 의 REPLACE_ 는 secret.yaml 로 복사 후 치환)
```

---

## 선결 조건 (클러스터 측)

| # | 항목 | 설치 명령 |
|---|---|---|
| 1 | EKS 클러스터 + 노드 그룹 | `eksctl create cluster ...` |
| 2 | AWS Load Balancer Controller | `helm install aws-load-balancer-controller ...` |
| 3 | metrics-server (HPA 동작) | `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/...` |
| 4 | NetworkPolicy 지원 CNI | EKS VPC CNI 옵션 활성 또는 Calico/Cilium 설치 |
| 5 | EFS CSI Driver (RWX PVC) | `helm install aws-efs-csi-driver ...` + EFS 파일 시스템 + access point |
| 6 | (운영) External Secrets Operator | `helm install external-secrets ...` (D14=c) |
| 7 | (운영) ArgoCD | `helm install argo-cd ...` (D13=b) |

---

## 적용 순서

```bash
# 1) 자격증명 채우기 (1회) — base 는 EKS 가정이라 별도 secret.yaml 작성
cp k8s/base/secret.example.yaml k8s/base/secret.yaml
$EDITOR k8s/base/secret.yaml          # REPLACE_* 모두 실값으로
# secret.yaml 은 .gitignore 처리됨 (확인: git check-ignore -v k8s/base/secret.yaml)

# 로컬 모드 (overlays/local) 는 별도 흐름 — .env 가 SSoT 이고 'make secret' 자동 생성.
# 자세히는 overlays/local/README.md 참조.

# 2) 매니페스트 안 placeholder 치환 (REPLACE_ACCOUNT 등)
#    실제로는 overlay 또는 envsubst 로 자동화 권장
sed -i.bak "s/REPLACE_ACCOUNT/123456789012/g" k8s/base/*.yaml
# ... 나머지 REPLACE_* 도 동일

# 3) dry-run 검증 (실제 apply 전)
kubectl apply -k k8s/base --dry-run=client
kubectl kustomize k8s/base | kubectl apply --dry-run=server -f -

# 4) 실제 apply (Secret 은 base 의 kustomization 에 미포함 — 별도 apply)
kubectl apply -f k8s/base/secret.yaml
kubectl apply -k k8s/base

# 5) 상태 확인
kubectl -n axis get all
kubectl -n axis get pvc
kubectl -n axis get networkpolicy,cronjob

# 6) 헬스체크 (Ingress 가 받기 시작)
curl -fsSL https://axis.skax.internal/health
```

> **왜 Secret 을 별도 apply 하나**: overlay (e.g., `overlays/local`) 가 환경별로 다른 Secret 을 추가할 수 있도록 base 에서는 Secret 을 kustomization resources 에 포함하지 않는다. cloud 배포 시엔 secret.yaml 을 직접 apply, local 시엔 `overlays/local/secret.local.yaml` 가 자동 포함.

---

## 트러블슈팅

| 증상 | 원인 후보 | 확인 방법 |
|---|---|---|
| `axis-ai` Pod 가 5분 후 CrashLoopBackOff | 모델 다운로드 실패 (huggingface.co 차단) | `kubectl logs -n axis axis-ai-...` · D11 정책 확인 |
| `axis-images` PVC 가 Pending | RWX StorageClass 없음 / EFS CSI 미설치 | `kubectl describe pvc axis-images -n axis` |
| Ingress Address 가 비어있음 | ALB Controller 미설치 / IRSA 권한 부족 | `kubectl logs -n kube-system aws-load-balancer-controller-...` |
| `axis-ai` Pod 에서 외부에서 접근 가능 | NetworkPolicy CNI 미활성 | EKS 콘솔의 VPC CNI 설정 또는 `kubectl get pods -n kube-system \| grep -i policy` |
| HPA 가 `<unknown>` 으로 표시 | metrics-server 미설치 | `kubectl top pod -n axis` |
| CronJob 이 트리거 안 됨 | `timeZone` 미지원 (k8s < 1.27) | `kubectl version` 확인 후 timeZone 제거 |
| backend → ai 호출 실패 | NetworkPolicy 매칭 라벨 불일치 | `kubectl describe networkpolicy allow-ai-from-backend -n axis` |

---

## v1 후속 작업 (현재 base 에 없음)

- `overlays/staging/` · `overlays/prod/` — 환경별 image tag · replicas · resource override
- ExternalSecret CRD — secret.yaml 대체
- ServiceMonitor — Prometheus 메트릭 수집
- Application (ArgoCD CRD) — GitOps 자동 sync
- PodDisruptionBudget — 노드 drain 시 가용성 보장
- topologySpreadConstraints — 2 AZ 분산

---

## 검증 체크리스트 (커밋 전)

- [ ] `kubectl apply -k k8s/base --dry-run=client` 통과
- [ ] `kubectl kustomize k8s/base | kubeval -` 또는 `kubeconform` 통과
- [ ] 모든 `REPLACE_*` placeholder 가 치환됐는지 grep 으로 0 건 확인
- [ ] secret.yaml 이 `.gitignore` 에 등록됐는지 확인
- [ ] 라벨 selector 일치: Deployment.spec.selector ↔ Service.spec.selector ↔ NetworkPolicy.spec.podSelector
- [ ] port 일관: frontend 3000 / backend 8080 / ai 8001
- [ ] envFrom 의 ConfigMap/Secret 이름이 axis-config / axis-secrets 인지
- [ ] ServiceAccount 이름이 모든 워크로드에서 매칭
