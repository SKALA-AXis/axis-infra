# 0005. PostgreSQL + Qdrant 이중 저장소 설계

- **날짜**: 2026-04-20
- **상태**: Accepted

## 배경

AXIS는 하루 약 500건의 기사를 수집하지만, 실제로 이슈 카드 생성에 사용되는 기사는 필터링 후 약 50건(10%)이다. 나머지 450건도 감사 추적·재처리 가능성을 위해 보존이 필요하다.

단일 저장소로 처리하는 방안을 검토했다.

- **Qdrant만 사용**: 원문 전량 저장 시 텍스트 페이로드 비용 급증. 재처리·감사 추적 어려움
- **PostgreSQL만 사용**: 벡터 검색 불가. pgvector는 Sparse·하이브리드 미지원

## 결정

**PostgreSQL(원문 아카이브)** 과 **Qdrant(벡터 검색엔진)** 를 역할 분리하여 이중 저장소로 운영한다.

| 저장소 | 저장 대상 | 보존 기간 | 역할 |
|---|---|---|---|
| PostgreSQL | 수집 원문 전량 + 메타데이터 | 6개월 | 원문 보존·감사 추적·재처리 |
| Qdrant `axis_main` | Gate 통과 대표 기사 벡터 | 3개월 TTL | 최근 검색 |
| Qdrant `axis_history` | Gate 통과 기사 벡터 | 12개월 TTL | 히스토리 분석 |

**Qdrant 포인트 구조:**
```json
{
  "id": "<uuid>",
  "vectors": {
    "dense": [...],
    "sparse": { "indices": [...], "values": [...] }
  },
  "payload": {
    "rdb_id": 12345,
    "peer_id": "samsung_sds",
    "event_type": "tech",
    "importance": "urgent",
    "pub_date": "2026-04-20",
    "cluster_id": 42,
    "title": "...",
    "summary": "..."
  }
}
```

> **원칙**: Qdrant 페이로드에 원문 전체 텍스트 저장 금지.

## 대안

| 대안 | 기각 이유 |
|---|---|
| Qdrant 단일 저장소 + 원문 페이로드 저장 | 텍스트 저장 시 메모리/디스크 비용 급증. 감사·재처리 불리 |
| PostgreSQL + pgvector | Sparse 벡터·RRF 미지원. 대량 벡터 검색 성능 한계 |
| Elasticsearch | BM25 지원, Dense 검색은 별도 플러그인 필요. 운영 복잡도 높음 |

## 근거

- **책임 분리**: PostgreSQL은 원문 보존의 단일 진실 공급원. Qdrant는 검색 성능에 집중
- **재처리 가능성**: Qdrant 벡터가 만료되어도 PostgreSQL 원문으로 재임베딩 가능
- **삽입 비율 최적화**: 500건 수집 → 50건만 Qdrant 삽입 (Gate 통과 기준)
- **비용 절감**: Qdrant에 텍스트 저장 시 메모리 3~5배 증가 예상 → 페이로드는 메타데이터만

## 영향

- `raw_articles.qdrant_vector_id` — PostgreSQL ↔ Qdrant 연결 컬럼
- `raw_articles.is_representative` — 대표 기사(Qdrant 적재 대상) 플래그
- Qdrant 검색 결과 반환 시 `rdb_id`로 PostgreSQL 원문 조회 필요
- axis-ai만 Qdrant에 직접 접근. axis-backend는 axis-ai를 통해 간접 검색
