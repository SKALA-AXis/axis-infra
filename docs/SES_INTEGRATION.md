# AWS SES 통합 spec — 일일 브리핑 이메일 발송

> 작성: 2026-05-12
> 가이드: 교수님 (skala-ai.com 도메인 SES verify 완료, IRSA `ses-mailer-sa` 셋업)
> 영향: axis-backend (구현) + axis-ai (delivery endpoint 응답 변경)

## 결정 사항

| 항목 | 결정 | 이유 |
|---|---|---|
| **API 방식** | SES V2 SDK (HTTP API) | SMTP 폐기 — 교수님 가이드 + IRSA 친화 |
| **인증** | IRSA — `ses-mailer-sa` 의 IAM role | SMTP credentials 불필요 |
| **Sender** | `noreply@skala-ai.com` | 매니저 verify 완료 도메인 |
| **Region** | `ap-northeast-2` | cluster 리전 |
| **발송 주체** | **axis-backend** (Spring Boot) | axis-ai 는 본문 데이터만 생성 |
| **스케줄링** | **옵션 B** — 기존 CronJob (`axis-cron-delivery`) 유지 | cluster cron + backend HA 이중 보장 |
| **수신자** | `BRIEFING_RECIPIENTS` (axis-config) 또는 DB | team13 6명 (현재) → SK AX 사업전략팀 (운영) |

옵션 A (Spring `@Scheduled`) 도 가능 — CronJob 제거 + backend 단일 발송. 결정은 backend 팀.

## 흐름

```
axis-cron-delivery CronJob (월-금 08:30 KST)
    │ POST + CRON_INTERNAL_TOKEN
    ↓
axis-backend:8080/api/pipeline/delivery
    │ 1) axis-ai 호출 (본문 데이터 생성)
    │    └─ POST axis-ai:8001/pipeline/delivery
    │       → axis-ai 가 동향 카드 + evidence chain 모아 HTML/텍스트 반환
    │ 2) SesMailService.sendBriefing(recipients, subject, html, text)
    │    └─ SES V2 SDK → AWS SES API (IRSA 인증)
    ↓
6명 inbox 도착
```

## axis-infra 적용 (완료)

### 1. axis-backend Deployment SA 변경

[`k8s/overlays/skala/patches/deployment-backend.yaml`](../k8s/overlays/skala/patches/deployment-backend.yaml):

```yaml
spec:
  template:
    spec:
      serviceAccountName: ses-mailer-sa   # axis-backend-sa → ses-mailer-sa
```

`ses-mailer-sa` 의 IAM role annotation:
```
eks.amazonaws.com/role-arn: arn:aws:iam::881490135253:role/eksctl-skala-2025-addon-iamserviceaccount-ska-Role1-Y4VEapoOEaKI
```

### 2. axis-config 갱신

[`k8s/overlays/skala/patches/configmap-env.yaml`](../k8s/overlays/skala/patches/configmap-env.yaml):

```yaml
AWS_REGION: "ap-northeast-2"
MAIL_FROM: "noreply@skala-ai.com"
BRIEFING_RECIPIENTS: "REPLACE_RECIPIENT_EMAILS"   # 발표 직전 team13 6명 박기
BRIEFING_TIME: "08:30"
```

SMTP_HOST / SMTP_PORT / SMTP_FROM 환경변수는 제거 (SES SDK 사용 시 불필요).

### 3. ArgoCD sync 후 적용

push 후 ArgoCD 가 자동 sync → backend pod 가 새 SA + env 로 rollout. backend 코드 변경 (아래) 까지 끝나면 실 발송 가능.

## axis-backend 작업 (박지원)

### 1. build.gradle 의존성 추가

```gradle
dependencies {
    implementation 'software.amazon.awssdk:sesv2'
}
```

### 2. SesMailService 작성 (`src/main/java/com/skala/axis/service/SesMailService.java`)

```java
package com.skala.axis.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sesv2.SesV2Client;
import software.amazon.awssdk.services.sesv2.model.*;

import java.util.List;

@Service
public class SesMailService {

    private final SesV2Client sesClient;
    private final String fromEmail;

    public SesMailService(
            @Value("${aws.region:ap-northeast-2}") String region,
            @Value("${mail.from}") String fromEmail
    ) {
        this.sesClient = SesV2Client.builder()
                .region(Region.of(region))
                .build();   // IRSA 가 credentials 자동 주입
        this.fromEmail = fromEmail;
    }

    public void sendBriefing(List<String> recipients, String subject, String html, String text) {
        Destination destination = Destination.builder()
                .toAddresses(recipients)
                .build();

        Body body = Body.builder()
                .html(Content.builder().data(html).charset("UTF-8").build())
                .text(Content.builder().data(text).charset("UTF-8").build())
                .build();

        Message message = Message.builder()
                .subject(Content.builder().data(subject).charset("UTF-8").build())
                .body(body)
                .build();

        SendEmailRequest request = SendEmailRequest.builder()
                .fromEmailAddress(fromEmail)
                .destination(destination)
                .content(EmailContent.builder().simple(message).build())
                .build();

        sesClient.sendEmail(request);
    }
}
```

### 3. application.yaml 갱신

```yaml
aws:
  region: ${AWS_REGION:ap-northeast-2}

mail:
  from: ${MAIL_FROM:noreply@skala-ai.com}

briefing:
  recipients: ${BRIEFING_RECIPIENTS:}   # comma-separated, axis-config 에서 주입
```

### 4. /api/pipeline/delivery endpoint 갱신

```java
@PostMapping("/api/pipeline/delivery")
public ResponseEntity<String> dailyBriefing() {
    // 1) axis-ai 호출 — 본문 데이터 받기
    BriefingContent content = aiClient.buildBriefing();
    // 응답: { subject, html, text, recipients (optional) }

    // 2) 수신자 결정 (axis-config 의 BRIEFING_RECIPIENTS 또는 DB)
    List<String> recipients = List.of(briefingRecipients.split(","));

    // 3) SES 발송
    sesMailService.sendBriefing(recipients, content.subject(), content.html(), content.text());

    return ResponseEntity.ok("sent");
}
```

### 5. (옵션 A — 권장) Spring @Scheduled 추가

CronJob 폐기 시:

```java
@Component
public class BriefingScheduler {

    @Autowired SesMailService mail;
    @Autowired AiClient ai;

    @Scheduled(cron = "0 30 8 * * MON-FRI", zone = "Asia/Seoul")
    public void dailyBriefing() {
        var content = ai.buildBriefing();
        mail.sendBriefing(content.recipients(), content.subject(), content.html(), content.text());
    }
}
```

`@EnableScheduling` 도 main 클래스에 추가. 옵션 A 채택 시 [`k8s/base/cronjob-delivery.yaml`](../k8s/base/cronjob-delivery.yaml) 제거 가능.

## axis-ai 작업 (박진/심유정)

### 1. EmailAgent 폐기

기존 `axis-ai/src/agents/email_agent.py` 의 `smtplib` 발송 로직 제거.

### 2. `/pipeline/delivery` 응답 변경

```python
# axis-ai/src/api/router.py
@router.post("/pipeline/delivery")
async def pipeline_delivery() -> BriefingContent:
    # 1) 동향 카드 + evidence chain 조회 (기존 로직)
    cards = await load_today_cards()

    # 2) 이메일 본문 구성 (기존 EmailAgent 의 본문 생성 로직만 유지)
    html = render_briefing_html(cards)
    text = render_briefing_text(cards)

    return BriefingContent(
        subject=f"[AXIS] 오늘의 동향 브리핑 — {today_str()}",
        html=html,
        text=text,
        recipients=load_recipients(),  # 옵션 — backend 가 axis-config 에서 받을 수도
    )
```

### 3. requirements 정리

```python
# pyproject.toml 에서 smtplib 외 SMTP 관련 의존성 제거 (사용 X)
```

## ArgoCD notifications (별도 plan — P8)

ArgoCD notifications-controller 는 *Pod + SMTP* 라 IRSA + SES SDK 직접 사용 불가. SES 의 *SMTP interface* 활용:

```
host: email-smtp.ap-northeast-2.amazonaws.com
port: 587 또는 465
username: <IAM 사용자의 SES SMTP credentials (별도 IAM user + SMTP credential 발급)>
password: <SES SMTP password>
from: axis-cicd@skala-ai.com   # 또는 noreply@skala-ai.com 재사용
```

매니저에 SES SMTP credentials 별도 요청 필요. P8 영역.

또는 **ArgoCD webhook → axis-backend 의 /api/internal/notify endpoint → backend 가 SES SDK 발송** — overkill 이지만 가능.

## 검증

### 1. backend 배포 후

```bash
# pod 의 SA 확인
kubectl get pod -l app=axis-backend -n skala3-finalproj-class3-team13 \
  -o jsonpath='{.items[0].spec.serviceAccountName}'
# 기대: ses-mailer-sa

# env 확인
kubectl exec -n skala3-finalproj-class3-team13 deploy/axis-backend -- env | grep -E "AWS_REGION|MAIL_FROM"
# 기대: AWS_REGION=ap-northeast-2, MAIL_FROM=noreply@skala-ai.com
```

### 2. 발송 테스트

backend 에 test endpoint 또는 즉시 발동:
```bash
kubectl exec -n skala3-finalproj-class3-team13 deploy/axis-backend -- \
  curl -X POST http://localhost:8080/api/pipeline/delivery \
  -H "Authorization: Bearer $CRON_INTERNAL_TOKEN"
# 6명 inbox 확인
```

### 3. CronJob 발동 검증 (옵션 B 유지 시)

```bash
# 다음 평일 08:30 KST 자동 발동
kubectl get cronjob axis-cron-delivery -n skala3-finalproj-class3-team13

# 즉시 수동 발동 (테스트용)
kubectl create job manual-briefing-test --from=cronjob/axis-cron-delivery \
  -n skala3-finalproj-class3-team13
```

## 운영 주의

- **SES sandbox 모드 여부 확인** — 매니저가 production access 신청했는지. sandbox 면 수신자 verify 필요 (200/day 제한).
- **BRIEFING_RECIPIENTS placeholder** — 발표 직전 team13 6명 이메일 박기 (axis-config patch).
- **bounce / complaint 처리** — SES 의 SNS topic 통한 알림 (P8 운영 강화).
- **CronJob 제거 시 (옵션 A)** — `k8s/base/cronjob-delivery.yaml` 삭제 + base kustomization.yaml 에서 제외 + axis-cron-sa 도 정리 검토.
