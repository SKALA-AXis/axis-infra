#!/usr/bin/env python3
"""CronJob 스케줄이 SKALA 노드 야간 셧다운 창(23:00–07:00 KST)에 걸리는지 검사.

skala-2025 클러스터의 워커 노드는 매일 23:00 KST에 내려가고 07:00 KST에 올라온다.
이 창 안에 스케줄된 CronJob은 포드를 스케줄할 노드가 없어 100% 실패한다.
(증거·결정 배경: docs/adr/0007-cron-night-shutdown-window.md)

규칙:
1. k8s/ 아래 모든 CronJob은 timeZone: Asia/Seoul 을 명시해야 한다.
2. schedule 의 시(hour) 필드가 23,0,1,2,3,4,5,6 과 교집합이 있으면 실패한다.
   (suspend: true 라도 검사 — 나중에 풀릴 때 터지는 것을 방지)

사용: python3 scripts/validate-cron-window.py  (레포 루트에서 실행)
"""

import sys
from pathlib import Path

import yaml

DEAD_HOURS = {23, 0, 1, 2, 3, 4, 5, 6}
REQUIRED_TZ = "Asia/Seoul"


def expand_hour_field(field: str) -> set[int]:
    """cron 시(hour) 필드를 0–23 정수 집합으로 전개."""
    hours: set[int] = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, step_s = part.split("/", 1)
            step = int(step_s)
        if part == "*":
            lo, hi = 0, 23
        elif "-" in part:
            lo_s, hi_s = part.split("-", 1)
            lo, hi = int(lo_s), int(hi_s)
        else:
            lo = hi = int(part)
        hours.update(range(lo, hi + 1, step))
    return hours


def check_file(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        docs = list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError as exc:
        return [f"{path}: YAML 파싱 실패 — {exc}"]

    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "CronJob":
            continue
        spec = doc.get("spec") or {}
        schedule = spec.get("schedule")
        if not schedule:
            continue  # strategic-merge patch 조각 (예: cronjob-harbor-pull.yaml)
        name = (doc.get("metadata") or {}).get("name", "<unnamed>")

        if spec.get("timeZone") != REQUIRED_TZ:
            errors.append(f"{path} [{name}]: timeZone 이 '{REQUIRED_TZ}' 가 아님 — 셧다운 창 검사가 무의미해짐")
            continue

        fields = str(schedule).split()
        if len(fields) != 5:
            errors.append(f"{path} [{name}]: schedule 필드 수가 5가 아님: '{schedule}'")
            continue

        try:
            hours = expand_hour_field(fields[1])
        except ValueError:
            errors.append(f"{path} [{name}]: hour 필드 해석 불가: '{fields[1]}'")
            continue

        overlap = sorted(hours & DEAD_HOURS)
        if overlap:
            errors.append(
                f"{path} [{name}]: schedule '{schedule}' 이 노드 셧다운 창(23:00–07:00 KST)에 걸림 "
                f"(시: {overlap}) — 07:00–22:59 사이로 옮기세요"
            )
    return errors


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    yaml_files = sorted(repo_root.glob("k8s/**/*.yaml"))
    if not yaml_files:
        print("k8s/ 아래 yaml 을 찾지 못함 — 레포 루트에서 실행했는지 확인", file=sys.stderr)
        return 2

    all_errors: list[str] = []
    checked = 0
    for f in yaml_files:
        if "secret" in f.name:  # secret 류는 CronJob 아님 + 내용 미파싱
            continue
        checked += 1
        all_errors.extend(check_file(f))

    if all_errors:
        print(f"❌ CronJob 야간 셧다운 창 위반 {len(all_errors)}건:\n", file=sys.stderr)
        for e in all_errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print(f"✅ {checked}개 yaml 검사 — 모든 CronJob 이 셧다운 창(23:00–07:00 KST) 밖에 스케줄됨")
    return 0


if __name__ == "__main__":
    sys.exit(main())
