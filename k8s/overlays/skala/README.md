# SKALA EKS overlay — class3-team13

> 대상: SKALA 가 제공한 AWS EKS 클러스터 (`skala-2025`)
> namespace: `skala3-finalproj-class3-team13`
> 레지스트리: Harbor (`amdp-registry.skala-ai.com` / project `skala26a-ai3`)
> DB: **in-namespace Postgres + Qdrant** (cluster 공용이 아니라 본인 namespace 안에 직접 배포 — 매니저 가이드)

`overlays/local` (kind 로컬) 의 SKALA 운영 버전.

---

## 1. 사전 확인 (한 번만)

| 항목 | 명령 | 기대 결과 |
|---|---|---|
| kubectl context | `kubectl config current-context` | `arn:aws:eks:ap-northeast-2:...:cluster/skala-2025` |
| namespace 권한 | `kubectl auth can-i create deployment -n skala3-finalproj-class3-team13` | `yes` |
| Postgres 접근 | `kubectl get svc -n postgres` | `postgres-1-postgresql` 보임 |
| Qdrant 접근 | `kubectl get svc -n qdrant` | `qdrant` 보임 |
| Harbor 접근 | `curl -sI https://amdp-registry.skala-ai.com/v2/` | `HTTP/2 401` (인증 필요 — 정상) |

---

## 2. 매니저로부터 받아야 할 것

1. **Harbor 자격증명** — `HARBOR_USER` / `HARBOR_PASS`
2. **Postgres admin 비밀번호** + **DB 격리 정책**
   - team13 전용 db/user 가 이미 만들어져 있는가? 또는 admin 권한으로 직접 생성?
3. **클러스터 wipe 정책** — 정기 리셋 주기 (백업 자동화 결정용)
4. **OPENAI_API_KEY** — 본인 키 또는 SKALA 제공
5. **Ingress 정책** — ALB Controller 사용 가능한지, 또는 NodePort/LoadBalancer

---

## 3. Pre-flight 셋업 (한 번만)

```bash
# (A) Harbor 로그인 — 로컬 docker 에 자격증명 저장
docker login amdp-registry.skala-ai.com

# (B) Postgres 격리 (admin 권한 필요. 매니저 또는 본인이 admin 인 경우)
PGADMIN_HOST="postgres-1-postgresql.postgres.svc.cluster.local"
# 외부 접근은 LB:
# PGADMIN_HOST="a549d1be548d945fbaa811f46bd3b3dd-586480945.ap-northeast-2.elb.amazonaws.com"

kubectl run pg-admin --rm -it --image=postgres:16-alpine -n skala3-finalproj-class3-team13 -- \
  psql "postgresql://postgres:<admin-pw>@$PGADMIN_HOST:5432/postgres"

# psql 안에서:
CREATE DATABASE axis_team13;
CREATE USER axis_team13 WITH PASSWORD '<강한_비밀번호>';
GRANT ALL ON DATABASE axis_team13 TO axis_team13;
\c axis_team13
GRANT ALL ON SCHEMA public TO axis_team13;
\q

# (C) Qdrant collection (cluster 내부, Pod 에서 호출)
kubectl run qdrant-init --rm -it --image=curlimages/curl:8.5.0 \
  -n skala3-finalproj-class3-team13 -- \
  curl -X PUT http://qdrant.qdrant.svc.cluster.local:6333/collections/team13_articles \
       -H 'content-type: application/json' \
       -d '{"vectors":{"size":1024,"distance":"Cosine"}}'

# (D) secret.skala.yaml 작성 — .env 에서 자동 생성 (단일 .env 사용)
cp .env.example .env             # 또는 기존 .env 사용
$EDITOR .env                      # POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD 채움
                                  # OPENAI_API_KEY / NAVER_* / DART_API_KEY 도 채움
make skala-secret                 # → k8s/overlays/skala/secret.skala.yaml 자동 생성

# (E) Harbor pull secret 생성
HARBOR_USER=team13 HARBOR_PASS='<password>' make skala-pull-secret
```

---

## 4. Flyway 마이그레이션 — axis-backend 가 startup 시 자동 적용

별도 명령 불필요. `axis-backend/build.gradle` 에 `flyway-core` + `flyway-database-postgresql` 의존성이 있어 SpringBoot 가 시작 시 자동으로 V1~V8 (`axis-backend/src/main/resources/db/migration/`) 을 적용함.

검증 — backend pod 로그에서 마이그레이션 결과 확인:

```bash
kubectl logs deployment/axis-backend -n skala3-finalproj-class3-team13 | grep -i flyway
# 기대 출력 예:
#   Successfully applied 8 migrations to schema "public"
#   Schema-validation: success
```

만약 backend pod 가 CrashLoopBackOff 면 마이그레이션 실패 가능성 — `kubectl describe pod` + 위 logs 확인.

수동으로 별도 실행하고 싶으면 (드물게 필요):

```bash
kubectl port-forward -n skala3-finalproj-class3-team13 svc/postgres 5432:5432 &
DB_PW=$(grep ^POSTGRES_PASSWORD= .env | cut -d= -f2-)
flyway -url=jdbc:postgresql://localhost:5432/axis -user=axuser -password="$DB_PW" \
       -locations=filesystem:../axis-backend/src/main/resources/db/migration info
unset DB_PW
```

로컬 frontend 에서 배포된 backend 인증 API를 바로 붙여 테스트하려면 backend service 도 port-forward 한다:

```bash
kubectl port-forward -n skala3-finalproj-class3-team13 svc/axis-backend 8080:8080 &
# 또는 axis-infra repo root:
make pf-backend
# background port-forward 가 IDE/Codex 세션에서 정리되면:
make pf-backend-fg
```

이 상태에서 `axis-frontend`의 Vite dev server를 띄우면 `/api/*` 요청이 `localhost:8080`의 cluster backend로 전달된다.

회원가입 이메일 인증 링크는 frontend route 를 열어야 하므로, 이 로컬 프론트 테스트 모드에서는 `AXIS_APP_BASE_URL=http://localhost:3100`으로 둔다. 공인 도메인/TLS가 준비되면 실제 프론트 URL로 바꾼다.

---

## 5. 일반 배포 흐름

```bash
# (1) 이미지 빌드 (현재 git SHA 기반 자동 태깅)
make skala-build

# (2) Harbor push (~5분, 첫 push 시 더 길 수 있음)
make skala-push

# (3) kustomization.yaml 의 newTag 를 현재 git SHA 로 치환
make skala-tag

# (4) overlay 적용
make skala-apply

# (5) Pod 가 다 Running 될 때까지 watch
kubectl get pods -n skala3-finalproj-class3-team13 -w

# (6) 상태 확인
make skala-status
make skala-logs
```

---

## 6. 백업 자동화

`cronjob-pg-dump.yaml` 이 매일 KST 02:00 (UTC 17:00) 에 실행:
- `pg_dump` → `axis-images` PVC 의 `/data/backups/`
- 14일 retention

**첫 배치 (이전 데이터 백필) 끝난 직후 수동으로 한 번 실행 권장**:

```bash
kubectl create job --from=cronjob/axis-pg-dump axis-pg-dump-manual \
  -n skala3-finalproj-class3-team13
```

S3 export 는 추후 추가 (sealed-secret 으로 AWS 자격증명 주입 후).

---

## 7. 트러블슈팅

| 증상 | 원인 / 해결 |
|---|---|
| `ImagePullBackOff` | Harbor pull secret 누락 또는 잘못. `kubectl describe pod` → `Events` 확인 |
| `CrashLoopBackOff (ai)` | OPENAI_API_KEY 누락 / DB 연결 실패. `kubectl logs` 확인 |
| `pending` PVC | StorageClass 가 `gp2` 또는 `gp3` 로 EKS 기본 있어야. PVC manifest 확인 |
| `permission denied` (DB) | psql 직접 접속해서 GRANT 누락 확인. 또는 `axis_team13` user 가 안 생성됨 |
| Ingress 안 됨 | ALB Controller 미설치 가능성. 매니저 확인 후 NodePort/LoadBalancer 로 fallback |

---

## 8. 변수 정리 (Makefile 과 동기)

| 변수 | 값 |
|---|---|
| `SKALA_NS` | `skala3-finalproj-class3-team13` |
| `HARBOR_HOST` | `amdp-registry.skala-ai.com` |
| `HARBOR_PROJECT` | `skala26a-ai3` |
| `SKALA_TAG` | `$(git rev-parse --short HEAD)` (CI 가 치환) |
| Postgres in-cluster DNS | `postgres-1-postgresql.postgres.svc.cluster.local:5432` |
| Postgres LB | `a549d1be548d945fbaa811f46bd3b3dd-586480945.ap-northeast-2.elb.amazonaws.com:5432` |
| Qdrant in-cluster DNS | `qdrant.qdrant.svc.cluster.local:6333` |
