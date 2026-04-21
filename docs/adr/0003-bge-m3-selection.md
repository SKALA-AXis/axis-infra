# 0003. BGE-M3 임베딩 모델 채택

- **날짜**: 2026-04-20
- **상태**: Accepted

## 배경

AXIS의 검색 품질은 임베딩 모델의 한국어 IT 도메인 성능에 직결된다. 골든셋 기준 Hit@5 ≥ 0.80, MRR ≥ 0.65를 달성해야 한다.

주요 고려 요소:
1. 한국어·영어 혼합 IT 뉴스 처리 능력
2. Dense + Sparse 벡터를 단일 모델로 생성 가능 여부
3. 로컬 실행 가능 여부 (API 비용 절감)
4. 라이선스 (상업적 활용 가능 여부)

## 결정

**BGE-M3 (BAAI/bge-m3)** 를 임베딩 모델로, **BGE-reranker-v2-m3** 를 리랭커로 채택한다. `FlagEmbedding` 라이브러리로 단일 모델 호출로 Dense + Sparse 벡터를 동시 생성한다.

## 대안

| 대안 | 기각 이유 |
|---|---|
| OpenAI text-embedding-3-large | Dense 전용. API 비용 상시 발생. 대량 임베딩 시 비용 급증 |
| KoSimCSE | 한국어 특화이나 영어 혼합 처리 약함. Sparse 미지원 |
| multilingual-e5-large | MIT 라이선스, 성능 양호하나 BGE-M3 대비 한국어 IT 도메인 성능 낮음 (내부 PoC) |
| Upstage solar-embedding | 성능 우수하나 유료 API |

## 근거

- **한국어 성능**: MTEB Korean 벤치마크 상위권. IT 뉴스 도메인 PoC에서 Hit@5 0.83 달성
- **Dense + Sparse 원샷**: 단일 모델 호출로 Dense·Sparse·ColBERT 세 가지 벡터 동시 생성
- **MIT 라이선스**: 상업 프로젝트에 제약 없음
- **로컬 실행**: GPU 없이 CPU로도 동작 (배치 처리 시 약 200ms/건)
- **FlagEmbedding 생태계**: BGE-reranker-v2-m3와 동일 라이브러리로 일관된 파이프라인 구성

## 영향

- axis-ai Dockerfile에 `FlagEmbedding>=1.2` 의존성 포함 필수
- 모델 파일 초기 다운로드: ~2GB (컨테이너 첫 실행 시 자동)
- 임베딩 서버 웜업 시간 고려 — `healthcheck`에서 모델 로드 완료 확인 필요
- 배치 임베딩 시 `batch_size=32` 권장 (메모리·속도 균형)
