# axis-infra 구조 작업 목록

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 담당: 인프라(본인)
> 현 상태 4개 레포 중 최상 (base/overlay 분리 우수, compose↔k8s 불일치 0건). 작업은 문서 거버넌스와 위생 중심.

## Phase 0 — 위생 (즉시, ~6/12)

- [x] `api/openapi copy.yaml` 삭제 — 완료 확인 (2026-06-12, api/ 에 정본 2종만 잔존)
- [x] 로컬 잔존물 삭제 (2026-06-12 확인 — 현재 untracked 는 langfuse/helm 팀원 WIP 뿐)
- [x] `.gitignore`에 macOS 복사본 패턴 보강 (2026-06-12, chore PR)
- [x] 문서 처분 완료 (2026-06-12): AI_AGENT_DESIGN·AXIS_DIFFERENTIATION_FEASIBILITY → `_archived/`, admin_page.md → `admin/`, 제출물 xlsx·PDF → `deliverables/`
- [ ] (경미) `cronjob-failure-notifier.yaml` 내부 보조 리소스(Role/RoleBinding/SA/ConfigMap = `axis-cron-notifier`)와 CronJob(`axis-cron-failure-notifier`) 네이밍 통일 — k8s 변경이므로 PR (※ CronJob명은 파일명과 일치, 1차 분석의 "파일명 불일치" 주장은 오류)

## Phase 1 — 문서 거버넌스 (~6/20)

- [x] **문서 SSoT 선언** — `docs/README.md` 문서 지도 신설 (2026-06-12):
  - [x] CONVENTION.md 정본 선언 (docs/README.md)
  - [x] 중복 구판 → `conventions/_archived/` (잔여분 docx 포함, 2026-06-12)
  - [x] `AGENTS.md` → "CLAUDE.md 참조" 포인터로 축소 **완료(2026-06-14 확인, 8줄)**
  - [x] 문서 지도 — `docs/README.md` 신설 + 루트 README 링크 (2026-06-12)
- [~] **CLAUDE.md 현행화**: 노출도 산식 **확정 반영 완료**(2026-06-12 팀 결정=코드 정본 0.70/0.30), 섹터 taxonomy 정본 통일됨. **잔여: LangGraph 버전 표기 정리** (ai/infra/pyproject 불일치)
- [x] **schema.sql ↔ Flyway 동기화 프로세스 문서화 — 완료**: `docs/DB_METADATA.md` V40 스냅샷/V41+ Flyway 진실, V45 현행 반영 + CONVENTION §15 마이그레이션 안전 규칙
- [ ] PR 템플릿에 문서 갱신 체크박스

## 발표 직전 체크리스트 (6/21~22 — 기존 CLAUDE.md 체크리스트 + 추가분)

- [ ] placeholder 최종 확인 — **치환 작업 불필요** (2차 검증: overlay 렌더에 REPLACE 잔존 0건). 확인만: `kubectl kustomize k8s/overlays/skala | grep -c REPLACE` → 0이면 통과
- [ ] `BRIEFING_RECIPIENTS` team13 6명 확정
- [ ] `axis-cron-delivery` suspend 상태 확인
- [ ] Application finalizer 제거 검토
- [ ] **아침 7시 기동 리허설**: 발표 전날 ArgoCD Healthy + 배포 핀 4태그 `docker manifest inspect` 존재 확인 (06-10 Harbor 삭제 사건 재발 대비)

## 진행 중 / 머지 대기 (이 계획과 별개로 이미 떠 있는 것)

- [x] PR #59 — cron 야간 셧다운 창 재배치 + CI 가드 (머지됨, 6/11 아침 검증: 야간 실패 잡 0건)
- [x] PR #60/#62/#63 — 모델 캐시 PVC + initContainer 워밍업 + 4Gi (머지됨, 6/11 아침 워밍업 4초 통과)
- [x] 서비스 3레포 Trivy PR — **3레포 모두 머지 완료(2026-06-14 확인)**: ai#124 / backend / frontend (각 report-only 스캔)
- [x] Harbor retention **설정 완료** (6/11): artifact 최근 10개 + develop/buildcache 각 3개, 매일 스케줄. 자체 cleanup 워크플로 폐기 확정
  - ⚠️ **롤백 창 주의**: 보존 10개 = 최근 ~10회 배포분. 그보다 오래된 커밋으로 `git revert` 롤백 시 해당 이미지가 이미 purge 됐을 수 있음 → ImagePullBackOff. 그 경우 해당 커밋에서 `gh workflow run build-and-push.yml --ref <sha>` 로 재빌드 후 롤백. 옛 태그 404 는 이제 **정상 동작**

## Phase 3 — 가드 자동화 (발표 후, 서비스 레포와 병행)

- [ ] pre-commit 위생 훅 패키지: 복사본 패턴(` [0-9].`)·`bin/`·`*.egg-info` 차단 — 4레포 공통 배포
- [ ] CI 파일 비대화 경고(soft 1,500줄) — 서비스 3레포
- [ ] Trivy report-only → 노이즈 파악 후 CRITICAL 게이트 승격
