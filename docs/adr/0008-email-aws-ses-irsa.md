# 0008. 이메일 발송 — AWS SES V2 SDK + IRSA

- **날짜**: 2026-05-12
- **상태**: Accepted
- **선행 결정**: v3 (Slack Webhook → 이메일), ADR-0007 (공용 ArgoCD)

## 배경

AXIS 의 사용자 접점은 **매일 아침 8:30 SK AX 사업전략팀에 동향 브리핑 이메일**. Slack 폐기 후 이메일이 *유일한* 알림 채널. 안정적 deliverability + 인계 가능한 sender + 보안성 필요.

## 시도 한 path

### Path 1 — SendGrid SMTP
- 가입 거부 (anti-fraud 정책, 이유 미공개)
- 폐기

### Path 2 — Resend SMTP (onboarding sender)
- 가입 + API key 발급 OK
- 그러나 `onboarding@resend.dev` sender = *verified email 만 deliver* sandbox 제약
- 6명 수신 0건 (Resend dashboard 0건, silent drop)
- domain verify 필요 (DNS TXT 추가) — `skala-ai.com` 의 DNS 권한 X
- 폐기

### Path 3 — Brevo (Single Sender Verification)
- 가입 성공 (SendGrid 보다 anti-abuse 관대)
- sender = 본인 Gmail (verify 가능) 단 *본인 sender 노출* — 인계 부담
- 미진행 (Path 4 가이드 받음)

### Path 4 — AWS SES + IRSA (**결정**)
- 매니저가 `noreply@skala-ai.com` SES verified domain 셋업
- IAM Service Account `ses-mailer-sa` 발급 (IRSA — IAM Roles for Service Accounts)
- Pod 가 SA 통해 IAM role assume → SES API 호출 (SMTP credentials 불필요)
- Spring Boot SDK = `software.amazon.awssdk:sesv2`

## 결정

**axis-backend 의 `SesMailService`** 가 AWS SES V2 SDK 통합 발송. axis-ai 는 본문 데이터만 반환.

### Architecture

```
axis-cron-delivery CronJob (월-금 08:30 KST)
  → POST axis-backend:8080/api/pipeline/delivery
    → POST axis-ai:8001/pipeline/delivery (본문 데이터 요청)
      → axis-ai: 동향 카드 + evidence chain + HTML/text 본문 → 반환
    → axis-backend 의 SesMailService:
        - SesV2Client.builder().region(Region.AP_NORTHEAST_2).build()
          (IRSA credentials 자동 주입)
        - SendEmailRequest with FromEmailAddress="noreply@skala-ai.com"
        - sesClient.sendEmail(request)
  → 6명 수신자 (team13 / SK AX 사업전략팀) inbox
```

### 책임 분리

| 컴포넌트 | 책임 |
|---|---|
| **axis-ai** | 동향 카드 조회 + evidence chain + HTML/text 본문 빌더 (smtplib 발송 폐기) |
| **axis-backend** | SES SDK 발송 통합 (`SesMailService`), 수신자 관리, 스케줄링 |
| **axis-infra** | k8s 매니페스트 (ses-mailer-sa, AWS_REGION, MAIL_FROM), spec 문서 |
| **매니저** | SES domain verify, IAM role, production access |

### 검증

cluster 안의 임시 boto3 pod (`ses-mailer-sa` SA) 로 sesv2.send_email 호출 → MessageId 발급 성공.
backend SES 코드는 박지원 작업 대기.

### 보안 이점 (vs SMTP)

- IRSA: SMTP credentials secret 자체 불필요 (OIDC token 자동 만료/회전)
- IAM 권한 최소화: `ses:SendEmail` 만 부여 (read API 거부 검증됨)
- AWS CloudWatch + SNS 통합: bounce/complaint 자동 알림 (P8 운영 강화)

## 폐기된 옵션

- **SMTP (Resend / Brevo / SendGrid / SES SMTP interface)** — IRSA 의 이점 (credential rotation) 활용 X
- **axis-ai 의 boto3 직접 발송** — axis-ai-sa 에 별도 IRSA 셋업 필요, 발송 주체 분산
- **ArgoCD notifications native SES** — ArgoCD notifications-engine 이 SMTP only, HTTP API 미지원. P8 에서 SES SMTP interface 또는 webhook → backend 우회 검토.

## 위험과 완화

- **SES sandbox 모드** — production access 신청 시 24-48h 검토. 매니저 영역. 검증: 임의 unverified address 에 발송 시도 → MessageId 발급 시 production 확정.
- **Gmail spam filter** — sender domain reputation 시간 필요. DMARC strict 부재로 silent drop 가능. 매니저가 SES dashboard 의 Bounce/Complaint 카운트 확인.
- **`MAIL_FROM` env injection** — `axis-config` (ConfigMap) 의 `MAIL_FROM=noreply@skala-ai.com` 이 backend Pod 에 envFrom 으로 주입. Spring 의 `${MAIL_FROM}` placeholder 가 그 값 사용.

## 참조

- [docs/SES_INTEGRATION.md](../SES_INTEGRATION.md) — backend / ai 팀 spec (코드 sample 포함)
- [k8s/overlays/skala/patches/deployment-backend.yaml](../../k8s/overlays/skala/patches/deployment-backend.yaml) — SA = ses-mailer-sa
- [k8s/overlays/skala/patches/configmap-env.yaml](../../k8s/overlays/skala/patches/configmap-env.yaml) — AWS_REGION + MAIL_FROM
