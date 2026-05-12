# 0006. Flyway 도입 및 Postgres 마이그레이션 운영 표준

- **날짜**: 2026-04-28
- **상태**: Accepted
- **선행 결정**: ADR-0005 (이중 저장소), 매니지드 SaaS DB 검토

> **갱신 노트 (2026-05-12)**: 본 ADR 의 기반 가정이었던 *Supabase Managed Postgres + Qdrant Cloud* 는 이후 폐기되고 **SKALA EKS 의 in-cluster Postgres + Qdrant (5Gi gp3 PVC 각각)** 로 전환되었음. Flyway 자동화 결정 자체는 그대로 유효 — Postgres 는 Postgres 이고, JPA + `org.flywaydb:flyway-database-postgresql` 의존성도 동일하게 동작. 본문은 history 보존을 위해 그대로 두되, `Supabase` 라는 단어는 모두 `in-cluster Postgres` 로 읽으면 됨.

## 배경

PostgreSQL을 Supabase Managed로 옮긴 직후, 스키마 변경을 어떻게 운영할지 결정이 필요하다.

지금까지의 운영:
- `axis-infra/db/schema.sql` 이 Single Source of Truth.
- 스키마 변경은 PR로 schema.sql만 수정하고, 사람이 Supabase SQL editor에서 수동 적용.
- JPA `ddl-auto: validate` 만으로 부팅 시 스키마 미일치를 차단.

문제점:
- 누가 언제 어떤 변경을 적용했는지 DB에 기록되지 않는다.
- 환경(local 개발자 컴퓨터, CI, prod)별로 적용 누락이 발생할 수 있다.
- 수동 SQL editor 적용은 트랜잭션 보장이 약하다 (실수로 일부만 실행될 위험).

## 결정

**SpringBoot 부팅 시 자동 적용되는 Flyway 마이그레이션을 도입한다.**

### 의존성·설정

- `axis-backend/build.gradle` — `flyway-core` + `flyway-database-postgresql` 추가 (Spring Boot 3.3 + Flyway 10 호환).
- `axis-backend/src/main/resources/application.yml` — `spring.flyway.enabled: true`, `baseline-on-migrate: true`, `out-of-order: false`.
- 마이그레이션 파일 위치: `axis-backend/src/main/resources/db/migration/`
- 명명 규칙: `V{N}__{snake_case_설명}.sql` (예: `V1__init_schema.sql`, `V2__add_evidence_chain_index.sql`)

### 단일 출처 정책

- `axis-infra/db/schema.sql` 은 **현재 스키마의 스냅샷** 으로 계속 유지한다 (Single Source of Truth 역할은 마이그레이션 파일 누적분으로 이동).
- 새 스키마 변경 시 워크플로우:
  1. `axis-backend/.../db/migration/V{N}__설명.sql` 작성 (PR).
  2. `axis-infra/db/schema.sql` 도 동시 업데이트 (Supabase 신규 환경 부트스트랩용 스냅샷).
  3. PR 리뷰 통과 → SpringBoot가 자동으로 Supabase에 V{N} 적용.

### baseline 처리

- Supabase에 schema.sql이 이미 적용된 상태(또는 일부 테이블이 존재하는 상태)에서 백엔드를 처음 부팅할 때를 대비해 `baseline-on-migrate: true` + `baseline-version: 0` 으로 설정.
- 처음 부팅 시 Flyway는 `flyway_schema_history` 테이블을 생성하고 V0을 baseline으로 기록한 뒤 V1부터 순차 실행.
- `IF NOT EXISTS` 가 명시된 V1__init_schema.sql 은 멱등하게 동작하므로 schema.sql이 이미 적용돼 있어도 안전.

### 절대 규칙

- **이미 적용된 V 파일은 수정 금지.** Flyway 체크섬이 어긋나면 부팅 실패. 변경이 필요하면 새 V{N+1} 파일을 만든다.
- `out-of-order: false` 로 V 번호 단조 증가만 허용 — 두 명이 동시에 같은 번호로 PR을 올리면 머지 시점에 한쪽이 번호를 올린다.
- DDL은 한 마이그레이션 안에서 트랜잭션 단위로 묶을 수 있도록 작성. Postgres는 대부분의 DDL을 트랜잭션 안에서 처리하지만, `CREATE INDEX CONCURRENTLY` 등 일부는 트랜잭션 외부 실행이 필요하므로 별도 파일로 분리.
- prod 적용 전, 새 V 파일은 반드시 staging Supabase 인스턴스에서 1회 검증.

## 결과

- 스키마 이력이 `flyway_schema_history` 테이블에 사용자·체크섬·소요시간과 함께 누적된다.
- local/CI/prod 어디서 부팅하든 동일한 스키마 상태가 보장된다.
- 스키마 변경이 코드 리뷰 대상에 포함된다 (V 파일 = 코드).

## 트레이드오프

- V 파일 immutable 원칙을 어기면 모든 환경에서 부팅 실패 → 작은 오타도 V{N+1} 패치로 처리해야 한다 (이는 의도된 안전장치).
- Supabase는 `flyway_schema_history` 테이블을 매니지드 백업에 포함하므로 별도 백업 불필요.
- 의존성 추가로 backend jar 크기 증가 (~1MB) — 무시 가능 수준.

## 후속 작업

- `V2__` 부터 시작될 다음 변경 후보: evidence_chain 컬럼 분리, peer_financials 인덱스 추가.
- 마이그레이션 파일 작성 가이드를 `axis-infra/docs/conventions/CONVENTION.md` 에 추가.
