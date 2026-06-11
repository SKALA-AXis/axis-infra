# AXIS 개발표준 정의서 — Infra

| 항목 | 내용 |
|---|---|
| 업무명 | AI를 활용한 Peer사 동향 모니터링 |
| Version | 1.0 (infra) |
| 프로젝트 | AXIS — AX Intelligence Signal |
| 작성일 | 2026-04-27 |
| 발주기관 | SK AX 사업전략팀 |
| 보안등급 | 일반 |
| 수행팀 | SKALA AI 13조 (김가은·박지원·박진·심유정·안가은·최종민) |
| 적용 레포 | **axis-infra** (스펙 / 스키마 / 컴포즈 / CI / 컨벤션) |

## 제·개정 이력

| 버전 | 일자 | 내용 | 작성자 | 승인자 |
|---|---|---|---|---|
| 1.0 | 2026-04-27 | 통합 표준정의서(v1.0)에서 infra 영역만 분리·재편 | 박지원, 최종민 | 김가은 |
| 1.0.1 | 2026-04-27 | 실제 레포 상태와 정합 검증 후 보정 — 컨테이너 5개로 정정, Qdrant 컬렉션 설계(ADR-0005)·TTL 추가, CI 실측(validate.yml 3 jobs) 반영, Flyway 현행 미연결 명시, Conventional Commits 9 type 정합, 브랜치 명세 CONVENTION.md §5 정합, `.gitignore` 실제 패턴(`*.p12`) 반영, `detect-private-key` 현행 반영 | 박지원, 최종민 | — |

---

## 1. 개요

### 1.1 본 문서의 목적

본 문서는 AXIS 프로젝트 중 **axis-infra 레포**가 책임지는 영역(API 스펙, DB 스키마, Docker Compose, CI, 컨벤션 문서, ADR)에 대한 개발 표준을 정의한다.
통합본 [AXIS_개발표준정의서_v1.0.docx](AXIS_개발표준정의서_v1.0.docx)에서 언어별 코드 규칙(Java/Python/TS)·계층별 규칙·테스트·AI 개발 표준은 제외하고, infra 레포가 단독으로 변경·관리하는 항목만 추출했다.

목적:

- 4개 레포(infra·backend·ai·frontend)가 공유하는 **계약(API·스키마·env)** 의 단일 출처를 infra에 두고, 변경 절차를 명확히 한다.
- 개발 환경(Docker·DB·Vector DB)을 모든 팀원이 동일하게 재현할 수 있도록 한다.
- 형상관리(브랜치·커밋·PR)와 보안(시크릿·접근통제)에 대한 최소 기준을 명시한다.

### 1.2 적용 범위

| 범위 | 포함 | 제외(다른 레포가 책임) |
|---|---|---|
| API 스펙 | `api/openapi.yaml`, `api/ai-internal-api.yaml` | 핸들러·라우터 구현 (backend/ai) |
| DB | `db/schema.sql`, Flyway 마이그레이션 정책 | JPA Entity·SQLAlchemy 모델 (backend/ai) |
| 컨테이너 | `docker-compose.yml`, `docker-compose.prod.yml` | 서비스 Dockerfile (backend/ai/frontend) |
| 환경변수 | `.env.example` 표준, 키 네이밍, 비밀 관리 정책 | 각 레포의 `application.yml` / `pyproject` 사용 방식 |
| CI | `.github/workflows/*` (infra 레벨), `docs/CI.md` | 각 레포 단위 빌드/테스트 파이프라인 |
| 문서 | `docs/conventions/`, `docs/adr/`, `docs/sprints/`, `docs/meetings/` | 각 레포 README, 코드 주석 |

### 1.3 개발 표준 적용의 예외

표준에서 벗어난 결정이 필요할 때는 **PM(김가은)** 과 사전 협의 후 [docs/adr/](../adr) 에 ADR로 기록한다. ADR 없이 적용된 예외는 PR 리뷰에서 차단한다.
현재까지 채택된 ADR 목록은 [CONVENTION.md §11](CONVENTION.md) 또는 [docs/adr/](../adr) 디렉터리를 직접 참조한다.

---

## 2. 인프라 아키텍처

### 2.1 적용 환경 (infra 책임 항목)

| 구분 | 항목 | 버전/사양 |
|---|---|---|
| RDBMS | PostgreSQL | 16 (docker image `postgres:16`) |
| Vector DB | Qdrant | 1.9.0 (docker image `qdrant/qdrant:v1.9.0`) |
| 컨테이너 | Docker / Docker Compose | v2.x |
| API 스펙 | OpenAPI | 3.0.x (YAML, `swagger-cli` 검증) |
| CI/CD | GitHub Actions | 레포별 워크플로우 + infra 레벨 스펙 검증 ([validate.yml](../../.github/workflows/validate.yml)) |
| 마이그레이션 | Flyway | 9.x 도입 예정 (현재는 `db/schema.sql` 직접 적용. 스테이징 진입 시점에 `axis-backend/src/main/resources/db/migration/V*.sql` 로 전환) |
| 시크릿 관리 | `.env` (로컬·dev), GitHub Actions Secrets (CI), 시크릿 매니저(AWS SSM/Secrets Manager 등) (prod 도입 예정 — ADR로 결정) | — |

> Backend(JDK·SpringBoot·Gradle)·AI(Python·LangGraph·LLM)·Frontend(Node·React·Vite)의 런타임 사양은 각 레포 표준을 따른다. 통합 사양은 [AXIS_개발표준정의서_v1.0.docx](AXIS_개발표준정의서_v1.0.docx) §2.1을 참조.

### 2.2 도입 솔루션 (infra 책임)

| 솔루션 | 채택 근거 |
|---|---|
| PostgreSQL 16 | 원문 아카이브·카드 뉴스·평가 메타 보관. JSON·전문검색 보조. 레퍼런스 풍부, 관리 비용 낮음. |
| Qdrant 1.9 | Dense+Sparse 하이브리드 검색 네이티브 지원. Rust 기반 안정성. **두 컬렉션 분리 운용** (`articles_main` 3개월 TTL — 검색용 / `articles_history` 12개월 TTL — 시그널 히스토리용). 채택 근거 ADR-0002, 저장소 설계 ADR-0005. |
| Docker Compose | 5개 컨테이너(`postgres`, `qdrant`, `backend`, `ai`, `frontend`)를 한 번에 기동·재현. Kubernetes 도입 전 단계의 표준. |
| GitHub Actions | 레포 권한 일원화. 서비스 컨테이너·시크릿 관리 표준 기능 제공. |

### 2.3 시스템 아키텍처 (스토리지·네트워크 관점)

```
┌──────────────────────────────────────────┐
│  React Frontend  (:3000)  ← 외부 노출 (UI) │
└─────────────────┬────────────────────────┘
                  │ REST  (api/openapi.yaml)
┌─────────────────▼────────────────────────┐
│  SpringBoot Backend  (:8080)  ← 외부 노출  │
│  - 유일한 외부 API 진입점                     │
│  - JWT 인증, CRUD, Email 발송 (v3 예정)     │
└─────────────────┬────────────────────────┘
                  │ HTTP 내부 (api/ai-internal-api.yaml)
┌─────────────────▼────────────────────────┐
│  Python AI Server  (:8001)                │
│  ※ prod 컴포즈에서 호스트 노출 금지 (expose만) │
│  - LangGraph 파이프라인, 크롤러               │
└──────┬─────────────────────┬─────────────┘
       │                     │
┌──────▼──────┐     ┌────────▼────────┐
│ PostgreSQL  │     │  Qdrant          │
│ (:5432)     │     │  (:6333 / :6334) │
└─────────────┘     └─────────────────┘
```

원칙:

- 외부에 노출되는 컴포넌트는 **frontend(UI)** 와 **backend(API)** 두 곳뿐이다.
- Frontend는 backend `:8080`만 호출한다. AI 서버·DB·Qdrant 직접 호출 금지.
- AI 서버는 backend에서만 호출한다(`AiClientService`). prod 컴포즈에서 `:8001` 호스트 노출 금지(개발 컴포즈는 디버깅 편의를 위해 publish 허용).
- 두 스토리지(Postgres / Qdrant) 동기화 책임은 AI 서버가 단독으로 진다 (ADR-0005).

---

## 3. 인프라 개발 표준

### 3.1 API 스펙 표준 (OpenAPI)

infra 레포는 외부 API(`openapi.yaml`)와 내부 API(`ai-internal-api.yaml`) 두 스펙을 단일 출처로 보관한다. backend·ai·frontend는 이 스펙으로부터 코드를 생성하거나 검증한다.

#### 3.1.1 URI 작성 원칙

- URI는 **소문자**만 사용한다. 단어 구분은 **하이픈(`-`)**, 언더스코어 금지.
- Resource는 명사·복수형으로 표현한다 (`/issues`, `/peers`). 행위는 HTTP Method.
- URI 끝 슬래시·확장자(`.json`) 금지. Content-Type 헤더로 표현.
- Collection: `/api/{resources}` · Item: `/api/{resources}/{id}` · Sub-collection: `/api/{resources}/{id}/{children}`.

#### 3.1.2 표준 URI 예시

| Method | URI | 설명 |
|---|---|---|
| GET | `/api/issues` | 카드 뉴스 목록 |
| GET | `/api/issues/{id}` | 카드 뉴스 단건 |
| GET | `/api/issues/today` | 오늘의 브리핑 |
| POST | `/api/search` | AI 검색 |
| GET | `/api/peers` | Peer사 목록 |
| GET | `/api/peers/{peerId}/issues` | Peer사 이슈 타임라인 |
| GET / PUT | `/api/alerts/settings` | 알림 설정 |
| GET | `/health` | 헬스체크 |

#### 3.1.3 응답 래퍼 표준

모든 외부 API는 공통 래퍼를 사용한다.

```json
// 성공
{ "success": true,  "data": { ... },
  "timestamp": "2026-04-27T09:00:00Z" }

// 실패
{ "success": false, "error": { "code": "AI_SERVER_TIMEOUT",
                               "message": "AI 서버 응답 시간 초과" },
  "timestamp": "2026-04-27T09:00:00Z" }
```

#### 3.1.4 HTTP Status Code 기준

| Code | 사용 시점 |
|---|---|
| 200 | 조회·수정·삭제 성공 |
| 201 | POST 자원 생성 성공 |
| 400 | 입력값 유효성 실패 |
| 401 | JWT 없음/만료 |
| 403 | 권한 없음 |
| 404 | 리소스 없음 |
| 500 | 서버 내부 오류 |
| 503 | AI 서버 타임아웃·다운 |

#### 3.1.5 스펙 변경 절차

1. infra 레포에서 `api/openapi.yaml` 또는 `api/ai-internal-api.yaml` 수정 PR 생성. validate.yml 의 `Notify API Spec Change` job 이 자동으로 PR에 타입 재생성 명령을 코멘트한다.
2. 머지 후 각 레포에서 자동 생성을 재실행하고 후속 PR을 올려 **PR끼리 본문에서 상호 링크**한다. CONVENTION.md §6 의 크로스 레포 PR 원칙에 따라 `axis-infra` 가 항상 먼저 머지된다.

   ```bash
   # frontend
   npx openapi-typescript ../axis-infra/api/openapi.yaml -o src/types/api.ts

   # backend
   openapi-generator-cli generate -i ../axis-infra/api/openapi.yaml -g spring -o ./generated

   # ai
   datamodel-codegen --input ../axis-infra/api/ai-internal-api.yaml --output src/schemas.py
   ```

3. Breaking change(URI/필드 삭제·타입 변경)는 ADR을 동반한다.

### 3.2 명명 규칙 (infra가 직접 관리하는 자산)

| 대상 | 규칙 | 예시 |
|---|---|---|
| 레포명 | kebab-case | `axis-infra` |
| 디렉토리·일반 파일 | kebab-case | `docker-compose.prod.yml` |
| YAML/MD/SQL 파일 | kebab-case 또는 의미적 prefix | `openapi.yaml`, `schema.sql` |
| ADR 파일 | `NNNN-{slug}.md` (4자리 일련번호 + 하이픈) | `0004-pipeline-separation.md` |
| Flyway 마이그레이션 | `V{N}__{설명}.sql` (snake_case 설명) | `V2__add_evidence_table.sql` |
| DB 테이블·컬럼 | **snake_case** 단·복수 일관성 (테이블 단수형 권장) | `card_news`, `published_at` |
| DB 인덱스 | `idx_{table}_{cols}` | `idx_card_news_published_at` |
| DB 외래키 | `fk_{child}_{parent}` | `fk_evidence_card_news` |
| Qdrant 컬렉션 | `{domain}_{purpose}` snake_case | `articles_main`, `articles_history` |
| 환경변수 | UPPER_SNAKE_CASE, 도메인 prefix | `POSTGRES_PASSWORD`, `OPENAI_API_KEY` |
| 브랜치 | `<type>/<issue#>-<kebab-desc>` ([CONVENTION.md §5](CONVENTION.md) 표준) | `feat/12-naver-news-crawler` |
| 커밋 scope | kebab-case | `feat(api-spec): ...` |

### 3.3 DB 스키마 표준

#### 3.3.1 단일 출처

- `db/schema.sql` 은 **신규 환경 부트스트랩용 전체 스키마 스냅샷**이다.
- 운영 환경은 **Flyway 마이그레이션**으로만 변경한다 (`axis-backend/src/main/resources/db/migration/V{N}__*.sql`).
- 스키마 변경 시 ① Flyway V 스크립트 추가, ② `db/schema.sql` 동기화 두 가지 모두 수행한다.

#### 3.3.2 컬럼·타입 규칙

- PK는 `id BIGSERIAL` 또는 `BIGINT GENERATED BY DEFAULT AS IDENTITY` 를 기본으로 한다.
- 시각은 `TIMESTAMPTZ` 만 사용한다. `TIMESTAMP`(without tz) 금지.
- 문자열은 길이 상한이 명확한 경우에만 `VARCHAR(N)`, 본문류는 `TEXT`.
- JSON은 `JSONB`, 배열은 `TEXT[]` 또는 `JSONB`.
- NULL 허용 여부와 기본값을 모든 컬럼에 명시한다.
- 모든 테이블은 `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` 를 가진다. 변경 추적이 필요한 테이블은 `updated_at` 도 추가.

#### 3.3.3 인덱스·제약

- 외래키에는 인덱스를 함께 만든다 (Postgres는 자동 생성하지 않음).
- 자주 조회되는 시간 필드(`published_at`, `created_at`)에 단일·복합 인덱스를 의도적으로 부여하고, 이유를 코멘트로 남긴다.
- UNIQUE 제약은 비즈니스 의미가 있는 경우에만 사용. 임시 dedup 용도는 별도 해시 컬럼으로.

#### 3.3.4 Qdrant 컬렉션 표준 (ADR-0005 정합)

- 컬렉션 두 개로 분리 운용:

  | 컬렉션 | 보존 | 용도 |
  |---|---|---|
  | `articles_main` | 3개월 TTL | 최근 기사 검색 (Dense+Sparse 하이브리드) |
  | `articles_history` | 12개월 TTL | 시그널 히스토리 분석·추세 비교 |

- 페이로드에는 **원문 텍스트 저장 금지** — 원문은 Postgres `raw_articles` 가 단일 출처. 페이로드는 메타데이터만(`rdb_id`, `peer_id`, `event_type`, `sector`, `exposure_band`, `exposure_score`, `pub_date`, `cluster_id`, `title`, `summary`).
- 두 스토리지의 동기화 책임은 axis-ai 가 단독으로 진다. backend·frontend 는 Qdrant 직접 접근 금지.

### 3.4 마이그레이션 표준 (Flyway)

- 도구: **Flyway 9.x** (도입 예정). 실행 주체는 backend 부팅 시 자동(`spring.flyway.enabled=true`).
- 위치: `axis-backend/src/main/resources/db/migration/` (디렉터리는 도입 시 생성).
- 파일명: `V{N}__{snake_case_description}.sql` (`N`은 단조 증가 정수, 빈 번호 없음).
- 한 마이그레이션은 **하나의 의도** 만 담는다. 무관한 변경 묶기 금지.
- 작성된 마이그레이션은 **불변**이다. 머지된 V 스크립트 수정 금지 — 새 V 스크립트로 보정.
- DROP·NOT NULL 추가 등 위험 변경은 두 단계로 분리:
  1. 새 컬럼/테이블 추가 + 백필,
  2. 다음 릴리스에서 제약 강화/구 컬럼 제거.
- **현재 상태(2026-04-27)**: backend `application.yml` 에 `flyway.enabled=false` 로 미연결, `db/schema.sql` 직접 수정 + 컨테이너 초기화로 운용 중. 스테이징 진입 시점에 Flyway 활성화 + V1 베이스라인을 작성하여 전환한다. 전환 시점은 별도 ADR 로 기록한다.

### 3.5 Docker / Compose 표준

- `docker-compose.yml` (개발용): `postgres`·`qdrant`·`backend`·`ai`·`frontend` 5개 서비스를 한 번에 기동. dev에서는 디버깅 편의를 위해 모든 포트를 호스트로 publish 한다.
- `docker-compose.prod.yml` (운영용): `postgres`·`qdrant`·`ai` 는 `ports:` 대신 `expose:` 만 — 호스트 노출 금지. 외부 노출은 `backend(:8080)`·`frontend(:3000)` 두 가지로 한정한다.
- 이미지 태그는 가능한 한 패치까지 고정한다 (예: `postgres:16`, `qdrant/qdrant:v1.9.0`). `latest` 금지.
- `restart` 정책: dev 는 `unless-stopped`, prod 는 `always`.
- 헬스체크(`healthcheck:`) 를 DB·Qdrant·backend·ai 에 명시하고, 의존 서비스는 `depends_on: condition: service_healthy` 사용.
- 볼륨은 named volume(`pgdata`, `qdrant_storage`)으로 선언하고, 호스트 bind mount는 개발용 컴포즈의 `./db/schema.sql:/docker-entrypoint-initdb.d/...` 같은 read-only 마운트에 한해 사용한다.
- 운영 컴포즈는 절대로 기본 비밀번호(`axpass` 등)를 fallback 으로 두지 않는다 (3.6 참조).

### 3.6 환경변수 / 시크릿 관리

- 모든 환경변수는 `.env.example` 에 키 + 더미값 + 1줄 설명을 남긴다. 실제 값은 `.env` (`.gitignore` 처리됨).
- Compose 변수 치환 시 **fallback 비밀번호 금지**: `${POSTGRES_PASSWORD:-axpass}` ❌ → `${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}` ✅. (현재 dev 컴포즈는 fallback 잔존 — 정리 대상)
- 시크릿이 들어가는 키는 suffix 로 식별 가능해야 한다: `*_PASSWORD`, `*_SECRET`, `*_API_KEY`, `*_TOKEN`, `*_CLIENT_SECRET`.
- 커밋 전 pre-commit hook으로 자동 차단: 현재 axis-ai 가 `detect-private-key` 를 적용 중 ([CONVENTION.md §12](CONVENTION.md)). 전 레포 확장 + `detect-secrets` 또는 `gitleaks` 추가 도입 권장.
- 운영(prod) 시크릿은 `.env` 파일이 아닌 외부 시크릿 매니저(AWS SSM/Secrets Manager 등)에서 주입한다. 도입 시점은 ADR로 기록.

### 3.7 형상관리 및 협업 규칙

> 본 절은 [CONVENTION.md](CONVENTION.md) §3·§4·§5·§6 의 요약·infra 관점 재정리이다. 충돌 시 CONVENTION.md 가 우선한다.

#### 3.7.1 브랜치 전략

```
main        ──●────────●──   (배포·발표용 안정 버전. PR만 가능)
develop     ──┴●──●──●─┴──   (통합 개발 브랜치, 기본 베이스)
feat/*      ──┘              (기능 추가, develop에서 분기)
fix/*                        (버그 수정)
refactor/*                   (리팩토링)
docs/*                       (문서 작업)
```

브랜치명 형식: `<type>/<issue#>-<kebab-desc>` (예: `feat/12-naver-news-crawler`).

#### 3.7.2 커밋 메시지 (Conventional Commits)

형식: `<type>(<scope>): <subject>` — type 9종은 [CONVENTION.md §4](CONVENTION.md) 에 정의(`feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`, `ci`).

infra 레포에서 자주 쓰는 scope (CONVENTION.md §4 정합):

| Type | 대표 사용처 | infra scope 예시 |
|---|---|---|
| feat | 신규 스펙·스키마 추가 | `api-spec`, `db`, `docker` |
| fix | 컴포즈·CI·스펙 버그 | `docker`, `db`, `ci` |
| docs | 컨벤션·ADR·회의록·스프린트 | `convention`, `adr`, `meeting`, `sprint`, `architecture` |
| refactor | 스키마·컴포즈 리팩토링 | `db`, `docker` |
| chore | 환경·gitignore·`.env.example` | `infra` |
| ci | GitHub Actions 변경 | `ci` |

예시:

```
feat(db): 카드 뉴스에 evidence_links JSONB 컬럼 추가

- raw_articles 와 N:1 관계로 출처 링크 보관
- backend Flyway V*.sql 마이그레이션과 동시 머지 필요

Closes skala-ai-13/axis-infra#34
```

#### 3.7.3 Pull Request 규칙

- 한 PR은 **300 lines 이하** 권장.
- 제목 = 커밋 메시지 형식 (`feat(scope): subject`).
- **최소 1명 승인** + CI 통과 후 머지.
- 머지 방식: **Squash Merge** 통일. 머지 후 브랜치 삭제.
- API/스키마 변경 PR은 본문에 영향받는 backend·ai·frontend PR을 함께 링크 ([3.1.5 절차](#315-스펙-변경-절차)).
- `main` 강제 푸시 금지.

### 3.8 보안 규칙 (infra 관점)

- **시크릿** : 코드·로그·테스트 픽스처에 하드코딩 금지. 모두 환경변수 경유.
- **`.gitignore`** : `.env`, `.env.local`, `.env.*.local`, `*.pem`, `*.key`, `*.p12` 반드시 포함 (현재 `.gitignore` 에 적용됨). 정기 점검.
- **AI 서버 노출** : prod 컴포즈에서 `:8001` 호스트 노출 금지(`expose:` 만 사용). dev 컴포즈는 디버깅 편의를 위해 publish 허용하되, 외부 IP 바인딩(`0.0.0.0`) 금지·loopback(`127.0.0.1`) 권장.
- **DB 노출 통제** : 운영 컴포즈는 DB 포트 호스트 publish 금지(현재 `expose:` 적용 ✅). 개발 컴포즈는 `127.0.0.1:5432` 형태로 로컬 바인딩으로 좁히기 권장.
- **기본 비밀번호** : compose 의 `${VAR:-default}` fallback 으로 시크릿 기본값을 두지 않는다. 누락 시 컨테이너 기동을 실패시켜야 한다(`${VAR:?...}`).
- **CORS** : 외부 API 진입은 backend 한 곳이며 허용 origin 화이트리스트로 관리. 와일드카드(`*`) 금지.
- **CI 시크릿** : GitHub Actions Secrets 만 사용. workflow 파일에 평문 키 금지. fork 트리거 시 시크릿이 노출되지 않도록 `pull_request_target` 사용 신중.
- **취약점 스캔** : Dependabot(레포별), `docker scout` 또는 `trivy` 를 CI에 통합 — 도입 시점은 ADR로 결정.
- **로그 위생** : 이메일 SMTP 자격증명, JWT, OpenAI/외부 API 키는 로그에서 마스킹. backend·ai 공통 규칙은 통합본 §3.9 참조.

### 3.9 로깅 표준 (운영 관점)

infra 레포는 로깅 코드를 직접 작성하지 않지만, 운영 시 **모든 서비스가 따라야 할 공통 기준** 을 정의한다.

| 레벨 | 기준 |
|---|---|
| ERROR | 즉시 대응 필요. 알림 발송 대상. |
| WARN | 즉시 장애는 아니나 주의. (AI 타임아웃 → BM25 폴백 등) |
| INFO | 정상 동작의 주요 이벤트. 운영 모니터링 기준. |
| DEBUG | 개발·디버깅용. 운영에서는 OFF. |

공통 요구:

- 표준 출력은 **stdout 1개 스트림**, JSON line(`@timestamp`, `level`, `service`, `message`, `request_id`) 권장. Compose 로그 드라이버로 일괄 수집.
- LLM 호출은 `tokens_in / tokens_out / cost_usd / model` 을 INFO로 기록 (AI 레포 책임).
- 파이프라인 실행 시간 `elapsed_ms` 항상 기록.
- API·OpenAI 키, 비밀번호, 개인정보는 어떤 레벨에도 출력 금지.

### 3.10 ADR 작성 표준

ADR(Architecture Decision Record)은 비가역·고비용 결정을 기록하기 위해 사용한다.

- 위치: `docs/adr/NNNN-{slug}.md` (4자리 일련번호).
- 템플릿:

  ```markdown
  # NNNN. <결정 제목>

  - 상태: Proposed | Accepted | Superseded by ADR-####
  - 일자: YYYY-MM-DD
  - 결정자: <이름들>

  ## 배경
  <왜 결정이 필요한가, 어떤 제약이 있는가>

  ## 선택지
  1. ...
  2. ...

  ## 결정
  <채택안과 이유>

  ## 결과
  <어떤 트레이드오프가 발생하며, 후속 작업은 무엇인가>
  ```

- ADR 작성 트리거: 솔루션 선택, 데이터/스토리지 분할, 보안 모델, 외부 의존성 추가, 표준 위반 예외.
- 한 번 `Accepted` 된 ADR은 **수정하지 않고**, 새 ADR이 이를 `Supersedes` 하도록 작성한다.

### 3.11 CI 표준

상세 내용은 [docs/CI.md](../CI.md) 가 단일 출처이며, 본 절은 합의된 최소 기준만 명시한다.

- **트리거** ([validate.yml](../../.github/workflows/validate.yml) 기준)
  - `push`: `main`, `develop`, `feat/**`, `fix/**`
  - `pull_request`: `main`, `develop`
  - `workflow_dispatch`: 모든 브랜치 (수동)
- **infra 레포 워크플로우(현행 3 jobs)**
  1. `Validate SQL Schema` — service container `postgres:16` 에 `db/schema.sql` 을 `psql -f` 로 실제 적용. 문법·제약 위반 즉시 실패.
  2. `Validate OpenAPI Specs` — `swagger-cli validate` 로 `api/openapi.yaml`·`api/ai-internal-api.yaml` 검증.
  3. `Notify API Spec Change` — PR diff에서 `api/` 변경 감지 시 자동 코멘트(타입 재생성 명령 안내). 알림 전용으로 실패해도 머지 차단 아님.
- **레포별 워크플로우** : 각 레포가 자체 단위 테스트·빌드를 수행. infra는 결과를 합치지 않는다.
- **보안 게이트** : pre-commit `detect-private-key` 적용(현행 axis-ai). 전 레포 확장 + `detect-secrets` 또는 `gitleaks` 추가는 향후 ADR로 결정.
- **머지 차단 규칙** : CI 실패 + 리뷰 미승인 + Conflict 중 하나라도 있으면 머지 불가.

---

## 부록 A. 책임 매트릭스 (RACI 요약)

| 자산 | infra | backend | ai | frontend |
|---|---|---|---|---|
| `api/openapi.yaml` | **R/A** | C | C | C |
| `api/ai-internal-api.yaml` | **R/A** | C | C | — |
| `db/schema.sql` (스냅샷) | **R/A** | C | C | — |
| Flyway `V*.sql` | C | **R/A** | C | — |
| `docker-compose*.yml` | **R/A** | C | C | C |
| `.env.example` | **R/A** | C | C | C |
| `docs/adr/` | **R/A** | C | C | C |
| `.github/workflows` (infra 레벨) | **R/A** | C | C | C |
| 각 레포 코드/테스트 | I | **R/A** | **R/A** | **R/A** |

R=Responsible, A=Accountable, C=Consulted, I=Informed.

---

본 문서는 팀 합의에 따라 언제든 수정 가능하며, 수정 시 axis-infra 레포에 PR로 제안한다.
변경된 표준은 머지 즉시 적용되며, 이전 표준에 따라 작성된 코드는 **별도 리팩토링 PR을 두지 않고** 자연스러운 변경 흐름에서 점진적으로 갱신한다.
