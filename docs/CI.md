# CI 가이드

AXIS 프로젝트의 GitHub Actions CI 설명입니다.
각 레포에 push하거나 PR을 올릴 때 자동으로 실행됩니다.

---

## 실행 조건

| 이벤트 | 대상 브랜치 |
|---|---|
| push | `main`, `develop` |
| pull_request | `main`, `develop` |
| 수동 실행 (Actions 탭 → Run workflow) | 모든 브랜치 |

---

## 레포별 CI

### axis-backend

**파일**: `.github/workflows/ci.yml`  
**Job 이름**: `Build and Test`

| 단계 | 명령어 | 실패 의미 |
|---|---|---|
| Set up JDK 17 | — | Java 환경 설치 문제 |
| Build | `./gradlew build` | 컴파일 오류 |
| Test | `./gradlew test` | JUnit 테스트 실패 |

---

### axis-ai

**파일**: `.github/workflows/ci.yml`  
**Job 이름**: `Lint, Type Check and Test`

| 단계 | 명령어 | 실패 의미 |
|---|---|---|
| Set up uv | — | Python 패키지 매니저 설치 |
| Install dependencies | `uv sync --all-extras` | 의존성 설치 실패 |
| Format check | `uv run ruff format --check src/` | 코드 포맷 미적용 (`uv run ruff format src/` 로 수정) |
| Lint | `uv run ruff check src/` | 미사용 import, 코드 품질 위반 |
| Type check | `uv run mypy src/` | 타입 오류 |
| Test | `uv run pytest tests/ -v` | pytest 테스트 실패 |

---

### axis-frontend

**파일**: `.github/workflows/ci.yml`  
**Job 이름**: `Type Check, Lint, Test and Build`

| 단계 | 명령어 | 실패 의미 |
|---|---|---|
| Install dependencies | `npm ci` | package-lock.json 불일치 |
| Type check | `npm run type-check` | TypeScript 타입 오류 |
| Lint | `npm run lint` | ESLint 규칙 위반 |
| Test | `npm run test` | Vitest 테스트 실패 |
| Build | `npm run build` | Vite 빌드 실패 |

---

### axis-infra

**파일**: `.github/workflows/validate.yml`  
**Job 이름**: `Validate SQL Schema`, `Validate OpenAPI Specs`, `Notify API Spec Change`

| Job | 내용 | 실패 의미 |
|---|---|---|
| Validate SQL Schema | `db/schema.sql`을 실제 PostgreSQL에 실행 | SQL 문법 오류 |
| Validate OpenAPI Specs | `swagger-cli`로 yaml 파일 검증 | OpenAPI 스펙 형식 오류 |
| Notify API Spec Change | PR에서 api/ 변경 감지 시 코멘트 자동 작성 | (알림 전용, 실패해도 블로킹 아님) |

> `api/openapi.yaml` 또는 `api/ai-internal-api.yaml`이 변경된 PR이면 자동으로 아래 코멘트가 달립니다:
> - axis-frontend: `npx openapi-typescript` 재실행 필요
> - axis-backend: `openapi-generator-cli` 재실행 필요
> - axis-ai: `datamodel-codegen` 재실행 필요

---

## CI 결과 확인 방법

### PR 페이지에서
PR 하단에 각 job의 통과/실패 여부가 표시됩니다.

```
✅ Build and Test — passing
❌ Lint, Type Check and Test — failing
```

### Actions 탭에서
레포 상단 **Actions** 탭 → 실패한 run 클릭 → 실패한 step 클릭 → 로그에서 오류 줄 확인

---

## 실패했을 때 대응

### axis-backend 빌드 실패
```bash
./gradlew build   # 로컬에서 먼저 확인
./gradlew test
```

### axis-ai 포맷 실패
```bash
uv run ruff format src/   # 자동 수정
uv run ruff check src/    # 린트 확인
uv run mypy src/          # 타입 확인
```

### axis-frontend 타입/린트 실패
```bash
npm run type-check   # 타입 오류 확인
npm run lint         # 린트 오류 확인
npm run build        # 빌드 가능 여부 확인
```

### axis-infra SQL/OpenAPI 실패
```bash
# SQL 문법 확인 — 로컬 postgres로 직접 실행해볼 것
psql -U axuser -d axis_test -f db/schema.sql

# OpenAPI 검증
npx @apidevtools/swagger-cli validate api/openapi.yaml
npx @apidevtools/swagger-cli validate api/ai-internal-api.yaml
```

---

## PR 올리기 전 체크리스트

```
axis-backend  □ ./gradlew build test 로컬 통과 확인
axis-ai       □ uv run ruff format src/ 실행 후 커밋
              □ uv run ruff check src/ / mypy src/ 통과 확인
axis-frontend □ npm run type-check && npm run lint && npm run build 통과 확인
axis-infra    □ schema.sql / openapi.yaml 수정 시 팀 공지
```
