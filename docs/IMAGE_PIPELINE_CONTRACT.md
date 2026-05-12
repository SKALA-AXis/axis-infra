# 카드 뉴스 이미지 파이프라인 계약서

> **대상 독자**: axis-ai 팀 (ImageFetchAgent 구현자).
> **목적**: backend·infra 가 이미 합의한 **DB 스키마 + 저장 경로 + 응답 흐름** 을 반영하여 AI 측 코드 변경 시 충돌 0 으로 맞추기 위한 계약.
>
> **변경 이력**
> - 2026-W4: 초안 (이 문서). axis-infra V2 migration + axis-backend `ImageController` 머지 동시 적용.

---

## 1. 큰 그림

```
[axis-ai]
  CrawlAgent     → article HTML 가져올 때 og:image / twitter:image / 본문 첫 <img> 추출
                   → state 또는 raw_articles.metadata 에 image_source_url 임시 저장

  [신규] ImageFetchAgent (EvidenceAgent 통과 후 실행 권장)
                 → 대표 article 의 image_source_url 다운로드
                 → 공유 볼륨에 파일 쓰기  (이 계약 §3)
                 → article_images 테이블에 INSERT  (이 계약 §4)

[axis-backend]  ← 이미 머지됨
  ImageController  GET /api/images/{id}
                 → ArticleImageRepository 로 메타 lookup
                 → 공유 볼륨에서 파일 읽기 (path-traversal 차단)
                 → 이미지 바이너리 + Cache-Control 1년 응답

  CardNewsService → 카드 응답 빌드 시 article_images 를 card_news_id 로 lookup
                   → 응답 DTO 에 image_url=/api/images/{id} · image_attribution · image_alt 첨부
```

---

## 2. 환경변수 (axis-ai pod 가 받아야 함)

| 변수 | 값 (default) | 출처 | 의미 |
|---|---|---|---|
| `IMAGE_STORAGE_PATH` | `/data/images` | docker-compose `axis-images` named volume | 컨테이너 안에서 이미지 파일을 쓸 루트 경로 |

이미 [`axis-infra/docker-compose.yml`](../docker-compose.yml) 의 `ai` 서비스에 `IMAGE_STORAGE_PATH` 가 주입되고 `axis-images` 볼륨이 `/data/images` 로 마운트되어 있다. AI 측 코드는 `os.environ["IMAGE_STORAGE_PATH"]` 로 읽으면 된다.

---

## 3. 파일 저장 규칙 (필수 준수)

### 3.1 경로 형식

```
{IMAGE_STORAGE_PATH}/{peer_id}/{yyyy-mm}/{sha256_of_file}.{ext}

예시:
  /data/images/lg_cns/2026-04/abc123def456...789.jpg
  /data/images/samsung_sds/2026-05/a1b2c3...e9f0.png
```

DB 의 `storage_path` 컬럼에는 **상대 경로** 만 저장:

```
lg_cns/2026-04/abc123def456...789.jpg
```

### 3.2 금지 사항

- 절대 경로 저장 금지 (`/data/images/...` 그대로 DB 에 X)
- `..` 포함 경로 금지 — backend 가 path-traversal 검증으로 400 반환
- 심볼릭 링크 금지
- 파일명에 한글·공백 금지 (URL-safe 문자만)

### 3.3 디렉토리 생성

`os.makedirs(parent_dir, exist_ok=True)` 로 peer_id / yyyy-mm 디렉토리 자동 생성.

### 3.4 동일 파일 중복 방지

- `source_url` 동일하면 다운로드 스킵 (DB 의 `source_url_hash` UNIQUE 가 강제)
- 파일명에 SHA-256(파일 콘텐츠) 사용하므로, 다른 URL 이라도 같은 이미지면 같은 파일 — 추가 다운로드는 발생하나 디스크는 1개만 사용

### 3.5 권장 사이즈/포맷

| 항목 | 권장 |
|---|---|
| 최대 파일 크기 | 5 MB (HEAD content-length 로 사전 확인) |
| 허용 MIME | `image/jpeg`, `image/png`, `image/webp` |
| 최소 해상도 | width ≥ 300 (광고 배너 / 스페이서 차단) |
| 썸네일 (선택) | 별도 entry 로 저장하지 말고 backend 가 향후 on-the-fly resize |

---

## 4. DB INSERT 계약

### 4.1 필수 컬럼 (NOT NULL)

```sql
INSERT INTO article_images (
    source_url,              -- 원본 og:image URL
    source_url_hash,         -- SHA-256(source_url) — UNIQUE 충돌 시 ON CONFLICT DO NOTHING
    storage_path             -- 상대 경로 (§3.1)
) VALUES (...);
```

### 4.2 함께 채워야 할 컬럼 (NOT NULL 아니지만 강력 권장)

| 컬럼 | 이유 |
|---|---|
| `article_id` | backend 가 카드 ↔ article 추적 |
| `cluster_id` | 같은 클러스터 카드끼리 이미지 dedup |
| `card_news_id` | **backend 의 카드 응답 lookup 키** — 비어있으면 카드에 이미지가 안 붙음 |
| `content_type` | backend 가 응답 `Content-Type` 으로 그대로 사용 |
| `width`, `height` | frontend / 이메일 본문 layout 결정 |
| `file_size_bytes` | 모니터링 / quota |
| `image_hash` | 동일 파일 다른 URL 검출 |
| `alt_text` | 접근성 + 이메일 클라이언트가 이미지 차단 시 대체 텍스트 |
| `attribution` | 출처 표기 (예: `"제공: 한경"`) — 카드 푸터에 표시 |
| `license_status` | 기본 `'unknown'`. 사내 정책상 안전하면 `'attributed'` |
| `fetched_at` | 다운로드 완료 시각 (UTC) |

### 4.3 권장 INSERT 패턴 (Python · psycopg2)

```python
import hashlib
from datetime import datetime, timezone
from sqlalchemy import text

INSERT_IMAGE = text("""
    INSERT INTO article_images (
        article_id, cluster_id, card_news_id,
        source_url, source_url_hash,
        storage_path, content_type,
        width, height, file_size_bytes, image_hash,
        alt_text, attribution, license_status,
        fetched_at
    ) VALUES (
        :article_id, :cluster_id, :card_news_id,
        :source_url, :source_url_hash,
        :storage_path, :content_type,
        :width, :height, :file_size_bytes, :image_hash,
        :alt_text, :attribution, :license_status,
        :fetched_at
    )
    ON CONFLICT (source_url_hash) DO NOTHING
    RETURNING id
""")

def insert_article_image(*, article_id, cluster_id, card_news_id,
                          source_url, storage_path, content_type,
                          width, height, file_size_bytes, image_bytes,
                          alt_text, attribution, license_status="unknown"):
    with SessionLocal() as db:
        row = db.execute(INSERT_IMAGE, {
            "article_id":      article_id,
            "cluster_id":      cluster_id,
            "card_news_id":   card_news_id,
            "source_url":      source_url,
            "source_url_hash": hashlib.sha256(source_url.encode()).hexdigest(),
            "storage_path":    storage_path,         # 상대 경로!
            "content_type":    content_type,
            "width":           width,
            "height":          height,
            "file_size_bytes": file_size_bytes,
            "image_hash":      hashlib.sha256(image_bytes).hexdigest(),
            "alt_text":        alt_text,
            "attribution":     attribution,
            "license_status":  license_status,
            "fetched_at":      datetime.now(timezone.utc),
        }).fetchone()
        db.commit()
        return row[0] if row else None
```

### 4.4 1 카드 = 1 이미지 정책

`card_news_id` 별로 이미지가 여러 건 있을 수 있지만, backend 는 `findFirstByCardNewsIdOrderByCreatedAtDesc` 로 **가장 최근 1건만** 사용한다. 즉 같은 카드에 더 좋은 이미지를 발견했으면 새로 INSERT 하면 됨 (덮어쓰기 X, 최신 우선).

---

## 5. 다운로드 시 주의

### 5.1 SSRF 방지

og:image URL 이 attacker controlled 가능. 다운로드 전 검증:

```python
from urllib.parse import urlparse
import ipaddress, socket

def is_safe_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"): return False
    try:
        ip = ipaddress.ip_address(socket.gethostbyname(parsed.hostname))
        if ip.is_private or ip.is_loopback or ip.is_reserved:
            return False
    except (ValueError, socket.gaierror):
        return False
    return True
```

### 5.2 Hot-link 차단 회피

일부 사이트는 Referer 검사. fetch 시 헤더 추가:

```python
requests.get(image_url, headers={
    "User-Agent": "Mozilla/5.0 (compatible; AxisBot/1.0)",
    "Referer": article_url,    # 원 article URL
}, timeout=10, stream=True)
```

### 5.3 Fail-soft

이미지 없거나 다운로드 실패해도 **카드 자체는 살린다**. ImageFetchAgent 의 실패는 EvidenceAgent 의 `pass` 결과에 영향 X.

---

## 6. backend 응답 시점 흐름 (확인용)

AI 가 INSERT 만 정확히 하면 backend 는 자동으로 카드 응답에 이미지 붙임:

```
GET /api/issues/today
  → CardNewsService.toResponse(card)
      → articleImageRepository.findFirstByCardNewsIdOrderByCreatedAtDesc(card.id)
      → 발견 시 응답에 image_url="/api/images/{image.id}" 첨부
```

프론트는 응답의 `image_url` 을 그대로 `<img src>` 에 사용. 이메일 본문도 동일 URL 사용 (외부 ALB 도메인 prefix 만 붙이면 됨).

---

## 7. 체크리스트 (AI 팀 PR 머지 전)

- [ ] `IMAGE_STORAGE_PATH` 환경변수 읽기
- [ ] 디렉토리 자동 생성 (`os.makedirs(..., exist_ok=True)`)
- [ ] `storage_path` 는 상대 경로로 INSERT
- [ ] `source_url_hash` UNIQUE 충돌 시 `ON CONFLICT DO NOTHING`
- [ ] `card_news_id` 채우기 (backend lookup 키)
- [ ] `content_type`, `width`, `height`, `image_hash` 채우기
- [ ] `attribution` 으로 출처 표기 (예: `"제공: <source_name>"`)
- [ ] SSRF 검증 (사내망 IP 차단)
- [ ] 5MB 상한 (HEAD content-length 사전 확인)
- [ ] 다운로드 실패해도 카드 생성은 살림 (fail-soft)
- [ ] 로컬 docker-compose `--profile local` 로 end-to-end 1건 검증

---

## 8. 트러블슈팅

| 증상 | 원인 | 대응 |
|---|---|---|
| backend 가 카드에 이미지 안 붙임 | `card_news_id` 가 NULL 또는 mismatch | INSERT 시 `card_news_id` 채우기 — IssueCardAgent 가 부여한 카드 id 그대로 |
| `GET /api/images/{id}` 가 404 | 파일 부재 / 권한 문제 | 컨테이너에서 `ls /data/images/<storage_path>` 확인. AI 컨테이너에서 mount RW 인지 확인 |
| `GET /api/images/{id}` 가 400 | `storage_path` 가 root 밖을 가리킴 | 절대 경로 또는 `..` 가 들어갔는지 확인. §3.1 형식 따름 |
| INSERT 시 UNIQUE 충돌 | 같은 `source_url` 재크롤링 | `ON CONFLICT DO NOTHING` 으로 무시 — 정상 동작 |
| backend 응답 Content-Type 이 octet-stream | DB 의 `content_type` 이 NULL | INSERT 시 `content_type` 같이 채우기 |

---

## 9. 추후 마이그레이션 (참고)

본 계약은 **로컬 공유 볼륨** 기반이지만, 아래 변화는 미리 알려둠:

- v1 (W6+): 클라우드 스토리지 (S3 / Supabase Storage) 로 전환 검토
- v2: CDN (CloudFront) 도입 시 `storage_url` 컬럼 추가 가능성
- 둘 다 `storage_path` 의 의미는 그대로 유지 — backend 가 prefix 만 바꿔서 흡수

즉 지금 계약대로 작성한 AI 코드는 **stable** — 이후 변경 영향 작음.
