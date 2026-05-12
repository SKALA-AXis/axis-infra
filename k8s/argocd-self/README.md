# 자체 ArgoCD — 비상용 spec (P8)

> **상태**: 공용 `skala-argocd` 정착 (Tekton CRD cleanup 후 사용 가능). 자체 ArgoCD 는 폐기.
> 보존 이유: 공용 ArgoCD 가 죽거나 매니저 응급 대응 불가 시 **비상 부팅 spec**.

## 일일 브리핑 / CI/CD 알림은 어디서?

일일 브리핑 (axis-cron-delivery → backend) = **backend 의 SesMailService (IRSA + SES V2 SDK)** 통합. ArgoCD notifications 와 무관. [docs/SES_INTEGRATION.md](../../docs/SES_INTEGRATION.md) 참조.

ArgoCD CI/CD 알림 (sync 성공/실패) = P8 영역. 공용 `argocd-notifications-cm` 에 매니저가 SES SMTP interface 또는 webhook → backend 패턴으로 박을 예정.

## 비상 부팅 시 (공용 ArgoCD 죽음)

```bash
helm install axis-argocd argo/argo-cd \
  -n skala3-finalproj-class3-team13 \
  -f k8s/argocd-self/values.yaml \
  --version 9.5.13
```

이후:
1. [../argocd/axis-application.yaml](../argocd/axis-application.yaml) 의 `metadata.namespace` 를 `skala-argocd` → `skala3-finalproj-class3-team13` 로 변경 (sed 또는 Edit)
2. `kubectl apply -f k8s/argocd/axis-application.yaml`
3. `kubectl apply -f k8s/argocd/repo-secret.yaml` (PAT 채워서)

## 주의 — Tekton CRD 재발

비상 부팅 시 cluster 에 Tekton CRD 가 다시 좀비 상태로 들어왔으면 cluster cache 빌드 fail. 그 경우 `values.yaml` 의 `configs.cm.resource.exclusions` 가 Tekton 회피.

## ResourceQuota

자체 ArgoCD 추가 시 services +4, pods +5. 현재 6/10 + 4 svc = **정확히 10**. ApplicationSet svc 가 추가되면 한도 초과. 비상 부팅 직전 매니저에 services quota 증액 요청 권장.

## 파일

| 파일 | 역할 | git 커밋 |
|---|---|---|
| `values.yaml` | helm chart values (namespace-scoped minimal, notifications 비활성) | ✅ |
| `README.md` | 이 파일 | ✅ |
