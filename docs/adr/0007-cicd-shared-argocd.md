# 0007. CI/CD GitOps — 공용 SKALA ArgoCD 사용

- **날짜**: 2026-05-12
- **상태**: Accepted
- **선행 결정**: ADR-0006 (Flyway), v6 의 자체 ArgoCD pivot (폐기됨)

## 배경

SKALA EKS 운영 배포를 *수동 매니페스트 apply* → *GitOps 자동화* 로 전환할 필요. `git push` 하나로 cluster 배포 + rollback 가능해야.

## 시도 한 path

### Path 1 — GitHub Actions only (`make skala-build skala-push skala-apply`)
- service repo push → GH Actions 가 build + push + cluster apply 모두 수행
- 단점: cluster credentials 가 GH Actions Secrets 에 노출, rollback = 별도 commit + replay
- 폐기

### Path 2 — 공용 `skala-argocd` 시도 (v2)
- cluster 의 매니저 운영 ArgoCD (HA × 3, 외부 ingress `argocd.skala25a.project.skala-ai.com`)
- 시도 시 cluster cache 빌드 fail — `tasks.tekton.dev` / `pipelines.tekton.dev` 의 conversion webhook (`tekton-pipelines-webhook` in `tekton-pipelines` ns) 호출 100% fail (svc + ns 모두 cluster 에 미존재, 480일 dead)
- ArgoCD 의 all-or-nothing cluster cache 정책 → 모든 Application sync 차단
- 일시 폐기

### Path 3 — 자체 ArgoCD pivot (v6)
- helm release `axis-argocd` 를 team13 ns 에 namespace-scoped install
- `resource.exclusions` 에 Tekton 명시 제외 → cluster cache fail 회피
- 동작 검증 통과 (P5 E2E + P6 rollback drill 23초 자동 복원)
- 단점: ResourceQuota services 10/10 압박, admin pw / helm upgrade SSA 충돌 / ApplicationSet pod 강제 떠있음 등 관리 부담

### Path 4 — Tekton CRD cleanup 후 공용 ArgoCD 복귀 (v7, **결정**)
- 매니저가 cluster 의 좀비 Tekton CRD 19개 cleanup (우리가 stuck 된 2개 finalizer 강제 제거)
- cluster cache 빌드 정상화 → 공용 `skala-argocd` 의 모든 Application sync 가능
- 자체 ArgoCD 폐기 (helm uninstall) — k8s/argocd-self/ 의 values.yaml 만 비상용 보존

## 결정

**공용 `skala-argocd` 를 운영 CD 도구로 사용**.

### 흐름

```
service repo (axis-ai/backend/frontend) develop push
  → GitHub Actions: ci.yml 통과 → build-and-push.yml
  → Harbor push (:SHA + :develop + :buildcache)
  → axis-infra develop 에 "deploy: SVC → SHA" auto-commit (kustomize edit set image)
  → 공용 ArgoCD (3분 polling) 변경 감지
  → kustomize build + ServerSideApply
  → Pod rollout
```

### 관리 책임 분리

| 영역 | 책임 |
|---|---|
| ArgoCD 설치 / upgrade / admin pw | 매니저 (cluster admin) |
| argocd-cm 의 cluster-wide 설정 (resource.exclusions 등) | 매니저 |
| ingress / TLS cert | 매니저 |
| Application CR + repo Secret 의 박기 | 우리 (team13) |
| repo 의 GitHub PAT 회전 (90일) | 우리 |

### Rollback 검증

P6 drill: 직전 deploy commit (`5a47f11 deploy: axis-frontend → dfeeb1b`) 을 `git revert` push → ArgoCD 23초 만에 이전 SHA (`3501567`) 로 자동 복원 + frontend pod rolling restart.

### 위험과 완화

- **Tekton CRD 재발** — 매니저가 다시 install 안 한다는 가정. 만약 발생 시 `k8s/argocd-self/values.yaml` 의 `resource.exclusions` 패턴으로 자체 ArgoCD 비상 부팅.
- **공용 ArgoCD 의 cluster-wide 영향** — `argocd-cm` 수정은 매니저 영역. 우리는 Application + Secret 만.
- **자동 commit 의 git history 오염** — `deploy: ...` commit 이 develop 에 쏟아짐. P8 에서 squash 또는 gitops 브랜치 분리 검토.

## 폐기된 옵션

- 자체 ArgoCD pivot — Tekton cleanup 후 무용. helm release 는 uninstall, values.yaml 만 비상 spec 으로 보존.
- helm-only deploy — GitOps 시각 효과 + rollback 정통성 측면에서 ArgoCD 가 우월.

## 참조

- [docs/ci-cd-plan.md](../ci-cd-plan.md) (v7 — 완전 spec)
- [docs/HANDOVER.md](../HANDOVER.md) (인계 — PAT 회전 / cluster access)
- [k8s/argocd/](../../k8s/argocd/) — Application + repo Secret
- [k8s/argocd-self/](../../k8s/argocd-self/) — 비상용 자체 ArgoCD spec
