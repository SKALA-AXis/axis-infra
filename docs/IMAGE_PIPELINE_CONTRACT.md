# 카드 뉴스 이미지 파이프라인 계약서

> 대상 독자: axis-ai 팀, axis-backend 팀.
> 업데이트: 2026-05-19 KST, V30 최소 DB 스키마 기준.
> 핵심 변경: `article_images` 테이블과 `/api/images/{id}` DB lookup 흐름은 V30에서 제거된다. 카드 이미지 metadata는 `card_news.image_assets` JSONB 배열에 저장한다.

---

## 1. 큰 그림

```text
[axis-ai]
  CrawlAgent
    -> og:image / twitter:image / 본문 첫 img 추출
    -> raw_articles.metadata 또는 raw_article_source_metadata.source_metadata에 원천 후보 보존

  ImageFetchAgent 또는 카드 생성 단계
    -> 이미지 URL, attribution, alt_text, storage metadata 구성
    -> card_news.image_assets JSONB 배열에 저장

[axis-backend]
  CardNewsService
    -> card_news.image_assets[0]에서 대표 이미지 선택
    -> 응답 DTO에 coverImageUrl, imageAttribution, imageAlt 제공
```

V30 이후 `article_images` row는 `legacy_records`에 archive된다. 이미 카드에 붙어 있던 이미지 metadata는 `card_news.image_assets`로 fold된다.

---

## 2. `card_news.image_assets` 계약

`image_assets`는 JSONB array다. 대표 이미지는 배열의 첫 번째 usable asset으로 간주한다.

권장 shape:

```json
[
  {
    "image_url": "https://...",
    "source_url": "https://...",
    "asset_url": "https://...",
    "storage_path": "lg_cns/2026-05/abc123.jpg",
    "content_type": "image/jpeg",
    "width": 1200,
    "height": 675,
    "file_size_bytes": 230000,
    "alt_text": "LG CNS AI data center article image",
    "attribution": "제공: source publisher",
    "license_status": "unknown",
    "fetched_at": "2026-05-19T09:00:00Z",
    "source_url_hash": "sha256..."
  }
]
```

Backend fallback 순서:

```text
image_url -> asset_url -> source_url
```

---

## 3. 파일 저장 규칙

파일을 외부 storage 또는 공유 볼륨에 저장할 경우 경로 규칙은 유지한다.

```text
{IMAGE_STORAGE_PATH}/{peer_id}/{yyyy-mm}/{sha256_of_file}.{ext}

예시:
  /data/images/lg_cns/2026-05/abc123def456.jpg
```

JSON의 `storage_path`에는 상대 경로만 저장한다.

금지 사항:

```text
절대 경로 저장 금지
.. 포함 경로 금지
심볼릭 링크 금지
한글/공백 파일명 금지
```

권장값:

| 항목 | 권장 |
|---|---|
| 최대 파일 크기 | 5 MB |
| 허용 MIME | `image/jpeg`, `image/png`, `image/webp` |
| 최소 해상도 | width >= 300 |
| 대표 비율 | 16:9 우선 |

---

## 4. 저장 예시

```python
from datetime import datetime, timezone
import hashlib
import json
from sqlalchemy import text

APPEND_IMAGE_ASSET = text("""
    UPDATE card_news
    SET image_assets = COALESCE(image_assets, '[]'::jsonb) || CAST(:asset AS jsonb)
    WHERE id = :card_news_id
""")

def append_image_asset(db, card_news_id: str, image_url: str, *, alt_text: str = "", attribution: str = ""):
    asset = {
        "image_url": image_url,
        "source_url": image_url,
        "source_url_hash": hashlib.sha256(image_url.encode()).hexdigest(),
        "alt_text": alt_text,
        "attribution": attribution,
        "license_status": "unknown",
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    }
    db.execute(
        APPEND_IMAGE_ASSET,
        {"card_news_id": card_news_id, "asset": json.dumps([asset], ensure_ascii=False)},
    )
```

---

## 5. 운영 주의사항

1. V30 이후 새 코드는 `article_images`에 INSERT하지 않는다.
2. `/api/images/{id}`에 의존하는 프론트 링크를 만들지 않는다.
3. 이미지 파일 자체는 DB 밖 storage에 두고, DB에는 metadata와 URL/path만 둔다.
4. 기존 이미지 row는 `legacy_records`에서 `source_table = 'article_images'`로 조회할 수 있다.
