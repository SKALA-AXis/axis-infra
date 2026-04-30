# AXIS 시스템 아키텍처

> Figma 작업용 단일 레퍼런스. **이 문서가 SoT** — 인프라 변경 시 함께 갱신.
> 작성: 2026-04-30 · 적용 범위: axis-infra / axis-backend / axis-ai / axis-frontend
> 표현 방식: 한 장 통합 다이어그램 (실선=현재 구현 / 점선·점박스=W6+ K8s·CI/CD 계획)
>
> **현재(Now) vs 계획(Planned) 구분**
>
> - 실선 박스·실선 화살표 = 현재 docker-compose 로 동작 중
> - 점선 보더 박스 / 점선 화살표 = K8s + Jenkins + ArgoCD 도입 후 (W6+)

---

## 1. 한 장 시스템 아키텍처

```mermaid
flowchart TB
    %% ── 외부 사용자 / 개발자 ──────────────────────────────
    User([👤 전략기획 담당자])
    Dev([👨‍💻 Developer])
    Mail([📧 이메일 수신함<br/>전략기획팀])

    %% ── 외부 데이터 / SaaS ───────────────────────────────
    subgraph SRC["🌐 크롤링 소스 (Track A · Track B)"]
        direction LR
        Naver[Naver News API]
        DART[DART OpenAPI]
        KIPRIS[KIPRIS]
        RSS[RSS · Google News]
        Saramin[Saramin]
        PW[Playwright<br/>공식 뉴스룸]
    end

    subgraph SAAS["☁️ Managed SaaS"]
        direction LR
        SB[(🟢 Supabase<br/>PostgreSQL Pooler<br/>aws-1-ap-northeast-2:6543)]
        QC[(🔴 Qdrant Cloud<br/>axis_main 3개월·axis_history 12개월)]
        OA[🤖 OpenAI GPT-4o]
        S3[(📦 S3<br/>IR PDF · 모델 아티팩트)]
    end

    subgraph GH_GROUP["🐙 GitHub Repos"]
        direction TB
        GH[axis-infra · axis-backend<br/>axis-ai · axis-frontend]
        GHOPS[axis-gitops<br/>kustomize / helm — 계획]
    end

    %% ── AWS Cloud ────────────────────────────────────────
    subgraph CLOUD["☁️ AWS Cloud — Region: ap-northeast-2"]
        direction TB

        R53[🌍 Route 53]
        CF[CloudFront / WAF]
        ECR[(📦 ECR<br/>Container Registry)]

        subgraph VPC["🔒 VPC (10.0.0.0/16)"]
            direction TB
            ALB[⚖️ Application Load Balancer<br/>HTTPS · ACM 인증서]

            subgraph K8S["⎈ Kubernetes Cluster — 3 AZ (a · b · c)"]
                direction LR

                subgraph NS_APP["📦 namespace: axis-app"]
                    direction TB
                    FE["⚛️ frontend Deployment<br/>React 18 + Vite + Radix UI<br/>replicas: 2 (HPA 예정)"]
                    BE["🍃 backend Deployment<br/>Spring Boot 3 · Java 17 · Flyway<br/>replicas: 2 (HPA 예정)"]
                    AI["🐍 ai Deployment<br/>Python 3.11 · FastAPI · LangGraph<br/>BGE-M3 · BGE-reranker-v2-m3<br/>replicas: 2 (HPA 예정)"]
                end

                subgraph NS_CICD["🚀 namespace: axis-cicd (W6+ 계획)"]
                    direction TB
                    JK["🟠 Jenkins<br/>Master + Agents"]
                    AR["🐙 ArgoCD<br/>GitOps Controller"]
                end

                subgraph NS_OBS["📊 namespace: monitoring (W6+ 계획)"]
                    direction TB
                    PR[Prometheus]
                    GR[Grafana]
                    LK[Loki]
                    ML[MLflow]
                end
            end
        end
    end

    %% ── 트래픽 흐름 (실선) ────────────────────────────────
    User -->|HTTPS| R53
    R53 --> CF
    CF --> ALB
    ALB --> FE
    ALB --> BE
    BE -->|"in-cluster<br/>ai-internal-api.yaml"| AI
    AI -->|크롤링 fetch| SRC
    BE -->|"평일 08:30 브리핑 발송"| Mail

    %% ── 데이터 영속화 / LLM (굵은 실선) ──────────────────
    BE ==>|"JDBC<br/>sslmode=require"| SB
    AI ==>|"SQLAlchemy + psycopg2"| SB
    AI ==>|"HTTPS + api-key"| QC
    AI ==>|"Chat / Embedding"| OA
    ML ==>|"artifacts"| S3

    %% ── CI/CD (점선 — W6+ 계획) ──────────────────────────
    Dev -->|git push| GH
    GH -.webhook.-> JK
    JK -.build · test · scan.-> ECR
    JK -.bump image tag.-> GHOPS
    GHOPS -.git poll.-> AR
    AR -.sync.-> FE
    AR -.sync.-> BE
    AR -.sync.-> AI

    %% ── 모니터링 (점선 — W6+ 계획) ──────────────────────
    AI -.metrics.-> PR
    BE -.metrics.-> PR
    FE -.logs.-> LK
    PR -.dashboard.-> GR
    LK -.dashboard.-> GR

    %% ── 스타일 ───────────────────────────────────────────
    classDef user fill:#F3F4F6,stroke:#1F2937,stroke-width:2px,color:#1F2937
    classDef fe fill:#EFF6FF,stroke:#2563EB,stroke-width:2px,color:#1E3A8A
    classDef be fill:#ECFDF5,stroke:#059669,stroke-width:2px,color:#064E3B
    classDef ai fill:#FEF3C7,stroke:#D97706,stroke-width:2px,color:#78350F
    classDef db fill:#EEF2FF,stroke:#4F46E5,stroke-width:2px,color:#312E81
    classDef saas fill:#F5F3FF,stroke:#7C3AED,stroke-width:2px,color:#4C1D95
    classDef cicd fill:#FEF2F2,stroke:#DC2626,stroke-width:2px,color:#7F1D1D
    classDef obs fill:#F0FDFA,stroke:#0D9488,stroke-width:2px,color:#134E4A
    classDef cloud fill:#F8FAFC,stroke:#0F172A,stroke-width:2px,color:#0F172A

    class User,Dev,Mail user
    class FE fe
    class BE be
    class AI ai
    class SB,QC,S3 db
    class OA saas
    class JK,AR,ECR,GH,GHOPS cicd
    class PR,GR,LK,ML obs
    class ALB,R53,CF cloud
```

### 다이어그램 범례

| 선 종류 | 의미 | 사용 예 |
|---|---|---|
| `─→` 실선 | 사용자 요청 트래픽 · 외부 fetch · 알림 발송 (동기 HTTP) | User→R53, BE→AI, AI→Naver, BE→Email |
| `═→` 굵은 실선 | 데이터 영속화 · 외부 LLM 호출 | BE/AI→Supabase, AI→Qdrant/OpenAI, MLflow→S3 |
| `-.→` 점선 | CI/CD · 모니터링 (W6+ 계획, 현재 미구현) | GH→Jenkins, ArgoCD→Pods, AI→Prometheus |

---

## 2. 컴포넌트 스택 (한 페이지 요약)

| 레이어 | 기술 | 책임 | 현재 상태 |
|---|---|---|---|
| Frontend | React 18 + Vite + TypeScript + Radix UI | 대시보드 UI | docker-compose 운영, W6+ K8s |
| Backend | Spring Boot 3.x · Java 17 · Flyway · WebClient · Spring Mail | REST API · JWT · 스케줄러 · 이메일 브리핑 발송 | 평일 08:30 자동 발송 (Slack 폐기) |
| AI Server | Python 3.11 · FastAPI · LangGraph 1.1.8 · uv | 크롤링 · 7노드 분석 파이프라인 · RAG | SQLAlchemy 2.0 + psycopg2 로 Supabase 접근 |
| RDB | PostgreSQL 16 (Supabase Managed) | 원문 · 이슈카드 · evidence_chain | Transaction Pooler:6543 (sslmode=require) |
| Vector DB | Qdrant 1.9 (Cloud) | 하이브리드 검색 (Dense+Sparse RRF) | `axis_main` 3개월 TTL · `axis_history` 12개월 TTL |
| LLM | OpenAI GPT-4o | 분류 · 카드 생성 · Generative Search | 일일 비용 목표: ≤ ₩5,000 |
| 임베딩 / 재랭킹 | BGE-M3 + BGE-reranker-v2-m3 | 로컬 추론 (FlagEmbedding, MIT) | AI Pod 내장 — 외부 호출 없음 |
| 스케줄러 | Spring `@Scheduled` (cron) | 매시 수집 · 평일 08:30 브리핑 · 월 09:00 약한신호 | `SchedulerConfig.java` |
| 컨테이너 | Docker Compose → Kubernetes | 5 컨테이너 → K8s Deployment | **현재**: docker-compose / **W6+**: K8s 3 AZ |
| CI | GitHub Actions → Jenkins | 빌드 · 테스트 · 이미지 푸시 | **현재**: GH Actions / **W6+**: Jenkins on K8s |
| CD | (수동 배포) → ArgoCD | GitOps · 무중단 배포 | **현재**: 수동 / **W6+**: `axis-gitops` watch |
| 모니터링 | (없음) → MLflow + Prometheus + Grafana + Loki | 모델 실험 · 메트릭 · 로그 | **W6+ 계획** — 현재 미구축 |

> ADR 참조: [SpringBoot](adr/0001-springboot-selection.md) · [Qdrant](adr/0002-qdrant-selection.md) · [BGE-M3](adr/0003-bge-m3-selection.md) · [파이프라인 분리](adr/0004-pipeline-separation.md) · [이중 저장소](adr/0005-two-storage-design.md) · [Flyway](adr/0006-flyway-introduction.md)

---

## 3. Figma 작업 가이드

### 3.1 전체 레이아웃 (스크린샷 1번 패턴 차용)

> 아래 ASCII 는 **Figma 캔버스 배치 가이드**입니다. §1 mermaid 와 컴포넌트 위치는 동일하지만, ASCII 는 추가로 Public/Private 서브넷과 AZ 컬럼 분배(예: AZ-c 에 Jenkins/ArgoCD 우선 배치)까지 표현합니다 — 본 mermaid 는 namespace 단위로만 그룹화.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  👤 User ──→ Route 53 ──→ CloudFront ──→ ALB              👨‍💻 Developer    │
│                                                              ↓             │
│                                                            GitHub          │
├────────────────────────────────────────────────────────────────────────────┤
│  ☁️ AWS Cloud — Region ap-northeast-2                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ 🔒 VPC                                                                │ │
│  │  ┌──────────── ⎈ Kubernetes Cluster (가로로 길게) ──────────────┐    │ │
│  │  │  AZ-a 컬럼          AZ-b 컬럼          AZ-c 컬럼              │    │ │
│  │  │  ┌────────────┐    ┌────────────┐    ┌────────────┐         │    │ │
│  │  │  │ Public     │    │ Public     │    │ Public     │         │    │ │
│  │  │  │  ALB·NAT   │    │  NAT       │    │  NAT       │         │    │ │
│  │  │  ├────────────┤    ├────────────┤    ├────────────┤         │    │ │
│  │  │  │ Private    │    │ Private    │    │ Private    │         │    │ │
│  │  │  │  FE·BE·AI  │    │  FE·BE·AI  │    │  Jenkins   │         │    │ │
│  │  │  │            │    │            │    │  ArgoCD    │         │    │ │
│  │  │  │            │    │            │    │  MLflow    │         │    │ │
│  │  │  └────────────┘    └────────────┘    └────────────┘         │    │ │
│  │  └──────────────────────────────────────────────────────────────┘    │ │
│  │                              ECR (Container Registry)                  │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────┘
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ 🟢 Supabase  │  │ 🔴 Qdrant    │  │ 🤖 OpenAI    │  │ 📦 S3         │
   │ PostgreSQL   │  │ Cloud        │  │ GPT-4o       │  │ Storage      │
   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
                              ↑
   ┌──────────────────────────────────────────────────────────┐
   │ 🌐 외부 크롤 소스: Naver · DART · KIPRIS · RSS · Saramin  │
   └──────────────────────────────────────────────────────────┘
```

### 3.2 Frame · 색상 · 로고

**Frame**: 1920×1080 (또는 4K 발표용 3840×2160)

**색상 팔레트** (다이어그램 그룹별)

| 그룹 | 배경 | 보더 | 용도 |
|---|---|---|---|
| User / 외부 | `#F3F4F6` | `#1F2937` | User · Developer · Email |
| Frontend | `#EFF6FF` | `#2563EB` | React 영역 |
| Backend | `#ECFDF5` | `#059669` | Spring Boot |
| AI | `#FEF3C7` | `#D97706` | Python AI 서버 |
| 저장소 | `#EEF2FF` | `#4F46E5` | DB · S3 |
| LLM SaaS | `#F5F3FF` | `#7C3AED` | OpenAI |
| CI/CD | `#FEF2F2` | `#DC2626` | Jenkins · ArgoCD · ECR |
| 모니터링 | `#F0FDFA` | `#0D9488` | Prometheus · Grafana · MLflow |
| AWS Cloud | `#F8FAFC` | `#0F172A` | VPC · ALB · Region 박스 |

**로고 SVG** (Figma `Iconify` 플러그인에서 ID 검색해 끌어다 쓰면 됨)

| 컴포넌트 | Iconify ID | 브랜드 컬러 |
|---|---|---|
| React | `logos:react` | `#61DAFB` |
| Vite | `logos:vitejs` | `#646CFF` |
| TypeScript | `logos:typescript-icon` | `#3178C6` |
| Spring Boot | `logos:spring-icon` | `#6DB33F` |
| Java | `logos:java` | `#007396` |
| Python | `logos:python` | `#3776AB` |
| FastAPI | `logos:fastapi-icon` | `#009688` |
| LangChain | `simple-icons:langchain` | `#1C3C3C` |
| OpenAI | `simple-icons:openai` | `#412991` |
| Hugging Face (BGE-M3) | `logos:hugging-face-icon` | `#FFD21E` |
| PostgreSQL | `logos:postgresql` | `#4169E1` |
| Supabase | `logos:supabase-icon` | `#3ECF8E` |
| Qdrant | `simple-icons:qdrant` | `#DC382D` |
| Docker | `logos:docker-icon` | `#2496ED` |
| Kubernetes | `logos:kubernetes` | `#326CE5` |
| Jenkins | `logos:jenkins` | `#D24939` |
| ArgoCD | `logos:argo-icon` | `#EF7B4D` |
| GitHub | `logos:github-icon` | `#181717` |
| AWS | `logos:aws` | `#FF9900` |
| MLflow | `simple-icons:mlflow` | `#0194E2` |
| Prometheus | `logos:prometheus` | `#E6522C` |
| Grafana | `logos:grafana` | `#F46800` |
| Naver | (텍스트 라벨) | `#03C75A` |

### 3.3 작업 팁

1. **컴포넌트 라이브러리 먼저** — Server Box(rounded 12px, 보더 2px), Database Cylinder, Cloud Boundary(점선 박스), 화살표(실선=동기 / 점선=비동기) 4종을 라이브러리로 만들어두면 양산 빠름
2. **AZ 점선 박스** — 첫 번째 스크린샷처럼 dash `[6, 4]`, 보더 컬러 `#94A3B8`
3. **K8s 박스가 3 AZ를 가로지르게** — Pod 들이 AZ 어디든 떠도 됨을 시각적으로 표현 (스크린샷의 "Kubernetes Engine" 박스 패턴)
4. **트래픽 흐름은 두께·색으로 구분** — 사용자 요청(파랑 실선) / 데이터 영속화(녹색 굵은 실선) / CI/CD(주황 점선) / 모니터링(회색 점선)
5. **외부 SaaS 는 Cloud 박스 밖으로** — 시각적으로 "우리 인프라 외부" 임을 명확히 (스크린샷에서 elastic/MongoDB/weaviate 가 하단에 별도)
6. **트래픽·비용 캡션 우하단** — 첫 번째 스크린샷처럼 작은 글씨로 다음 수치 표기

   | 항목 | 추정치 | 근거 |
   |---|---|---|
   | 활성 사용자 | ~30명 (사내) | SK AX 사업전략팀 규모 |
   | 일일 크롤링 | ~500건 | Naver/DART/RSS 등 |
   | Qdrant 삽입 | ~50건/일 | Gate 1·2·3 통과 후 |
   | LLM 호출 비용 | 목표 ≤ ₩5,000/일 | CLAUDE.md 성능 목표 |
   | 이슈카드 생성 E2E | 목표 ≤ 30초 | CLAUDE.md 4주차 목표 |

---

## 부록: Mermaid → SVG 내보내기

```bash
# CLI 설치
npm install -g @mermaid-js/mermaid-cli

# 본 문서의 mermaid 블록을 SVG 로 (Figma import 용)
mmdc -i docs/SYSTEM_ARCHITECTURE.md -o docs/architecture.svg
```

또는 [mermaid.live](https://mermaid.live) 에 §1 코드 그대로 붙여넣고 다운로드.

---

## 갱신 정책

- **언제**: 새 컴포넌트 / 외부 의존 / 배포 토폴로지 변경 시
- **누가**: 변경 도입 PR 작성자가 같은 PR 에 본 문서 diff 포함
- **검증**: 리뷰어가 다이어그램 ↔ 실제 매니페스트 정합성 확인
- **ADR 와 관계**: 큰 의사결정은 ADR 가 SoT, 본 문서는 시각화. ADR 변경 시 본 문서도 동시 갱신
