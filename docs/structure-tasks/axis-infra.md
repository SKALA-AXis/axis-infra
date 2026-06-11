# axis-infra 구조 작업 목록

> 상위 계획: [PROJECT_STRUCTURE_PLAN.md](../PROJECT_STRUCTURE_PLAN.md) · 담당: 인프라(본인)
> 현 상태 4개 레포 중 최상 (base/overlay 분리 우수, compose↔k8s 불일치 0건). 작업은 문서 거버넌스와 위생 중심.

## Phase 0 — 위생 (즉시, ~6/12)

- [ ] `api/openapi copy.yaml` 삭제 (131KB, 5/18 시점 사본 — 정본은 openapi.yaml)
- [ ] 로컬 잔존물 삭제: `k8s/overlays/skala/secret.skala 2.yaml`, `.env.skala.tmp.bak` (※ 둘 다 **git 미추적** — 보안 사고 아님, 로컬 위생)
- [ ] `.gitignore`에 macOS 복사본 패턴 보강: `* [0-9].yaml`, `* [0-9].md`
- [ ] untracked 문서 처분: `docs/AI_AGENT_DESIGN.md`, `docs/AXIS_DIFFERENTIATION_FEASIBILITY.md`, `docs/admin_page.md`, 한글명 PDF → 커밋 or `docs/_archived/`
- [ ] (경미) `cronjob-failure-notifier.yaml` 내부 보조 리소스(Role/RoleBinding/SA/ConfigMap = `axis-cron-notifier`)와 CronJob(`axis-cron-failure-notifier`) 네이밍 통일 — k8s 변경이므로 PR (※ CronJob명은 파일명과 일치, 1차 분석의 "파일명 불일치" 주장은 오류)

## Phase 1 — 문서 거버넌스 (~6/20)

- [ ] **문서 SSoT 선언**:
  - [ ] `docs/conventions/CONVENTION.md` = 컨벤션 단일 정본 선언
  - [ ] `AXIS_개발표준정의서_infra_v1.0.md`(80% 중복), `AXIS_개발계획2.md`, `AXIS_개발계획_v3.md`, `*.docx` → `docs/conventions/_archived/` 이동
  - [ ] `AGENTS.md` → "CLAUDE.md 참조" 3줄 포인터로 축소
  - [ ] README에 "문서 지도" 절 추가 (무엇이 어디의 정본인지)
- [ ] **CLAUDE.md 현행화**: 노출도 산식·섹터 taxonomy 정본 확정(ai 코드 구현값 대조 + 팀 확인) 후 ai CLAUDE.md와 통일, LangGraph 버전 표기 정리
- [ ] **schema.sql ↔ Flyway 동기화 프로세스 문서화** (`docs/DB_METADATA.md`): V40까지 스냅샷, V41+는 backend Flyway가 진실, 마일스톤마다 `pg_dump --schema-only` 재덤프
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
- [ ] 서비스 3레포 Trivy PR: backend#64 / ai#124(머지됨) / frontend#77 — 잔여분 머지 확인
- [x] Harbor retention **설정 완료** (6/11): artifact 최근 10개 + develop/buildcache 각 3개, 매일 스케줄. 자체 cleanup 워크플로 폐기 확정
  - ⚠️ **롤백 창 주의**: 보존 10개 = 최근 ~10회 배포분. 그보다 오래된 커밋으로 `git revert` 롤백 시 해당 이미지가 이미 purge 됐을 수 있음 → ImagePullBackOff. 그 경우 해당 커밋에서 `gh workflow run build-and-push.yml --ref <sha>` 로 재빌드 후 롤백. 옛 태그 404 는 이제 **정상 동작**

## Phase 3 — 가드 자동화 (발표 후, 서비스 레포와 병행)

- [ ] pre-commit 위생 훅 패키지: 복사본 패턴(` [0-9].`)·`bin/`·`*.egg-info` 차단 — 4레포 공통 배포
- [ ] CI 파일 비대화 경고(soft 1,500줄) — 서비스 3레포
- [ ] Trivy report-only → 노이즈 파악 후 CRITICAL 게이트 승격
