# docs/ 문서 지도

> 무엇이 어디의 **정본**인지 한 장으로. (2026-06-12 디렉토리 정리와 함께 신설)

## 정본 선언 (SSoT)

| 영역 | 정본 | 비고 |
|---|---|---|
| 프로젝트 전체 맥락 | [`../CLAUDE.md`](../CLAUDE.md) | 아키텍처·배포·제약·진행 상태 |
| 팀 컨벤션 | [`conventions/CONVENTION.md`](conventions/CONVENTION.md) | Git·PR·DB 마이그레이션 안전 규칙(§15) |
| DB 스키마 | [`../db/schema.sql`](../db/schema.sql) | V40까지 스냅샷 + 이후 동기화. 관계는 [`DB_METADATA.md`](DB_METADATA.md) §Flyway |
| API 계약 | [`../api/openapi.yaml`](../api/openapi.yaml) · [`../api/ai-internal-api.yaml`](../api/ai-internal-api.yaml) | 변경 시 각 레포 codegen 재실행 |
| 기술 결정 | [`adr/`](adr/) | ADR 0001~0007 |
| 노출도 산식 | axis-ai `src/preprocessing/classification.py` | **코드가 정본** (2026-06-12 팀 확정, 0.70/0.30 · high≥0.65) |

## 디렉토리

| 위치 | 내용 |
|---|---|
| `adr/` | Architecture Decision Records |
| `conventions/` | 컨벤션 정본 + 기능요구사항정의서 (`_archived/`: 구판 표준정의서 등) |
| `meetings/` · `sprints/` | 회의록 · 스프린트/회고 |
| `structure-tasks/` | 구조 개선 작업 추적 (레포별 + agent-split-design) |
| `design/` | 설계 문서 |
| `admin/` | 관리자 대시보드 설계 (`admin_page.md`가 entry) |
| `db-snapshot/` | DB 스냅샷 |
| `deliverables/` | 과제 제출물 (설계서 xlsx, 질의 회신 PDF) |
| `_archived/` | 탐색 단계 산출물 (현행 의사결정에 미사용) |

## 루트 문서 (주제별)

**운영·배포**: [`ci-cd-plan.md`](ci-cd-plan.md)(GitOps 정본) · [`CI.md`](CI.md) · [`IMAGE_PIPELINE_CONTRACT.md`](IMAGE_PIPELINE_CONTRACT.md) · [`HANDOVER.md`](HANDOVER.md) · [`INFRA_KNOWLEDGE_BASE.md`](INFRA_KNOWLEDGE_BASE.md) · [`OPERATOR_MANUAL_REVIEW.md`](OPERATOR_MANUAL_REVIEW.md) · [`OBSERVABILITY_LANGFUSE.md`](OBSERVABILITY_LANGFUSE.md)

**아키텍처·데이터**: [`SYSTEM_ARCHITECTURE.md`](SYSTEM_ARCHITECTURE.md) · [`DB_METADATA.md`](DB_METADATA.md) · [`API_SURFACE.md`](API_SURFACE.md) · [`AUDIT_LOG.md`](AUDIT_LOG.md) · [`SES_INTEGRATION.md`](SES_INTEGRATION.md)

**계획(현행)**: [`PROJECT_STRUCTURE_PLAN.md`](PROJECT_STRUCTURE_PLAN.md) · [`INFRASTRUCTURE_PLAN.md`](INFRASTRUCTURE_PLAN.md) · [`K8S_PLAN.md`](K8S_PLAN.md)
