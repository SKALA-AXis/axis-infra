# 0001. SpringBoot + Python AI 분리 아키텍처 채택

- **날짜**: 2026-04-20
- **상태**: Accepted

## 배경

AXIS 시스템은 두 가지 성격이 다른 컴포넌트로 구성된다.

1. **REST API 서버**: 프론트엔드 요청 처리, DB 조회, 스케줄링, Slack 발송 — 안정성·타입 안전성·트랜잭션 관리가 중요
2. **AI 파이프라인**: LangGraph 기반 멀티 에이전트, BGE-M3 임베딩, Qdrant 연동, GPT-4o 호출 — Python AI 생태계 의존성이 높음

단일 언어/프레임워크로 두 역할을 모두 처리하는 방안도 검토했다.

## 결정

**SpringBoot 3.x (Java 17)** 를 REST API 서버로, **FastAPI (Python 3.11)** 를 AI 파이프라인 내부 서버로 분리 채택한다.

- 두 서버는 HTTP(포트 8001)로 통신하며, `api/ai-internal-api.yaml` 이 계약을 정의한다.
- 프론트엔드는 SpringBoot만 바라본다. Python 서버는 외부 직접 접근 불가.

## 대안

| 대안 | 기각 이유 |
|---|---|
| FastAPI 단일 서버 | Java 기반 엔터프라이즈 기능(JPA, Scheduler, WebClient) 사용 불가. 팀 백엔드 역량 Java에 집중 |
| SpringBoot 내 Python 서브프로세스 호출 | 모델 로딩 비용 매번 발생. 배포 단위 분리 불가 |
| Django + DRF | 비동기 처리 불리, LangGraph 통합 복잡 |

## 근거

- **언어별 최적 생태계 활용**: Java의 JPA/Scheduler/WebClient vs Python의 LangChain/FlagEmbedding/Qdrant-client
- **팀 역량 분리**: Backend Lead는 Java, AI Engineer는 Python — 서로 간섭 없이 병렬 개발 가능
- **배포 단위 분리**: AI 모델 업데이트 시 SpringBoot 재배포 불필요
- **환각 방지 격리**: AI 파이프라인 오류가 REST API 가용성에 영향을 주지 않음

## 영향

- `axis-infra/api/ai-internal-api.yaml` 이 두 서버 간 계약의 단일 진실 공급원
- SpringBoot는 `AiClientService` 한 곳에서만 Python 서버를 호출 (다른 서비스에서 직접 호출 금지)
- 로컬 개발 시 `docker compose up -d postgres qdrant` 후 각 서버를 별도 실행 가능
