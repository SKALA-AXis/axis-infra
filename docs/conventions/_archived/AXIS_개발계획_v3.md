# AXIS 개발 계획서 v3

> **최초 작성**: 2026-04-23 (v1)  
> **방향 전환**: 2026-04-24 (v2 — 1차 현직자 미팅 반영)  
> **목적·검증 체계 재정의**: 2026-04-27 (v3)  
> **W3 종료 / W4 진입 갱신**: 2026-04-27 저녁  
> **작성**: SKALA AI 13조  
> **목표**: 5/20 중간평가까지 핵심 기능 완성  
> **기반 미팅록**: `docs/meetings/현직자미팅-1.pdf` (2026-04-23, SK AX 사업전략팀)

---

## 0. 시스템의 최종 목적

이 시스템은 **"정확한 팩트의 빠른 전달"** 을 통해 **경영진의 의사결정을 보조**하는 것이 최종 목적이다.

### 0.1 5가지 의사결정 보조 영역

| 영역 | 질문 | 시스템 출력 |
|---|---|---|
| 적 분석 | Peer사가 우리보다 기술적·재무적으로 앞서고 있나? | Peer사 재무 시계열 + 기술 동향 추적 |
| 객관화 거울 | 우리 실적이 시장 대비 좋은가, 시장이 좋아서 좋은가? | Peer사 4사 재무 비교 + 시장 평균 |
| 구조 변화 체크 | 시장 자체가 어디로 가고 있나? | 글로벌 동향 + 검색량 트렌드 + MBB 인사이트 |
| 전략 점검 | 우리 전략이 시장 흐름과 맞는가? | 4개 트렌드 섹터별 Peer사 활동 비교 |
| 미래 대응 | 지는 시장이면 다음 전략은? | 약한 신호 감지 (보류) + 채용·특허 추이 |

### 0.2 본질 가치 재정의 (v1 → v3)

| 구분 | v1 | v3 |
|---|---|---|
| 본질 가치 | AI가 시사점·통찰 제공 | **정확한 팩트의 빠른 전달** |
| 최종 목적 | (명시 안 됨) | **경영진 의사결정 보조** |
| AI 역할 | 시사점 자동 생성 | **검증된 팩트 + 재무 연결 (시사점은 옵션)** |
| 차별점 | 5개 축 가중치 분류 | **검증 체인 + 뉴스↔재무 연결 + 도메인 룰** |
| 표시 방식 | "긴급/주목/참고" | **"○○ 동향 + 근거 데이터 + 검증 경로"** |
| 알림 채널 | Slack | **이메일 (1순위) + MS Teams (검토)** |
| 출력 구조 | (불명확) | **3단 계층: 한 줄 → 상세 → 검증** |

미팅에서 받은 핵심 질문: **"시중 AI로 다 할 수 있잖슴 → 차별점?"**  
→ 답: 검증 체인 + 뉴스↔재무 연결 + SI 도메인 지식 + 선제 탐지 (§9 참조)

---

## 1. 미팅에서 확정된 사항

### 1.1 Peer사 범위 (확정)

```
SI 동종업계로 한정 — 4사
├── 삼성SDS  (물류 사업 제외, ITS만 분석)
├── LG CNS
├── 현대오토에버
└── 포스코 DX
```

**제외**: AI 도입 일반 기업, 도메인별 확장 Peer사 (현 시점)

### 1.2 모니터링 트렌드 섹터 (4개 확정) ⭐ v3 변경

v2의 "보안 1개 + 2개 미정"이 v3에서 **4개 모두 확정**됩니다. 현직자가 명시한 "AX가 반드시 챙기는 뉴스"가 직접적 근거입니다.

```
✅ 보안                  (1차 미팅 명시)
✅ AI 기술동향          (AX 반드시 챙기는 뉴스)
✅ 대규모 수주          (AX 반드시 챙기는 뉴스)
✅ SK AX 사업 영역      (제조AX·에이전틱AI·MSP·운영최적화)
```

각 섹터별 키워드 사전 작성은 W4 초반 작업.

### 1.3 모니터링 주기 5종 (확정) ⭐ v3 신규

```
이벤트성 (Event-driven)  ← 선제 탐지 메일 (5분 이내)
일간 (Daily)            ← 매일 오전 8:30 브리핑 [1순위]
주기별 (Periodic)        ← 주간·격주 핵심 이슈 정리
월간 (Monthly)           ← 재무 시계열 업데이트
연간 (Yearly)            ← IR 자료 분기·연간 리포트
```

v1·v2에는 일간·주간·연간만 있었고, **이벤트성·월간**이 v3에서 신규 정의됩니다.

### 1.4 데이터 정책 (확정 + 컨설팅사 신뢰 소스 명시)

```
사용 ✓
├── Tier 1: DART 공시 + KIPRIS 특허 + 공식 뉴스룸
├── Tier 1.5: 컨설팅사 자료  ← v3 신규 명시
│   ├── 맥킨지 (McKinsey)
│   ├── BCG
│   ├── Bain
│   └── Kearney (커니)
├── Tier 2: 공신력 있는 전자 기사 (네이버 뉴스 API, RSS)
├── 채용공고 (정기 공채만, 수시 제외)
├── IR 자료 (분기별)
├── 검색량 데이터 (Google Trends·Naver DataLab)
├── 글로벌 동향 (X·Threads 키워드 추출)
└── 논문 (제목·방향성만)

사용 ✗
├── SNS·블로그·카페 (찌라시)
├── 개인 의견 담긴 사별 SNS
├── 빅카인즈 직접 크롤링 (ToS 위반)
└── 유료 소스
```

**컨설팅사 데이터 처리**:
- 공식 인사이트 페이지 RSS·웹 크롤링
- credibility_score: 0.85 (Tier 1과 Tier 2 중간)
- 시장 구조 변화 분석에 직접 인용 가능

### 1.5 표시 정책 (확정)

```
변경
├── "카드 뉴스"  → "○○ 동향 카드"
├── "긴급/주목"  → 폐기, 근거 데이터로 대체
│   (관련 기사 건수, 신뢰성 있는 출처 노출 빈도)
└── "오늘의 키워드"  → 발표용으로만 유지

추가
├── 시계열성 (3~12개월 흐름) + 이상치 탐지
└── 정보 계층 3단 (§6 참조)
```

### 1.6 우선순위 (확정)

```
1순위: 일간 브리핑       ← 명확하게 하나라도 잘 되도록
2순위: 실시간 모니터링   (정확도 + 속도)
3순위: Peer사 재무·전략 분석
```

---

## 2. 진행 현황 (2026-04-27 W3 종료 시점)

### 2.1 W3·W4 산출물 — v3 분석 파이프라인 골격 완성 ✅

v3 변경(시사점 보류·SC 검증 폐기·증거첨부 도입)을 반영해 axis-ai의 6+1개 에이전트와 v3 ingestion_graph가 모두 동작 단계로 진입했습니다.

```
✅ CrawlerAgent           처리 대기(RAW) ID 조회 어댑터
✅ CredibilityAgent       Gate 2 신뢰도 필터 (임계값 0.5)
✅ DeduplicationAgent     BGE-M3 + Union-Find 클러스터링
✅ ClassificationAgent    v3 4섹터+other 키워드 매칭 + 결정적 노출도 (305줄)
✅ IssueCardAgent         GPT-4o 3줄 요약 + event_type 태깅
✅ EvidenceAgent          v3 증거첨부 4종 부착 (source_links/provenance/financial/mbb)
✅ FinancialLinkerAgent   카드 ↔ peer_financials segment 매칭 (442줄)
✅ IRParserAgent          PyMuPDF IR PDF 텍스트 추출 (170줄)
🟡 NotificationAgent      26줄 스텁 (이메일 모듈로 재구현 필요)
✅ ingestion_graph.py     v3 5+1노드 (crawl→credibility→dedup→classify→card_news→evidence)
🟡 delivery_graph.py      53줄, 노드 모두 TODO + 슬랙 코드 잔존 (W5 재작성)
```

### 2.2 크롤러 v4 — Track A/B 분리 + Peer 4사 확장 완료

```
✅ Track A (1시간) — RSS·뉴스 7종
   네이버뉴스 / Google News RSS / ETnews / ZDNet / Bloter / 연합뉴스
✅ Track B (새벽 2시) — 7종
   DART / KIPRIS / SDS·LGCNS·현대오토에버·포스코DX 뉴스룸
   한경 컨센서스 / 네이버 금융리서치 / 사람인
✅ APScheduler 등록 — Track A/B 자동 실행 (scheduler.py)
✅ run_crawler_once.py    터미널 단독 실행 스크립트 (--track a|b|all)
✅ run_pipeline_once.py   파이프라인 단독 실행 스크립트
```

**Peer 4사** (samsung_sds, lg_cns, hyundai_autoever, posco_dx) 모두 키워드·alias 등록 완료.

### 2.3 인프라·DB·CI 진행

```
✅ axis-infra/db/schema.sql — v3 테이블 추가 (peer_financials, evidence_chain)
✅ axis-infra/CLAUDE.md — v3 동기화 (4섹터+other, 결정적 산식, 4 peer)
✅ docker-compose 정리 (obsolete `version: '3.8'` 제거)
✅ axis-ai CI — feat/** fix/** 푸시 시 자동 실행 + concurrency cancel
✅ axis-infra CI(validate) — 동일 트리거 적용
✅ mypy 30개 에러 → 0 (Protocol 도입 + BeautifulSoup AttributeValueList 처리)
🟡 Flyway — application.yml에 설정만 있고 build.gradle 의존성 없음·V1 마이그 파일 없음
🟡 SecurityConfig — `permitAll()` 상태, JWT 미구현
🔴 .env.example의 SLACK_WEBHOOK_URL 잔존 — 이메일 변수로 교체 필요
```

### 2.4 실데이터 적재 현황 (4/27 18시 기준)

```
raw_articles    204건  (RAW 5 / CLASSIFIED 109 / CLUSTERED_DUPE 90)
card_news     109건  (전건 validation_pass=true ← §2.6 ② 참고)
clusters        ~109   (under-merge 일부 잔존)
```

분포 관찰:

- **Peer 편중**: samsung_sds 압도, posco_dx·hyundai_autoever 저조 → 키워드 보강 필요
- **섹터 분포**: "other" 비율 높음, 키워드 충돌(예 "에이전틱AI"가 ai_tech↔sk_ax_biz 양쪽)로 sk_ax_biz가 거의 안 잡힘
- **오분류 사례**: "삼성SDS·LG CNS 챗GPT 에듀 리셀러" 카드가 `security` 로 분류 (ai_tech가 적절)
- **Hot 카드**: IC-20260427-085 노출도 0.80 high

### 2.5 이전 W3 보고 갱신

v3 5회 실행에서 관찰된 issue들의 현재 상태:

| 이슈 | 4/27 W3 보고 | 4/27 W3 종료 시점 |
|---|---|---|
| urgent 0건 | v3 등급 폐기로 자연 해결 | ✅ 4섹터+노출도로 대체 완료 |
| 클러스터링 under-merge | threshold 0.83 + 제목 가중치 | 🟡 0.90 그대로 — 효과 검증 필요 |
| Classification 컨텍스트 부족 | cluster_size·peer_count 프롬프트 추가 | ✅ 결정적 산식 도입으로 해결 |
| RSS 키워드 매칭 0~1건 | 우선순위 낮음 | ✅ 그대로 (Naver+Google News 커버) |

### 2.6 W3 종료 시점에 새로 발견된 이슈 ⚠️

#### ① 노출도 산식 코드↔문서 불일치

| 항목 | 코드(`classification_agent.py`) | 문서(CLAUDE.md, 본 계획서 §1.4) |
|---|---|---|
| high 임계값 | 0.65 | **0.70** |
| cluster_size 정규화 | 5건 saturation | "7일 최대값 기준" |
| tier1_diversity | 3개 이상 1.0 | "/5" 비례 |

→ **W4 월요일 통일 결정 필요** (보고 가독성·재현성 영향)

#### ② Evidence 검증이 너무 느슨

109/109 카드 모두 `validation_pass=true`. EvidenceAgent의 4종 첨부 검증이 실질적으로 누락 시그널을 잡지 못함. **W4 검증 로직 강화 필요**:

- financial_refs는 peer_financials 데이터 없을 때 자동 missing 처리
- mbb_refs 미구현 단계에서는 기본 missing
- 출처에 없는 수치(금액·%) 자동 Fail 룰 미동작

#### ③ 섹터 키워드 충돌 / dict 순서 의존

`match_sectors()`가 dict 첫 매칭만 채택 → security > ai_tech > large_deal > sk_ax_biz 순서 고착. "AI 보안" 류는 항상 security로, sk_ax_biz는 거의 진입 불가.

- "에이전틱AI"가 `ai_tech`·`sk_ax_biz` 양쪽 등록 → 항상 ai_tech 승
- **W4: 우선순위 명시화 / LLM tie-breaker 도입 검토**

#### ④ peer_financials 데이터 부재

테이블은 있으나 데이터가 없음. FinancialLinkerAgent(442줄)가 코드만 동작 가능 상태. **W4: data/peer_financials/*.json 4사 분기 stub 데이터 적재 + IRParser로 점진적 갱신**

#### ⑤ delivery_graph가 슬랙 잔존

`send_slack_node`로 명명·구현. v3 이메일 전환 결정과 코드 불일치. **W5에 EmailAgent + delivery_graph 전면 재작성**

#### ⑥ 보안 무방비

- Spring `SecurityConfig` `permitAll()` — 모든 API 인증 없음
- Swagger UI 무인증 공개
- `OPENAI_API_KEY` 키 회전·사용량 알림 미설정
- 컨테이너 5432 포트 dev compose에서 호스트 노출 (로컬만이면 OK)
- **W6 데모 전 최소 차단** 필요 (Bearer 정적 토큰이라도)

### 2.7 백엔드·프론트 진행 현황

```
axis-backend
  [x] 골격 (Controller·Repository·Entity·WebClient)
  [x] /api/issues 기본 응답
  [x] application.yml flyway 설정 (의존성 미추가 상태)
  [ ] flyway-core 의존성 추가 + V1__init_schema.sql 베이스라인
  [ ] 이메일 발송 모듈 (SMTP·SendGrid)
  [ ] DongHyangController (이슈→동향 리네임)
  [ ] peer_financials 테이블 Repository (스키마는 axis-infra에 적용됨)
  [ ] 검증 체인 API (/api/evidence/{id})
  [ ] SecurityConfig JWT 적용 (현재 permitAll)

axis-frontend
  [x] 골격 (라우팅·레이아웃·타입 자동생성)
  [x] BriefingPage 기본 화면
  [ ] BriefingPage API 연동
  [ ] 재무 시계열 차트 컴포넌트
  [ ] 정보 계층 3단 카드 컴포넌트
  [ ] 이메일 미리보기 영역
  [ ] 검증 페이지 (3단)
```

### 2.8 팀·DB 운영 결정 사항 (4/27 합의)

```
DB 공유 (5/20 데모 전까지)
├── 스키마: axis-infra/db/schema.sql 깃 커밋 → 슬랙 공지 → 팀원 `down -v && up -d`
├── 시드: 한 명이 pg_dump으로 axis-infra/db/seed.sql 생성 → 깃 공유
├── API 키: 각자 발급 (OPENAI/NAVER/DART/KIPRIS/SARAMIN), .env 절대 커밋 X
└── Sprint A(5/21~)에 Neon staging 도입 검토

Flyway 도입
└── 5/20 이후 Sprint A에서 V1 베이스라인 + V2 마이그 도입
   (그 전에는 schema.sql 직접 수정 + 컨테이너 재생성 OK)

문서 정리
├── docs/conventions/AXIS_개발계획_v1.md → _archived/ 이동 완료
└── 본 v3 문서가 단일 진본
```

---

## 3. 핵심 설계 원칙 (v3 신규)

### 3.1 정보 계층 3단 원칙 ⭐

모든 알림·리포트·대시보드 출력은 **3단 구조 강제**.

```
[1단] 핵심 한 줄 요약 (Headline)        — 5초 읽기
   "LG CNS, 팔란티어 파트너십 → AI 매출 비중 12%→18%"

[2단] 상세 정보 (Detail)                 — 30초 훑기
   3줄 요약 + 재무 변화 차트 + 관련 기사 + 출처 신뢰도

[3단] 검증 정보 (Evidence)               — 검증 모드
   원문 링크 + 판단 근거 + 재무 데이터 출처 + MBB 인용
```

이메일·MS Teams·대시보드·API 응답 모두 동일 구조.

### 3.2 검증 가능성 4가지 자동 첨부 ⭐

리포트·알림에 항상 4가지 검증 정보를 첨부.

```
1. 출처 링크
   - 원문 URL + 백업 텍스트 (링크 깨짐 대비)
   - 동적 URL 차단 시 archive.org 폴백

2. 판단 근거 (Provenance)
   - 어떤 raw_articles ID로 도출했는지
   - 어떤 LLM 프롬프트·모델·실행 시각인지

3. 재무 숫자 출처
   - DART 공시 번호 또는 IR 자료 페이지 번호
   - 추출 시점·추출 메서드

4. 컨설팅사 인용
   - 관련 영역에 대한 MBB·커니 보고서 링크
   - "맥킨지 2026 IT Outlook 참고" 식 자동 매칭
```

### 3.3 임원 시간 = 가장 희소한 자원

모든 UI·알림은 다음 원칙을 따른다.

- **첫 화면 5초 안에 핵심 파악 가능**해야 함
- **자기 관심사 외에는 자동 접힘** (탭·필터 우선)
- **클릭으로만 상세·검증 정보 노출** (정보 과부하 방지)
- **불필요한 색상·아이콘 제거** (정보의 노이즈 줄이기)

---

## 4. 보류 처리 모듈 (v3 일부 수정)

| 모듈 | v2 처리 | v3 처리 | 이유 |
|---|---|---|---|
| `ImplicationAgent` (시사점 생성) | 보류 | **보류 유지** | 시사점은 옵션, 인간 판단 영역 |
| `ValidationAgent` (SC 검증) | 보류 | **역할 전환** ⭐ | SC 검증 → 근거 첨부 검증 |
| `weak_signal_agent.py` | 보류 | **보류 유지** | Sprint A 재투입 검토 |
| 5축 가중치 ClassificationAgent | 수정 | 수정 | 4개 섹터 + 노출도·건수 |
| Slack Webhook 발송 | 변경 | 변경 | 이메일·MS Teams |

> **ValidationAgent 역할 전환** (v3 신규): SC 검증으로 시사점 일관성을 보는 게 아니라, **§3.2의 4가지 검증 정보가 모두 자동 첨부됐는지 확인**하는 모듈로 전환. 누락 시 사람 검토 플래그 부착.

보류된 모듈은 코드를 삭제하지 않고 `src/agents/_deprecated/` 하위로 이동.

---

## 5. 신규 핵심 기능 (v3 완성)

### 5.1 IR·재무 파싱 에이전트 ⭐ 차별화 핵심

```
역할: PDF·HWP IR 자료 파싱 → 재무 지표 구조화 저장
주기: 분기별 자동 (실적 발표일 기준)
산출물:
  - 매출액, 영업이익, 사업부별 매출 비중 (시계열)
  - 채용 증감, R&D 투자, 자본적 지출 변화
  - 사업부 재편·전략 코멘트 추출

기술 스택:
  - PDF 파싱: PyMuPDF + LLM (표·차트 추출)
  - 저장: PostgreSQL `peer_financials` 테이블 (JSONB)
  - 업데이트: DART 공시 감지 시 자동 트리거
```

**삼성SDS 처리 규칙**: 물류 사업 분리, ITS만 추출.

### 5.2 뉴스↔재무 연결 분석 에이전트 ⭐ 차별화 핵심

```
역할: Peer사 뉴스 발생 시 재무 데이터에서 근거·영향 추출
입력: 뉴스 (예: "LG CNS 팔란티어 파트너십")
출력:
  - 왜 했나? → 재무 변화 추적 (예: "AI 매출 비중 12%→18%")
  - 숫자로? → 관련 사업부 매출·인력 추이
  - 비교 → 동종 Peer사 동일 시기 변화

원리: 뉴스 발생일 기준 ±3개월 재무 데이터 컨텍스트 + LLM 분석
```

이게 시사점을 대체하는 차별화 포인트입니다. 시사점 대신 **숫자로 설명되는 팩트**를 제공합니다.

### 5.3 선제적 탐지 메일 알림 ⭐ 시연용

```
시나리오:
  Peer사가 4개 트렌드 섹터(보안·AI·수주·사업영역) 관련 액션
  → 5분 이내 이메일 발송
  → 제목: "[AXIS 선제 탐지] LG CNS, AI 보안 솔루션 인수"
  → 본문: §3.1 3단 구조 적용

폐쇄망 대응:
  - 외부 사이트 직접 접속 불가 환경 고려
  - 이메일 본문에 핵심 정보 포함 (1단·2단)
  - "리포트가 생성되었습니다" 안내
```

### 5.4 글로벌 동향 + 검색량 트렌드

```
글로벌 동향:
  X·Threads 키워드 추출 (재미 요소)
  → 공통 언급 단어 → 해외 뉴스 매핑
  → MBB·커니 인사이트와 자동 매칭

검색량 데이터:
  Google Trends, Naver DataLab API
  → 급증 키워드 → 시장 인사이트
  → 알림에 반영 (시장 변화 신호)
```

### 5.5 시계열 이상치 탐지 (대시보드)

```
3~12개월 흐름 표시
  → 채용·투자·기사 빈도 이상치 감지
  → 갑자기 늘어난 항목 강조
  → 클릭 시 원인 추적 (관련 뉴스·재무 변화)

예: "삼성SDS, 보안 인력 채용 4주간 3배 증가"
```

### 5.6 검증 체인 모듈 ⭐ v3 신규

```
역할: §3.2의 4가지 검증 정보를 모든 산출물에 자동 첨부

저장 구조: PostgreSQL evidence_chain 테이블
  - card_news_id (FK)
  - source_links (JSONB, archive.org 폴백 포함)
  - provenance (raw_articles_ids, llm_model, prompt_version, run_at)
  - financial_refs (DART 공시번호, IR 페이지)
  - mbb_refs (관련 컨설팅사 보고서 자동 추천)

API: GET /api/evidence/{card_news_id}
  → 대시보드 3단 페이지·이메일 본문에서 호출
```

---

## 6. UI/UX 설계 (v3)

### 6.1 임원용 출력 포맷 (3단 구조)

```
[1단] 이메일 양식 — 5초 읽기
─────────────────────────────────────
제목: [AXIS] LG CNS 팔란티어 파트너십, AI 매출 18% 도달
본문 (3줄 이내):
  핵심: LG CNS, 팔란티어 AI 플랫폼 파트너십 체결
  숫자: 분기 AI 매출 비중 12% → 18% 점프
  검증: DART 1Q26 사업보고서 / ZDNet 4/27
  → [상세 보기]

[2단] 대시보드 카드 — 30초 훑기
─────────────────────────────────────
[Peer사 로고 | 동향 섹터 | 발생일 | 출처 신뢰도 ★★★★★]
[헤드라인 한 줄]
[3줄 요약]
[연결 재무 차트 — 인라인]
[관련 기사 N건 + 노출도 점수]

[3단] 상세 페이지 — 검증 모드
─────────────────────────────────────
+ 원문 본문 전체
+ 분석 근거 (어떤 데이터로 무엇을 도출했는지)
+ DART 공시 원본 링크 + IR 페이지 캡처
+ MBB·커니 관련 보고서 자동 추천
+ 사람 검토 플래그 (의심 시 표시)
```

### 6.2 대시보드 메인 화면

```
변경 전 → 변경 후
─────────────────────────────────────
카드 뉴스           → ○○ 동향 카드 (4개 섹터별)
긴급/주목/참고      → 노출도·건수·출처 신뢰도
Peer 증감률 추이    → 주요 동향 기사 (시계열) + 재무 카드
오늘의 키워드       → 유지 (발표용)
선제 탐지 (없음)    → 신규 추가 (메인 노출, 5분 이내 알림 미리보기)
검증 영역 (없음)    → 카드 클릭 시 3단 검증 페이지로
```

### 6.3 탭 재구성

```
유지
├── Dashboard          (메인)
├── Briefings (일간)   (1순위)
├── Peers              (재무·전략 분석)
└── Search (챗봇)

축소·통합
├── Reports 탭         → 챗봇 내부로 통합
└── Articles 탭        → Dashboard 하단 또는 제거

신규
├── Trends             (글로벌 동향, 검색량, MBB 인사이트)
└── Admin              (스케줄러, API 비용, 로그)
```

### 6.4 알림 시스템

```
기존: Slack Webhook
변경:
  1순위: 이메일 (3단 구조 적용)
  2순위: MS Teams (검토)
  제외: Slack (실무 미사용), 문자 (과금 부담)
```

알림 주기:
- **이벤트성 (선제 탐지)**: 즉시 (5분 이내)
- **일간 브리핑**: 매일 오전 8:30
- **주간 리포트**: 월요일 오전 9시 (선택)
- **월간 재무 업데이트**: 매월 1일 (DART 분기 공시 후)
- **연간 리포트**: 별도 트리거

---

## 7. 4주 개발 계획 (4/28 ~ 5/20)

> v1 일정에서 W3 → W4 → W5 → W6로 한 주씩 미뤄 정리.

### 7.1 W4 (4/28~5/4) — 방향 정렬 + 재무 데이터 기반

> 4/27 시점 진척도 표기: ✅완료 / 🟡진행중 / ⏳시작전. **굵은 항목**이 W4 신규.

**전체 (월요일 1일차)**

- ⏳ 미팅록 기반 요구사항 v0.4 업데이트 (4개 섹터 확정 반영)
- ⏳ 보류 모듈 `_deprecated/`로 이동 (Slack 코드는 이메일 모듈 동작 후)
- ⏳ WBS v8.0 재정렬
- 🟡 **신규(4/27)**: 노출도 산식 코드↔문서 통일 (§2.6 ①)
- 🟡 **신규(4/27)**: 섹터 키워드 충돌·우선순위 정리 (§2.6 ③)

**AI Engineer A (박진)**

- 🟡 IR PDF 파싱 PoC — IRParserAgent 170줄 골격 완료, 4사 PDF 입수 경로 미정
- ⏳ hybrid_search.py 시작
- ⏳ reranker.py 시작
- ⏳ **신규(4/27)**: data/peer_financials/*.json 4사 분기 stub 적재 (FinancialLinker 활성화)

**AI Engineer B (심유정)**

- ✅ ClassificationAgent 리팩토링 (4섹터+other + 결정적 노출도) — 305줄
- ✅ 뉴스↔재무 연결 에이전트 PoC — FinancialLinkerAgent 442줄 (PoC 이상 수준)
- ✅ 4개 섹터 키워드 사전 작성 — sector_keywords.py
- ⏳ 골든셋 레이블링 50건 (W4 내)
- 🟡 **신규(4/27)**: Peer 편중 해소 (posco_dx·hyundai_autoever 키워드 보강)

**PM (김가은)**

- ✅ ingestion_graph.py 재설계 (시사점·SC 제외, EvidenceAgent 노드 추가)
- ✅ 신규 에이전트 흐름 정의 (crawl→credibility→dedup→classify→card_news→evidence)
- ✅ 검증 체인 모듈 설계 — EvidenceAgent + evidence_chain 테이블
- 🟡 **신규(4/27)**: Evidence 검증 룰 강화 (§2.6 ②) — 109/109 pass 문제 해결

**Backend Lead (박지원)**

- 🟡 `peer_financials` 테이블 — schema.sql에 추가됨, Repository·JPA Entity 미구현
- 🟡 `evidence_chain` 테이블 — schema.sql에 추가됨, Repository·JPA Entity 미구현
- ⏳ Flyway 도입 — build.gradle 의존성 누락, V1 베이스라인 미작성
- ⏳ 이메일 발송 모듈 (SMTP·SendGrid 검토)
- ⏳ **신규(4/27)**: SecurityConfig — 최소 Bearer 토큰 인증 도입 (5/20 데모 전)

**Frontend (안가은·최종민)**

- ⏳ 용어 변경 (이슈→동향, 긴급/주목 폐기)
- ⏳ Reports 탭 제거, Articles 탭 통합
- ⏳ **3단 카드 컴포넌트 프로토타입**

---

### 7.2 W5 (5/5~5/13) — 핵심 기능 구현

**AI Engineer A (박진)**
- [ ] /search, /gen-search 엔드포인트
- [ ] **IR 파싱 에이전트 본격 구현** (4개 Peer사 분기 자료 적재)
- [ ] MBB·커니 RSS·웹 크롤러 추가 (Tier 1.5)

**AI Engineer B (심유정)**
- [ ] **뉴스↔재무 연결 에이전트 완성**
  - 뉴스 발생 → 관련 사업부 식별 → 재무 데이터 추출 → 변화 분석
- [ ] **선제 탐지 모듈** (4개 섹터 키워드 트리거)
- [ ] 이메일 발송 연동 (UrgentMonitor → 이메일 양식)
- [ ] 골든셋 레이블링 50건 추가 (총 100건 완료)

**PM (김가은)**
- [ ] delivery_graph.py 재설계 (Slack → 이메일)
- [ ] 일간 브리핑 자동 발송 안정화
- [ ] **검증 체인 자동 첨부 모듈 구현**

**Backend Lead (박지원)**
- [ ] CardNewsController → DongHyangController로 변경
- [ ] AiClientService 신규 엔드포인트 연결
- [ ] 이메일 발송 스케줄러 (오전 8:30)
- [ ] **GET /api/evidence/{id} 엔드포인트**

**Frontend (안가은·최종민)**
- [ ] BriefingPage (1순위 — 명확하게 잘 되도록, 3단 구조 적용)
- [ ] Peers 페이지 (재무 시계열 차트 + 전략 방향성)
- [ ] **시계열 이상치 강조 컴포넌트**
- [ ] **검증 페이지 (3단)** 

---

### 7.3 W6 (5/14~5/20) — 통합 + 중간평가

**전체**
- [ ] E2E 통합 테스트
- [ ] 정확도 검증 (골든셋 100건)
  - 분류 정확도, 재무 연결 정확도, 링크 유효성, 검증 첨부율
- [ ] 글로벌 동향 + 검색량 트렌드 추가 (재미 요소)
- [ ] 시연 시나리오 작성
  - 라이브 데모: "기사 발생 → 5분 내 메일" + "뉴스 클릭 → 검증 페이지"
- [ ] 5/18~5/19 데모 리허설 2회
- [ ] **5/20 중간평가**

---

## 8. 성능 검증 기준 (재정의)

| 지표 | 목표 | 측정 |
|---|---|---|
| 링크 유효성 | 99% 이상 | 크롤링 링크 → 실제 접근 가능 비율 |
| 동향 분류 정확도 | 85% 이상 | 골든셋 100건 사람 평가 |
| 재무 연결 정확도 | 80% 이상 | 뉴스↔재무 매핑 사람 검증 |
| **검증 첨부율** ⭐ | **100%** | 모든 산출물에 §3.2 4종 첨부 |
| 선제 탐지 속도 | 5분 이내 | 기사 발생 → 메일 발송 시간 |
| 일간 브리핑 안정성 | 7일 연속 발송 성공 | 자동 발송 모니터링 |

---

## 9. 차별화 포인트 (시연 시 강조)

미팅에서 "시중 AI로 다 할 수 있잖슴 → 차별점?" 질문 받았습니다.

```
1. 검증 체인 ⭐ v3 핵심
   "모든 출력에 4가지 검증 정보 자동 첨부"
   원문 링크 + 판단 근거 + 재무 출처 + MBB 인용
   → "ChatGPT는 답을 주지만 검증 경로를 못 줍니다"

2. 뉴스↔재무 연결
   "왜 이 액션을 했는지 숫자로 설명"
   삼성SDS 분기 매출, LG CNS AI 매출 비중 자동 추적

3. 선제 탐지 + 폐쇄망 대응
   외부 사이트 접속 어려운 환경에서
   이메일 한 통으로 핵심 정보 + 검증 경로 전달

4. SI 특화 도메인 지식
   삼성SDS 물류 제외, ITS만 분석
   MBB 신뢰 소스 자동 매칭
   4개 섹터(보안·AI·수주·사업영역) 도메인 룰
```

---

## 10. 즉시 폐기·축소

```
폐기 (코드 _deprecated/ 이동)
├── ImplicationAgent
├── WeakSignalAgent
├── Slack Webhook 코드 (이메일 발송 모듈 동작 확인 후)
└── 5개 축 가중치 분류 로직

전환
├── ValidationAgent → 근거 첨부 검증 모듈로 형태 변경

축소
├── Reports 탭 → 챗봇 내부 통합
├── Articles 탭 → Dashboard 통합 또는 제거
└── 보고서 편집 기능 → 제거 (챗봇이 대체)
```

---

## 11. 의문점 (v2 잔여 + v3 신규 + W3 종료 갱신)

```
🔴 노출도 임계값·정규화 정의 통일 ⭐ W3 종료 발견
   - 코드 0.65 vs 문서 0.70
   - cluster_size_norm: 코드 5건 saturation vs 문서 7일 max
   - tier1_diversity: 코드 3개 1.0 vs 문서 /5 비례
   → W4 월요일 회의에서 결정 (한쪽으로 통일)

🔴 섹터 키워드 충돌 / 우선순위 ⭐ W3 종료 발견
   - "에이전틱AI" 등이 ai_tech·sk_ax_biz 양쪽 등록
   - dict 첫 매칭만 채택 → security가 항상 ai_tech를 이김
   - 해결안 후보: (a) 키워드 분리 (b) 점수 가중합 (c) LLM tie-breaker

🔴 Evidence 검증 강도 ⭐ W3 종료 발견
   - 109/109 validation_pass=true → 의미 없는 통과 처리 의심
   - financial_refs/mbb_refs 미구현 단계의 missing 처리 정책 미정

🟡 IR PDF 파일 입수 경로
   - DART 공시 첨부 자동 다운로드 vs 수동 업로드
   - 자동화 우선이지만 폴백 필요

🟡 검색량 데이터 API
   - Naver DataLab: 무료, 일별 트렌드
   - Google Trends: pytrends 라이브러리, 비공식
   - 안정성 검증 필요

🟡 MBB·커니 자료 수집 방법 ⭐ v3 신규
   - 맥킨지 Insights, BCG Publications 등 공식 RSS 확인
   - 회원가입·페이월 영역 처리 정책 (제목·요약만 사용)

🟡 보안 최소선 ⭐ W3 종료 발견
   - Spring SecurityConfig.permitAll() 상태 — JWT 또는 정적 Bearer
   - Swagger UI prod 차단 정책
   - OPENAI_API_KEY 사용량 알림·키 회전 주기

🟡 Flyway 도입 시점 ⭐ W3 종료 발견
   - build.gradle 의존성 누락 + V1 마이그 미작성
   - 5/20까지는 schema.sql 직접 수정 + 컨테이너 재생성으로 운영
   - Sprint A에서 V1 베이스라인 + V2 마이그로 전환

🟢 글로벌 동향 X·Threads 수집 방법
   - 공식 API 유료 → Sprint A로 미뤄도 됨

✅ 해소: 트렌드 섹터 4개+other 확정 (보안·AI·수주·사업영역)
✅ 해소: 빅카인즈 처리 (직접 크롤링 금지, 대체 소스로 충분)
✅ 해소: Peer 4사 키워드 등록 (samsung_sds·lg_cns·hyundai_autoever·posco_dx)
✅ 해소: ClassificationAgent v3 — 4섹터 + 결정적 노출도 산식 구현
✅ 해소: ingestion_graph 5+1노드 — EvidenceAgent 노드 연결 완료
```

---

## 12. 다음 미팅 준비 체크리스트

```
대시보드 메인 화면 반영 항목
├── 용어 변경 (이슈 → 동향)
├── 4개 섹터별 동향 카드
├── 긴급/주목 폐기, 노출도·건수·신뢰도 표시
├── 시계열 이상치 시각화
├── 선제 탐지 알림 영역 (메일 알림 미리보기)
├── Peer사 재무 시계열 카드
├── 글로벌 동향 영역 (재미 요소)
└── 카드 → 3단 검증 페이지 이동

준비할 시연
├── 라이브 데모: 기사 발생 → 5분 내 메일 도착
├── 메일 → 클릭 → 3단 검증 페이지 이동 시연
├── 뉴스↔재무 연결 한 사례 (LG CNS 팔란티어 → AI 매출 추이)
└── 멀티에이전트 검증 흐름 시각화
```

---

## 13. 역할 분담

| 역할 | 담당자 | 주 책임 |
|---|---|---|
| AI Lead + PM | **김가은** | axis-ai 파이프라인, axis-infra 일정, **검증 체인 설계** |
| AI Engineer A | **박진** | RAG·검색·평가, **IR 파싱**, **MBB 크롤러** |
| AI Engineer B | **심유정** | 크롤러·전처리, **뉴스↔재무 연결**, 골든셋 |
| Backend Lead | **박지원** | axis-backend, 이메일 발송, **evidence_chain API** |
| Frontend | **안가은·최종민** | axis-frontend, **3단 카드 컴포넌트**, 검증 페이지 |

---

## 14. W7~W9 (5/21~6/23) — 애자일 3스프린트

중간평가 이후 피드백 기반으로 고도화.

| 스프린트 | 기간 | 핵심 목표 |
|---|---|---|
| Sprint A | 5/21~5/27 | 현업 피드백 반영 + 약한 신호 감지 재투입 검토 |
| Sprint B | 5/28~6/3  | 신규 기능 + UAT + 성능 최적화 |
| Sprint C | 6/4~6/23  | 안정화 + 최종 발표 준비 |

### Sprint A 주요 작업
- 현업 인터뷰 결과 반영 (분류·재무 연결 정확도 튜닝)
- `weak_signal_agent.py` 재투입 결정
- Peer사 모니터링 화면 고도화 (전략 방향성 추가)
- MBB·커니 자료 자동 매칭 정확도 향상

### Sprint B 주요 작업
- 트렌드 분석 뷰 + 주간 리포트 자동 생성
- 월간 리포트 모듈 (재무 시계열)
- UAT (현업 시나리오 10건)
- 부하 테스트 (동시 10명, 응답 2초)

### Sprint C 주요 작업
- UAT 피드백 반영 + 최종 버그 수정
- 관리자 대시보드 (Admin 탭)
- 최종 발표자료 + 데모 리허설 3회
- **6/23 최종 발표**

---

## 주의사항

- **파이프라인 분리 유지** — `ingestion_graph` ≠ `delivery_graph`
- **Qdrant 페이로드에 원문 전체 저장 금지** — 메타데이터만
- **BGE-M3 메모리 부족 시** OpenAI Embeddings로 임시 대체 후 Sprint A에서 교체
- **보류 모듈 삭제 금지** — `_deprecated/`로 이동하여 복구 가능 상태 유지
- **Slack Webhook 코드 제거 시점**: 이메일 발송 모듈이 W4 안에 동작 확인된 이후
- **검증 첨부율 100% 보장** — 누락 시 자동으로 사람 검토 플래그 부착
- **임원 시간 절약 원칙** — 모든 화면은 5초 안에 핵심 파악 가능해야 함

---

## 변경 이력

- **2026-04-23**: v1 최초 작성
- **2026-04-24**: v2 — 1차 현직자 미팅 반영 (방향 전환)
- **2026-04-27 오전**: v3 — 목적·검증 체계 재정의 + W3 결과 통합
- **2026-04-27 저녁**: W3 종료 시점 진척도 갱신
  - §2 실측 기반 재작성 (raw 204·card 109·peer 4사·소스 14종)
  - §2.6 신규: 노출도 산식 불일치·Evidence 느슨함·섹터 키워드 충돌·peer_financials 데이터 부재·delivery_graph 슬랙 잔존·보안 무방비
  - §2.8 신규: DB 공유 정책·Flyway 도입 시점·문서 정리
  - §7.1 W4 진척도 표기 (✅/🟡/⏳) + 신규 4/27 발견 항목 추가
  - §11 의문점 — 🔴 신규 3건(임계값 통일·키워드 충돌·검증 강도) + 🟡 2건(보안·Flyway) 추가
  - v1 문서를 `_archived/`로 이동

---

*"정확한 팩트의 빠른 전달로 경영진의 판단을 돕는다" — 이 한 줄에 모든 결정을 맞춥니다.*
