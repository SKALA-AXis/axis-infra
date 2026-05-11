# 자체 ArgoCD 시도 — 참조 spec (P8)

> **상태**: v6 의 자체 ArgoCD pivot 시도 시 사용한 helm chart values. v7 에서 폐기 (Tekton 좀비 cleanup 후 공용 `skala-argocd` 사용 가능).
> 보존 이유: notifications spec (SMTP + 3 triggers + 한국어 templates + 6명 subscriptions) 이 **P8 매니저 작업 시 참조 자료**.

## 왜 보존?

발표 후 P8 단계에서 매니저가 공용 `argocd-notifications-cm` 에 우리 알림 설정 추가할 때:

- [values.yaml](./values.yaml) 의 `notifications.notifiers.service.email.smtp` → 그대로 cm 의 `service.email.smtp` 키
- `notifications.subscriptions` → cm 의 `subscriptions` 키
- `notifications.templates.*` → cm 의 `template.*` 키
- `notifications.triggers.*` → cm 의 `trigger.*` 키

즉 **chart values → cm 키 1:1 대응**. 매니저가 5분 안에 공용 cm 갱신 가능.

## P8 SMTP 도메인 verify 후 적용 절차

```yaml
# values.yaml 의 host/from/username 만 ESP 별로 교체:

# Brevo
host: smtp-relay.brevo.com
port: 465
from: axis-cicd@<verified-domain>
username: <Brevo SMTP login>

# Resend
host: smtp.resend.com
port: 465
from: axis-cicd@<verified-domain>
username: resend

# AWS SES (운영 정공)
host: email-smtp.ap-northeast-2.amazonaws.com
port: 465
from: axis-cicd@<verified-domain>
username: <SES SMTP credential username>
```

ESP 별 API key/password 는 `argocd-notifications-secret` 의 `email-password` 키에 박힘 (cluster 의 secret, gitignored).

## 자체 ArgoCD 재설치 시 (비상 대응)

공용 `skala-argocd` 가 죽거나 매니저가 응급 대응 못 할 때만:

```bash
helm install axis-argocd argo/argo-cd \
  -n skala3-finalproj-class3-team13 \
  -f k8s/argocd-self/values.yaml \
  --version 9.5.13
```

이후 [../argocd/axis-application.yaml](../argocd/axis-application.yaml) 의 `metadata.namespace` 를 `skala-argocd` → `skala3-finalproj-class3-team13` 로 변경 후 apply.

⚠️ ResourceQuota services 한도 (10) 안에 들어와야 — 현재 6/10 이므로 자체 ArgoCD 4 svc 추가 시 정확히 10. 단 ApplicationSet controller (chart v9.5+ 강제 포함) 가 svc 추가 → 잠재 위험. P8 에서 controller flag tuning 권장.

⚠️ admin password reset 절차 등은 [../../docs/HANDOVER.md §3 v1 archive](../../docs/HANDOVER.md) 참조 (v2 에서 매니저 영역으로 이전됨).

## 파일

| 파일 | 역할 | git 커밋 |
|---|---|---|
| `values.yaml` | helm chart values (namespace-scoped minimal install + notifications spec) | ✅ |
| `README.md` | 이 파일 | ✅ |
