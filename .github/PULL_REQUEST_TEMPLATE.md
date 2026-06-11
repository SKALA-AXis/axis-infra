## 변경 내용

-

## 체크리스트

- [ ] 이 변경으로 낡아지는 문서가 없는가? (CLAUDE.md / README / docs/* — 있으면 같은 PR에서 갱신)
- [ ] k8s 변경 시: `kubectl kustomize` 3종(base/skala/local) 렌더 확인
- [ ] CronJob 추가/변경 시: 07:00–22:59 KST 창 준수 (`scripts/validate-cron-window.py`)
- [ ] API 스펙(`api/*.yaml`) 변경 시: 팀 공지 + 각 레포 타입 재생성 안내
