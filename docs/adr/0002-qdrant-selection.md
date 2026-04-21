# 0002. Qdrant 벡터 데이터베이스 채택

- **날짜**: 2026-04-20
- **상태**: Accepted

## 배경

AXIS의 RAG 파이프라인은 Dense 벡터(의미 검색)와 Sparse 벡터(키워드 검색)를 결합하는 **하이브리드 검색**이 핵심이다. 특히 한국어 IT 뉴스는 "팔란티어", "에이전트웍스" 같은 고유 명사·신조어가 많아, 순수 Dense 검색만으로는 재현율이 낮다.

또한 3개월 TTL(main 컬렉션)과 12개월 TTL(history 컬렉션) 두 가지 보존 정책을 운영해야 한다.

## 결정

**Qdrant 1.9.x** 를 벡터 데이터베이스로 채택한다. BGE-M3가 생성하는 Dense + Sparse 벡터를 단일 포인트로 저장하고, RRF(Reciprocal Rank Fusion)로 결합 검색한다.

## 대안

| 대안 | 기각 이유 |
|---|---|
| Chroma | 하이브리드 검색 미지원(별도 BM25 라이브러리 필요). 프로덕션 안정성 미검증 |
| Pinecone | 하이브리드 검색 지원하나 유료 클라우드 서비스. 데이터 외부 전송 우려 |
| Weaviate | 하이브리드 검색 지원, 그러나 BGE-M3 Sparse 벡터(SPLADE 형식) 직접 수용 복잡 |
| pgvector | Dense 전용, Sparse·RRF 미지원 |

## 근거

- **하이브리드 검색 네이티브**: Dense + Sparse 벡터를 단일 API로 처리, RRF 내장
- **BGE-M3 Sparse 형식 직접 수용**: SPLADE 형식 Sparse 벡터를 Named Vectors로 저장 가능
- **TTL 설정 지원**: 컬렉션별 payload TTL 또는 점수 기반 자동 삭제
- **오픈소스 + 로컬 운영**: Docker Compose로 완전한 로컬 실행 가능. 데이터 외부 전송 없음
- **Rust 기반 고성능**: 10만 건 벡터 검색 p99 < 50ms (내부 PoC 측정)

## 영향

- BGE-M3 임베딩 결과를 Dense (`dense`) + Sparse (`sparse`) Named Vectors로 Qdrant에 저장
- Qdrant 페이로드에 원문 전체 텍스트 저장 금지 — `rdb_id` FK로 PostgreSQL 원문 참조
- axis-ai만 Qdrant에 직접 접근. axis-backend는 Qdrant 직접 쿼리 금지
- 컬렉션 설계: `axis_main` (3개월 TTL), `axis_history` (12개월 TTL)
