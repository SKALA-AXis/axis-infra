# AXIS 팀 개발 컨벤션 및 협업 가이드

> **프로젝트명**: AXIS — AI 기반 Peer사 동향 모니터링 시스템
> **작성일**: 2026-04-17
> **최종 수정**: 2026-04-20 (레포 구조·기술 스택 확정 반영)
> **목적**: 팀 전원이 동일한 기준으로 협업하기 위한 컨벤션·프로세스·규칙 정의
> **문서 위치**: `axis-infra` 레포의 `docs/conventions/CONVENTION.md`

---

## 목차

1. [프로젝트 기본 정보](#1-프로젝트-기본-정보)
2. [레포지토리 구조 (멀티레포)](#2-레포지토리-구조-멀티레포)
3. [Git Flow 전략](#3-git-flow-전략)
4. [커밋 메시지 컨벤션](#4-커밋-메시지-컨벤션)
5. [브랜치 네이밍 규칙](#5-브랜치-네이밍-규칙)
6. [Pull Request 규칙](#6-pull-request-규칙)
7. [코드 컨벤션](#7-코드-컨벤션)
8. [Python 환경 관리 (uv)](#8-python-환경-관리-uv)
9. [이슈 관리](#9-이슈-관리)
10. [API 스펙 공유 규칙](#10-api-스펙-공유-규칙)
11. [문서화 규칙](#11-문서화-규칙)
12. [개발 환경 및 도구](#12-개발-환경-및-도구)
13. [커뮤니케이션 규칙](#13-커뮤니케이션-규칙)
14. [스프린트 운영](#14-스프린트-운영)

---

## 1. 프로젝트 기본 정보

| 항목 | 내용 |
|---|---|
| **서비스명** | AXIS (AX Intelligence Signal) |
| **프로젝트명** | AI 기반 Peer사 동향 모니터링 시스템 |
| **레포지토리 구조** | 멀티레포 (infra / backend / ai / frontend) |
| **Backend 스택** | SpringBoot 3.x (Java 17) — REST API 서버 |
| **AI/Crawler 스택** | Python 3.11+, FastAPI, LangGraph, BGE-M3, Qdrant, GPT-4o, uv |
| **Frontend 스택** | React 18 + TypeScript + Vite |
| **형상 관리** | Git + GitHub |
| **이슈 트래킹** | `axis-infra` 레포의 Issues + GitHub Projects (org 단위) |
| **커뮤니케이션** | Slack / Notion |

---

## 2. 레포지토리 구조 (멀티레포)

### 레포 구성

```
[GitHub Organization: skala-ai-13]
│
├── 🏗  axis-infra          ← 진실의 원천 (Source of Truth)
│   ├── CLAUDE.md            # 전체 프로젝트 컨텍스트 (Claude Code용)
│   ├── docker-compose.yml   # 전체 서비스 로컬 실행
│   ├── docker-compose.prod.yml
│   ├── .env.example
│   ├── db/
│   │   └── schema.sql       # PostgreSQL DDL
│   ├── api/
│   │   ├── openapi.yaml     # REST API 계약서 (Backend ↔ Frontend)
│   │   └── ai-internal-api.yaml  # 내부 API 계약서 (Backend ↔ AI)
│   ├── README.md            # 프로젝트 전체 소개 (레포 루트)
│   ├── .gitignore
│   ├── .github/
│   │   └── workflows/
│   │       └── validate.yml # SQL·OpenAPI 유효성 검사 CI
│   └── docs/
│       ├── conventions/
│       │   └── CONVENTION.md  # 본 문서
│       ├── adr/             # 기술 결정 기록 (ADR)
│       ├── meetings/        # 회의록 (YYYY-MM-DD.md)
│       └── sprints/         # 스프린트 계획 및 회고
│
├── ⚙️  axis-backend         ← SpringBoot REST API 서버 (Java 17)
│   ├── CLAUDE.md            # 백엔드 전용 컨텍스트 (Claude Code용)
│   ├── build.gradle
│   ├── .env.example
│   ├── Dockerfile
│   └── src/main/java/com/skala/axis/
│       ├── controller/      # REST API 엔드포인트
│       ├── service/         # 비즈니스 로직
│       │   └── AiClientService.java  # Python AI 서버 호출 전담
│       ├── repository/      # JPA Repository
│       ├── domain/          # JPA Entity
│       ├── dto/             # Request/Response DTO
│       └── config/          # Security, Scheduler, WebClient 설정
│
├── 🤖  axis-ai              ← Python AI 파이프라인 + 크롤러
│   ├── CLAUDE.md            # AI 전용 컨텍스트 (Claude Code용)
│   ├── pyproject.toml       # uv 기반 의존성 관리
│   ├── uv.lock
│   ├── .python-version
│   ├── .env.example
│   ├── Dockerfile
│   └── src/
│       ├── api/             # FastAPI 내부 엔드포인트 (SpringBoot만 호출)
│       ├── agents/          # LangGraph 에이전트 12개
│       ├── pipeline/        # 수집/전달 파이프라인 그래프
│       ├── rag/             # BGE-M3 임베딩, Qdrant 검색, Reranker
│       ├── crawler/         # 뉴스·공시·채용공고 수집
│       └── db/              # PostgreSQL, Qdrant 클라이언트
│
└── 🎨  axis-frontend        ← React 대시보드
    ├── CLAUDE.md            # 프론트 전용 컨텍스트 (Claude Code용)
    ├── package.json
    ├── .env.example
    ├── Dockerfile
    └── src/
        ├── pages/
        ├── components/
        ├── hooks/
        ├── api/             # axios 호출 레이어
        └── types/
            └── api.ts       # openapi.yaml에서 자동 생성 (수동 수정 금지)
```

### 멀티레포 운영 원칙

- **`axis-infra` 레포가 단일 진실 공급원(Single Source of Truth)** 입니다. 모든 API 스펙·DB 스키마·컨벤션·회의록·의사결정은 여기에 기록됩니다.
- **axis-backend(SpringBoot)와 axis-ai(Python)는 분리** 합니다. 언어가 다르고 배포 단위가 다릅니다.
- **axis-ai는 외부 직접 접근 불가** 합니다. 모든 요청은 axis-backend를 통해서만 전달됩니다.
- **Qdrant 직접 접근은 axis-ai만** 합니다. axis-backend는 Qdrant에 직접 쿼리하지 않습니다.
- **프론트-백 연동은 `api/openapi.yaml`로**, 백-AI 연동은 `api/ai-internal-api.yaml`로 진행합니다.
- **이슈는 `axis-infra` 레포에 통합 등록** 하는 것을 기본으로 하되, 레포 내부 이슈는 각 레포에서 관리할 수 있습니다.
- **GitHub Projects (org 레벨)** 로 모든 레포의 이슈를 하나의 칸반 보드에서 관리합니다.
- **CLAUDE.md** 각 레포 루트에 두어 Claude Code가 프로젝트 맥락을 자동으로 인식하게 합니다.

### 서비스 간 통신 구조

```
React (Frontend :3000)
    ↕ REST API (openapi.yaml 계약)
SpringBoot (Backend :8080)
    ↕ HTTP 내부 통신 (ai-internal-api.yaml 계약, 포트 8001)
Python AI Server (axis-ai :8001)
    ↕
PostgreSQL (:5432)    Qdrant (:6333)
```

---

## 3. Git Flow 전략

모든 레포에 동일하게 적용합니다. 간소화된 **GitHub Flow + develop** 전략을 사용합니다.

```
main        ──●────────●──────────●──  (배포용, 발표·제출용 안정 버전만)
              │        │          │
develop     ──┴●──●──●─┴●──●──●──●┴──  (통합 개발 브랜치, 기본 베이스)
                │  │  │   │  │  │
feature       ──┘  │  │   │  │  │     (기능 개발)
fix              ──┘  │   │  │  │     (버그 수정)
docs                ──┘   │  │  │     (문서 작업)
refactor                ──┘  │  │     (리팩토링)
```

**브랜치 역할**

| 브랜치 | 역할 | 직접 커밋 |
|---|---|---|
| `main` | 배포·제출용 안정 버전. 발표 시 이 브랜치 사용 | ❌ (PR만) |
| `develop` | 기본 통합 브랜치. 모든 feature가 여기로 머지됨 | ❌ (PR만) |
| `feature/*` | 새 기능 개발 | ✅ |
| `fix/*` | 버그 수정 | ✅ |
| `docs/*` | 문서 작업 | ✅ |
| `refactor/*` | 리팩토링 (동작 변경 없음) | ✅ |

**작업 흐름**

1. `develop`에서 feature 브랜치 생성
2. 로컬에서 작업 후 커밋
3. `develop`에 PR 생성
4. 최소 1명 리뷰 승인 후 Squash Merge
5. 마일스톤 단위로 `develop` → `main` PR

---

## 4. 커밋 메시지 컨벤션

**Conventional Commits** 규칙을 따릅니다.

### 형식

```
<type>(<scope>): <subject>

<body (선택)>

<footer (선택)>
```

### Type 종류

| Type | 의미 |
|---|---|
| `feat` | 새로운 기능 추가 |
| `fix` | 버그 수정 |
| `docs` | 문서 수정 |
| `style` | 코드 포맷팅, 세미콜론 누락 등 (동작 변경 없음) |
| `refactor` | 코드 리팩토링 (기능 변경 없음) |
| `test` | 테스트 코드 추가/수정 |
| `chore` | 빌드, 패키지 매니저, 설정 파일 수정 |
| `perf` | 성능 개선 |
| `ci` | CI/CD 파이프라인 수정 |

### Scope (레포별 구분)

**axis-backend 레포 (SpringBoot)**
- `api`, `service`, `domain`, `config`, `infra`, `auth`, `scheduler`

**axis-ai 레포 (Python AI)**
- `crawler`, `agent`, `rag`, `pipeline`, `db`, `api`, `schema`

**axis-frontend 레포 (React)**
- `ui`, `api`, `hooks`, `pages`, `auth`, `types`

**axis-infra 레포**
- `docker`, `db`, `api-spec`, `convention`, `architecture`, `meeting`, `sprint`, `adr`

### 예시

```
feat(crawler): 네이버 뉴스 수집기 추가

- BeautifulSoup 기반 파싱 로직 구현
- 중복 기사 URL 해시 기반 제거 추가

Closes skala-ai-13/axis-infra#12
```

```
feat(rag): BGE-M3 Dense+Sparse 하이브리드 검색 구현
fix(agent): Reranker 입력 토큰 초과 에러 해결
docs(api-spec): 이슈 카드 조회 엔드포인트 스펙 업데이트
refactor(service): AiClientService WebClient 타임아웃 분리
```

### 규칙

- **Subject는 50자 이내**, 마침표 없이, 명령형으로 작성
- 본문(Body)은 72자마다 줄바꿈, "왜" 변경했는지 중심으로 서술
- **크로스 레포 이슈 참조**: `Closes org/repo#N` 형식으로 작성

---

## 5. 브랜치 네이밍 규칙

```
<type>/<이슈번호>-<간단한-설명>
```

### 예시

```
feat/12-naver-news-crawler
feat/23-bge-m3-hybrid-search
fix/27-reranker-token-overflow
fix/34-springboot-ai-client-timeout
docs/35-api-spec-v2
refactor/41-issue-card-agent-split
```

### 규칙

- 영어 소문자 + 하이픈(`-`) 사용 (언더스코어 금지)
- 설명은 3~5단어 이내로 간결하게
- 이슈가 `axis-infra` 레포에 있는 경우에도 레포별 브랜치 번호는 그대로 사용

---

## 6. Pull Request 규칙

### PR 템플릿 (`.github/PULL_REQUEST_TEMPLATE.md`)

각 레포에 동일한 템플릿을 둡니다.

```markdown
## 🎯 작업 내용
- 이번 PR에서 한 작업 요약

## 🔗 관련 이슈
Closes skala-ai-13/axis-infra#N

## ✅ 변경 사항
- [ ] 변경사항 1
- [ ] 변경사항 2

## 🧪 테스트
- [ ] 로컬에서 테스트 완료
- [ ] 새로운 테스트 코드 추가
- [ ] 기존 테스트 모두 통과

## 📸 스크린샷 (UI 변경 시)

## 🔄 API 변경 여부
- [ ] API 변경 없음
- [ ] API 변경 있음 → `axis-infra/api/openapi.yaml` 업데이트 PR 함께 진행 (#PR 링크)
- [ ] AI 내부 API 변경 있음 → `axis-infra/api/ai-internal-api.yaml` 업데이트 PR 함께 진행 (#PR 링크)

## 💬 리뷰어에게 전달 사항
```

### PR 규칙

- **작게 쪼개서 올립니다.** 하나의 PR은 300 lines 이하를 권장합니다.
- **제목은 커밋 메시지와 동일한 형식** (`feat(scope): subject`)
- **최소 1명 이상의 리뷰 승인** 이 있어야 머지 가능
- **Merge 방식은 Squash Merge** 로 통일
- **머지 후 원본 브랜치 삭제**
- **CI 통과 안 된 PR은 머지 금지**

### 크로스 레포 PR 원칙

**REST API 변경이 있으면 세 개의 PR이 동시에 진행** 됩니다.

1. `axis-infra` 레포 — `api/openapi.yaml` 스펙 업데이트 **(먼저 머지)**
2. `axis-backend` 레포 — SpringBoot 엔드포인트 구현
3. `axis-frontend` 레포 — 타입 재생성 및 API 호출 코드 업데이트

**AI 내부 API 변경이 있으면 두 개의 PR이 동시에 진행** 됩니다.

1. `axis-infra` 레포 — `api/ai-internal-api.yaml` 스펙 업데이트 **(먼저 머지)**
2. `axis-backend` 레포 — AiClientService 업데이트
3. `axis-ai` 레포 — FastAPI 엔드포인트 업데이트

> 항상 `axis-infra` PR이 먼저 머지된 후 나머지가 머지됩니다.

### 리뷰 규칙

- **24시간 내 리뷰** 원칙
- 리뷰는 **근거와 대안** 을 함께 제시 ("이게 이상해요" ❌ / "이 부분은 N+1 쿼리가 발생할 수 있는데, `selectinload`를 쓰면 해결됩니다" ✅)
- **Approve / Request Changes / Comment** 를 명확히 구분

---

## 7. 코드 컨벤션

### Python (axis-ai)

- **패키지 매니저**: `uv` (`pip install` 절대 금지)
- **포매터**: `ruff format` (line-length 100)
- **린터**: `ruff check`
- **타입 체커**: `mypy` (최소 타입 힌트 필수)
- **네이밍**:
  - 함수/변수: `snake_case`
  - 클래스: `PascalCase`
  - 상수: `UPPER_SNAKE_CASE`
- **Docstring**: Google 스타일

```python
def embed_text(text: str, mode: str = "dense") -> dict:
    """BGE-M3로 텍스트를 임베딩한다.

    Args:
        text: 임베딩할 텍스트
        mode: 'dense' | 'sparse' | 'both'

    Returns:
        {'dense': np.ndarray, 'sparse': dict} 형태의 벡터

    Raises:
        EmbeddingTimeoutError: 임베딩 서버 응답 3초 초과 시
    """
```

### Java (axis-backend)

- **스타일 가이드**: Google Java Style Guide
- **빌드 도구**: Gradle
- **네이밍**:
  - 클래스: `PascalCase`
  - 메서드/변수: `camelCase`
  - 상수: `UPPER_SNAKE_CASE`
  - 패키지: `lowercase`
- **Lombok 적극 활용**: `@Data`, `@Builder`, `@RequiredArgsConstructor`
- **DTO 분리 필수**: Entity를 API 응답으로 직접 반환 금지
- **로거**: SLF4J (`System.out.println` 금지)
- **AI 서버 호출**: `AiClientService`에만 집중 (다른 Service에서 직접 호출 금지)

### TypeScript (axis-frontend)

- **포매터**: `prettier`
- **린터**: `eslint`
- **타입**: TypeScript strict 모드
- **네이밍**:
  - 함수/변수: `camelCase`
  - 컴포넌트/클래스: `PascalCase`
  - 상수: `UPPER_SNAKE_CASE`
  - 파일명(컴포넌트): `PascalCase.tsx`
  - 파일명(유틸): `camelCase.ts`
- **`src/types/api.ts` 수동 수정 금지**: openapi-typescript로만 재생성
- **`any` 타입 사용 금지**

### 공통 규칙

- **환경변수는 `.env`로 관리**, 코드에 하드코딩 금지
- **주석은 "왜"를 설명**, "무엇을"은 코드로 표현
- **함수는 한 가지 일만** 수행 (Single Responsibility)
- **매직 넘버 금지**, 상수로 추출
- **Pre-commit hook** 으로 포매터·린터 자동 실행

---

## 8. Python 환경 관리 (uv)

Python 환경 관리에 **uv** 를 사용합니다. pip + venv + pip-tools의 기능을 통합한 Rust 기반 패키지 매니저로, 설치 속도가 빠르고 재현성이 보장됩니다.

### 초기 세팅

```bash
# 1. uv 설치 (최초 1회)
curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. Python 버전 고정
uv python install 3.11
echo "3.11" > .python-version

# 3. 프로젝트 초기화 (레포 최초 생성 시만)
uv init
```

### 의존성 관리

```bash
# 패키지 추가
uv add fastapi langgraph langchain-openai

# 개발 의존성 추가
uv add --dev ruff mypy pytest pre-commit

# 특정 버전 지정
uv add "fastapi>=0.115,<0.120"

# 패키지 제거
uv remove 패키지명

# 의존성 동기화 (clone 후 최초 실행)
uv sync

# 의존성 업데이트
uv lock --upgrade
```

### 스크립트 실행

```bash
uv run uvicorn src.main:app --reload
uv run pytest
uv run ruff format .
uv run ruff check .
uv run mypy src/
```

### 핵심 파일

| 파일 | 커밋 여부 | 역할 |
|---|---|---|
| `pyproject.toml` | ✅ | 의존성 선언 |
| `uv.lock` | ✅ | 의존성 버전 고정 (재현성 보장) |
| `.python-version` | ✅ | Python 버전 고정 |
| `.venv/` | ❌ | 로컬 가상환경 (gitignore) |

### `pyproject.toml` 기본 구조

```toml
[project]
name = "axis-ai"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.115",
    "uvicorn[standard]>=0.27",
    "langchain>=1.2",
    "langchain-core>=1.2",
    "langchain-openai>=1.1",      # GPT-4o 연동 필수
    "langgraph>=1.1",
    "FlagEmbedding>=1.2",          # BGE-M3, BGE-reranker
    "qdrant-client>=1.9",
    "sqlalchemy>=2.0",
    "psycopg2-binary>=2.9",
    "openai>=1.30",
    "apscheduler>=3.10",
    "feedparser>=6.0",
    "beautifulsoup4>=4.12",
]

[dependency-groups]
dev = [
    "ruff>=0.5",
    "mypy>=1.10",
    "pytest>=8.0",
    "pytest-asyncio>=0.23",
    "pre-commit>=3.0",
]

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "W", "UP"]

[tool.mypy]
python_version = "3.11"
strict_optional = true
```

### 규칙

- **`uv.lock`은 반드시 커밋** 합니다. 버전 불일치 이슈를 방지합니다.
- **`requirements.txt`는 사용하지 않습니다.**
- 새 의존성 추가 시 **PR에서 의존성 추가 이유를 명시** 합니다.

---

## 9. 이슈 관리

### 이슈 위치

- **기획·기능·크로스 레포 이슈**: `axis-infra` 레포 (공통 이슈)
- **레포 내부 이슈**: 해당 레포 (예: SpringBoot 내부 리팩토링은 axis-backend 레포)

### 이슈 템플릿

#### 기능 이슈 (`.github/ISSUE_TEMPLATE/feature.md`)

```markdown
## 🎯 목적
이 기능이 왜 필요한가?

## 📋 요구사항
- [ ] 요구사항 1
- [ ] 요구사항 2

## 🎨 영향 범위
- [ ] axis-backend (SpringBoot)
- [ ] axis-ai (Python AI)
- [ ] axis-frontend (React)
- [ ] axis-infra (API 스펙, DB 스키마)

## 🔧 구현 힌트
기술적 접근 방법이나 참고 자료

## ✅ 완료 조건 (DoD)
- [ ] 테스트 통과
- [ ] 문서 업데이트
- [ ] PR 리뷰 완료
```

#### 버그 이슈 (`.github/ISSUE_TEMPLATE/bug.md`)

```markdown
## 🐛 버그 설명

## 🔁 재현 방법
1. ...
2. ...

## ✅ 기대 동작

## ❌ 실제 동작

## 🖥 환경
- 레포:
- Branch/Commit:
- OS:
- Java/Python/Node 버전:
```

### 라벨 체계

| 라벨 | 용도 |
|---|---|
| `type: feature` | 새 기능 |
| `type: bug` | 버그 |
| `type: docs` | 문서 |
| `type: refactor` | 리팩토링 |
| `priority: high` | 즉시 처리 |
| `priority: medium` | 일반 |
| `priority: low` | 여유 있을 때 |
| `area: backend` | SpringBoot 관련 |
| `area: ai` | Python AI·크롤러·RAG 관련 |
| `area: frontend` | React 관련 |
| `area: infra` | Docker·DB·API 스펙 관련 |
| `status: in-progress` | 진행 중 |
| `status: blocked` | 막혀있음 |

### GitHub Projects 운영

- **Org 레벨 Projects** 하나를 만들어 네 레포의 이슈를 통합 관리합니다.
- 칸반 컬럼: `Backlog` → `Todo` → `In Progress` → `Review` → `Done`
- 스프린트별로 필터링 가능하도록 `Sprint` 필드를 추가합니다.

---

## 10. API 스펙 공유 규칙

멀티레포에서 가장 중요한 이슈는 **레포 간 API 싱크** 입니다. OpenAPI 스펙을 계약서로 삼아 관리합니다.

### API 파일 구분

| 파일 | 용도 | 사용 레포 |
|---|---|---|
| `axis-infra/api/openapi.yaml` | SpringBoot ↔ Frontend REST API | axis-backend, axis-frontend |
| `axis-infra/api/ai-internal-api.yaml` | SpringBoot ↔ Python AI 내부 API | axis-backend, axis-ai |

### 원칙

- **`axis-infra/api/` 가 API의 유일한 진실** 입니다.
- API 변경 순서:
  1. `axis-infra` 레포에서 OpenAPI YAML 수정 PR **(팀 합의 + 먼저 머지)**
  2. 각 레포에서 자동 생성 재실행 후 구현
- 관련 PR들은 서로 링크를 연결합니다.

### 타입 자동 생성

**Frontend (openapi.yaml → TypeScript 타입):**
```bash
npx openapi-typescript ../axis-infra/api/openapi.yaml -o src/types/api.ts
```

**SpringBoot (openapi.yaml → Controller 인터페이스):**
```bash
openapi-generator-cli generate \
  -i ../axis-infra/api/openapi.yaml \
  -g spring \
  -o ./generated
```

**Python AI (ai-internal-api.yaml → Pydantic 모델):**
```bash
datamodel-codegen \
  --input ../axis-infra/api/ai-internal-api.yaml \
  --output src/schemas.py
```

### openapi.yaml 변경 시 팀 공지 필수

`axis-infra` 레포 PR에 아래 체크리스트를 반드시 포함합니다:
```markdown
## API 스펙 변경 공지
- [ ] axis-frontend: openapi-typescript 재실행 필요
- [ ] axis-backend: openapi-generator 재실행 필요
```

---

## 11. 문서화 규칙

### `axis-infra/docs/` 필수 문서

- `conventions/CONVENTION.md` — 본 문서
- `adr/NNNN-제목.md` — 주요 기술 의사결정 로그 (ADR)
- `meetings/YYYY-MM-DD.md` — 회의록
- `sprints/sprint-N.md` — 스프린트 계획 및 회고

### ADR 템플릿

```markdown
# NNNN. 결정 제목

- **날짜**: YYYY-MM-DD
- **상태**: Proposed / Accepted / Deprecated

## 배경
어떤 상황에서 어떤 문제가 있었는가?

## 결정
무엇을 선택했는가?

## 대안
어떤 다른 선택지가 있었는가?

## 근거
왜 이 선택을 했는가?

## 영향
이 결정이 가져오는 결과는?
```

### 작성된 ADR 목록

```
adr/0001-springboot-selection.md    SpringBoot + Python AI 분리 채택
adr/0002-qdrant-selection.md        Qdrant 채택 (하이브리드 검색 네이티브)
adr/0003-bge-m3-selection.md        BGE-M3 임베딩 채택
adr/0004-pipeline-separation.md     수집/전달 파이프라인 분리 원칙
adr/0005-two-storage-design.md      PostgreSQL + Qdrant 이중 저장소 설계
```

### 문서 원칙

- **코드와 문서는 같은 PR에서** 업데이트
- 회의록은 당일 작성자를 정해 24시간 내 업로드
- 중요한 기술 결정은 **ADR 형식으로 `docs/adr/`에 기록**
- CLAUDE.md는 프로젝트 맥락이 변경될 때마다 업데이트

---

## 12. 개발 환경 및 도구

### 필수 도구

| 도구 | 버전 | 용도 |
|---|---|---|
| Java (JDK) | 17 | axis-backend |
| Python | 3.11+ | axis-ai |
| uv | 최신 | Python 패키지 관리 |
| Node | 20+ | axis-frontend |
| pnpm 또는 npm | 최신 | JS 패키지 관리 |
| Docker + Docker Compose | v2.x | 전체 서비스 로컬 실행 |
| pre-commit | 3.x | 커밋 전 자동 검사 |

### 전체 서비스 한 번에 실행

```bash
# axis-infra 레포에서
docker compose up -d

# 서비스별 포트
# PostgreSQL: 5432
# Qdrant:     6333 (HTTP), 6334 (gRPC)
# Backend:    8080 (SpringBoot)
# AI:         8001 (Python FastAPI)
# Frontend:   3000 (React)
```

### axis-backend 로컬 세팅

```bash
git clone <axis-backend-url>
cd axis-backend
cp .env.example .env

# DB, Qdrant만 Docker로 먼저 실행
cd ../axis-infra && docker compose up -d postgres qdrant

# SpringBoot 실행
./gradlew bootRun --args='--spring.profiles.active=local'

# Swagger UI 확인
open http://localhost:8080/swagger-ui
```

### axis-ai 로컬 세팅

```bash
git clone <axis-ai-url>
cd axis-ai
cp .env.example .env

uv sync
uv run pre-commit install

# DB, Qdrant만 Docker로 먼저 실행
cd ../axis-infra && docker compose up -d postgres qdrant

# AI 서버 실행
uv run uvicorn src.api.main:app --reload --port 8001
```

### axis-frontend 로컬 세팅

```bash
git clone <axis-frontend-url>
cd axis-frontend
cp .env.example .env   # VITE_API_BASE_URL=http://localhost:8080

npm install

# 타입 자동 생성 (axis-infra가 같은 레벨에 있어야 함)
npx openapi-typescript ../axis-infra/api/openapi.yaml -o src/types/api.ts

npm run dev
```

### Pre-commit 설정 (axis-ai)

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.5.0
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: detect-private-key     # API 키 노출 방지
      - id: check-added-large-files
      - id: end-of-file-fixer
```

### 배포 전략

- **로컬 개발**: `axis-infra/docker-compose.yml`
- **시연·발표**: 단일 클라우드 VM에 `docker-compose.prod.yml`로 배포
- **향후 확장**: Kubernetes (현 단계에서는 적용하지 않음)

---

## 13. 커뮤니케이션 규칙

### 채널

| 채널 | 용도 |
|---|---|
| Slack `#general` | 공지·잡담 |
| Slack `#dev-backend` | SpringBoot 기술 논의 |
| Slack `#dev-ai` | Python AI·RAG·크롤러 기술 논의 |
| Slack `#dev-frontend` | React 기술 논의 |
| Slack `#alerts` | CI 실패, 배포 알림 (봇 연동) |
| Notion | 기획 초안, 아이디어 스케치 |
| GitHub Issues/PR | 모든 기술적 토론의 최종 기록 |

### 원칙

- **기술 결정은 GitHub에 남깁니다.** Slack에서 결정된 내용도 이슈/PR 코멘트로 한 번 더 기록합니다.
- 중요한 의사결정은 **ADR로 `docs/adr/`에 남깁니다.**
- **비동기 우선.** 즉답이 필요한 경우에만 멘션(@) 사용
- **막히면 15분 룰.** 15분 이상 혼자 해결 안 되면 질문합니다. 막히는 것을 혼자 해결하려다 시간 낭비하는 것이 더 큰 손해입니다.

---

## 14. 스프린트 운영

### 주기

- **1주 단위 스프린트** (월요일 시작 – 일요일 종료)

### 정기 미팅

| 미팅 | 시간 | 목적 |
|---|---|---|
| **스프린트 플래닝** | 월요일 오전 30분 | 이번 주 할 일 분배 |
| **데일리 스탠드업** | 매일 오전 15분 | 어제/오늘/블로커 |
| **스프린트 리뷰** | 금요일 오후 30분 | 결과물 데모 |
| **회고** | 금요일 오후 30분 | KPT (Keep / Problem / Try) |

### 주간 데모 원칙

**매주 금요일: 동작하는 것 1개가 반드시 팀에 공유되어야 합니다.**
'거의 다 됐어요'는 없는 것과 같습니다. 30%짜리 기능이라도 돌아가는 것을 보여줍니다.

### KPT 회고 양식 (`docs/sprints/sprint-N.md`)

```markdown
# Sprint N 회고 (YYYY-MM-DD ~ YYYY-MM-DD)

## 📊 스프린트 목표 달성도
- 계획: N개 이슈
- 완료: N개 이슈

## 👍 Keep (계속 하고 싶은 것)
-

## ⚠️ Problem (문제였던 것)
-

## 🚀 Try (다음 스프린트에 시도할 것)
-

## 🎯 다음 스프린트 목표
-
```

---

## 15. DB 마이그레이션 안전 규칙 (2026-06-12 사고 후 명문화)

> 사고: 미커밋 Flyway 초안(V44)이 로컬 bootRun + port-forward 경유로 **운영 DB에
> 직접 적용**됨 → 다음 배포가 체크섬 충돌로 CrashLoop. (상세: backend PR #79)

1. **공유 클러스터 DB에 flyway migrate는 배포 경로로만.** develop 머지 → 이미지 빌드
   → ArgoCD 배포된 pod의 Flyway만 운영 DB를 migrate할 수 있습니다.
2. **로컬 스키마 실험은 docker postgres에서만.** `--spring.flyway.enabled=true`
   override를 쓰기 전에 `lsof -i :5432`로 **port-forward가 5432를 점유 중인지 반드시
   확인**합니다 — docker DB인 줄 알았던 localhost:5432가 운영 DB일 수 있습니다.
3. **기술적 강제**: 운영 DB에는 `axis.environment='prod'` 마커가 설정돼 있고, backend의
   `beforeMigrate__prod_guard.sql`이 배포 경로 밖(placeholder `axis_migrate_source≠cluster`)
   migrate를 RAISE EXCEPTION으로 차단합니다.
4. **이미 적용된 마이그레이션 파일은 수정 금지** — 변경이 필요하면 새 V번호로 추가합니다.
5. 새 마이그레이션 추가 시 `axis-infra/db/schema.sql`(SSoT)도 같은 PR 세트로 동기화합니다.

---

## 📌 핵심 요약 (TL;DR)

1. **멀티레포 4개 (infra / backend / ai / frontend)**, `axis-infra`가 단일 진실 공급원
2. `develop` 브랜치 기반 GitHub Flow, 모든 레포에 동일 적용
3. 커밋/브랜치/PR은 **Conventional Commits** 형식
4. 모든 PR은 **1명 이상 리뷰 + Squash Merge**
5. **Python은 uv + ruff + mypy** (`pip install` 절대 금지), Java는 Google Style, TypeScript는 prettier + eslint
6. **`.env`는 절대 커밋 금지**, `uv.lock`은 반드시 커밋
7. **API 변경 시 axis-infra → backend/ai → frontend 순으로 PR** (연결 필수)
8. 이슈는 `axis-infra` 레포 중심 + **GitHub Projects org 보드** 로 통합 관리
9. 중요한 기술 결정은 **ADR로 `docs/adr/`** 에 기록
10. 주 1회 스프린트 + KPT 회고, 결과는 `docs/sprints/`에 저장
11. **각 레포 루트에 CLAUDE.md** 두어 Claude Code가 맥락을 자동으로 인식
12. **막히면 15분 룰** — 15분 이상 혼자 해결 안 되면 바로 질문

---

**본 문서는 팀 합의에 따라 언제든 수정 가능하며, 수정 시 `axis-infra` 레포에 PR로 제안합니다.**
