# 적대적 리뷰 07 — 레이턴시 재검증 결과 + 상세 업그레이드 카탈로그

> 리뷰일: 2026-07-06 · 기준: `master` @ `dd458cc` (v1.3.6)
> 방법: [06-latency.md](06-latency.md)의 모든 핵심 주장을 **원문 코드를 직접 열어 라인 단위로 재대조**. 코드로 검증 가능한 것과 외부 추정치를 명확히 구분함.
> 관점: "사용자가 실제로 느끼는 지연"별로 시나리오를 묶고, 각 업그레이드를 구현 스케치·예상 절감·리스크·검증 방법까지 상세 기술.

---

## Part 1 — 재검증 결과

### 1-A. 코드로 확정된 발견 (✅ 원문 대조 완료)

| 06 ID | 주장 | 재검증 결과 |
|---|---|---|
| 4.2 | 플로팅 dwell 1.4–3.6초 | ✅ **확정.** `minimumFloatingCaptionDwell = 1.4` / `maximumFloatingCaptionDwell = 3.6` (`TranslationSessionStore.swift:89-90`), `dwell = 1.1 + readableLength/32` (2445행). dwell 길이는 원문·번역 중 **긴 쪽**(`max(sourceLength, translationLength)`, 2444행) 기준 — 번역이 길면 dwell이 더 늘어남(06에 없던 세부). 조기 수정 창 0.45초(87행), 제자리 확장은 제시 텍스트 <28자일 때만(88, 2432-2433행), 단일 슬롯 newest-wins 큐(2420행), 타이머 바닥 50ms(2474행) 전부 일치 |
| 4.1 | 80ms 스로틀, 트레일링 플러시 없음 | ✅ **확정.** `realtimeTranscriptPublishInterval = 0.08`(`OpenAIRealtimeTranscriber.swift:14`). `appendRealtimeTranscriptionDelta`(292-300행)는 80ms 미경과 시 `return`만 하고 어떤 지연 발행도 예약하지 않음. 억제된 텍스트는 다음 델타 또는 completed에서만 발행. **가중 확인**: completed가 빈 transcript면 `guard ... else { return }`(252행)으로 발행도 리셋도 안 되어, 스로틀에 걸린 꼬리가 **다음 발화의 델타까지** 미표시 |
| 3.1 | OpenAI VAD 튜닝됨 | ✅ **확정.** `lowLatencyServerVAD` = threshold 0.42 / prefix 120ms / silence 220ms (511-522행). 단, **전사(transcription) 모드에만** 적용(173행) |
| 3.2 | Gemini VAD 설정 전무 | ✅ **확정.** `GeminiLiveSetup`(135-149행)은 model + responseModalities + translationConfig + 입출력 전사 토글이 전부. `realtimeInputConfig`/`automaticActivityDetection` 부재 |
| 3.3 | OpenAI 번역 모드 turn_detection 미전송 | ✅ **확정.** translationOnly 세션(180-196행)은 전사 모델 + noiseReduction + 출력 언어만 전송. turnDetection도, **입력 포맷/레이트도** 없음(전사 모드는 rate 24000 명시, 168행) |
| 5.1 | 번역 단일 슬롯 직렬 소비 | ✅ **확정.** `latestTranslationRequest` 단일 변수 newest-wins(3164행), `translationTask` 1개(3172-3178행), while 루프 직렬 소비(3181-3220행). in-flight 1건이 끝날 때까지 새 텍스트 대기 |
| 5.2 | 번역 REST 60초 타임아웃 | ✅ **확정.** `URLSession.shared.data(for:)`(`OpenAITranslationService.swift:35`) — 기본 요청 타임아웃 60초, 비스트리밍 `/v1/responses`. 덤: 5행의 `private let model`은 사용처 없는 사문 |
| 4.7 | 번역 디바운스 45/70/450/900ms | ✅ **확정.** `translationDebounceDelay`(3233-3247행): 장기 모드 10k자↑ 900 / 4k자↑ 450, 버스트 첫 0.45초 70, 이후 0 또는 45 |
| 7.1 | 더빙 큐 무제한 | ✅ **확정.** `player.scheduleBuffer(buffer, completionHandler: nil)`(`OpenAIRealtimeAudioOutput.swift:64`) — completion 추적 없음, 큐 계정 없음, 플러시 API 없음(`stop()`은 전체 정지, 28-34행). 샘플레이트 변경 시 `player.stop()`이 큐를 통째로 드롭(78-85행) |
| 7.2 | Apple 더빙 직렬 백로그 | ✅ **확정.** `synthesizer.speak(utterance)`(`TranslatedSpeechOutput.swift:29`) — AVSpeechSynthesizer 내부 직렬 큐, 깊이 캡 없음, stale 폐기 없음. `utterance.rate`는 **아예 미설정**(기본 속도) — 백로그 시 가속 여지 있음 |
| 4.5 | 타자기 애니메이션 최대 ~0.7초 | ✅ **확정 + 범위 정정.** 청크 4–8자 / 딜레이 10–18ms(109-110행), 청크는 **공백·구두점마다도** 분할(152행: `current.count >= maxCharacters \|\| character.isWhitespace \|\| character.isPunctuation`) → 청크 수 ≈ 단어 수. 360자 델타: 영어 ~65청크 ≈ 0.65초, **한국어(어절이 짧아) ~0.8–0.9초**, 무공백 CJK ~0.45초. **단, 사용처는 `FloatingCaptionWindowView.swift:104` 유일** — 메인 보드가 아니라 **플로팅 창 전용** 지연이며, dwell과 같은 표면에 누적됨. `reduceMotion`은 존중함(84행) |
| 9.3 | Gemini 시작 최악 ~28초 + 선행 오디오 폐기 | ✅ **확정.** ping 40회, `delay = min(100 + attempt*50, 500)`(160-170행): Σ = (100+150+…+450) + 32×500 = 2,200 + 16,000 = **18.2초** + `waitForSetupComplete` 10초 데드라인 50ms 폴링(187-206행) = 최악 ~28초. `append()`가 `isSetupComplete` 전 오디오를 무조건 폐기(89행). 에러 판별은 `localizedDescription.contains("socket is not connected")`(238-240행) — 비영어 로케일 취약 확정 |
| §0 | 샘플레이트 불일치는 오탐 (02·D3 정정) | ✅ **정정 확정.** `let sampleRate = usesOpenAIRealtimeAudio ? 24_000 : 16_000`(`TranslationSessionStore.swift:483-485`) — OpenAI 경로는 진짜 24kHz 캡처. Gemini mimeType `"audio/pcm;rate=16000"` 하드코딩(100행)도 캡처 16kHz와 일치. 다만 이 계약이 4개 파일의 리터럴로 흩어진 리스크는 유효 |
| 2.2 | 48슬롯 고갈 시 오디오 무음 폐기 | ✅ **확정.** `guard reserveAudioSendSlot() else { continue }`(Gemini 106행, OpenAI 동형) — 폐기 시 신호 전무 |

### 1-B. 재검증에서 **새로 발견**된 사항 (06에 없음)

#### N1. dwell 대기 중 취소 연쇄가 MainActor 스핀 루프가 됨 — High (CPU/에너지)
- 위치: `TranslationSessionStore.swift:2467-2498`
- 메커니즘: `scheduleFloatingPresentationAdvance()`가 기존 태스크를 cancel → 취소된 태스크의 `try? await Task.sleep`이 **즉시** throw(삼켜짐) → 가드 없이 `promoteQueuedFloatingPresentationIfReady()` 진입 → dwell 미경과라 `scheduleFloatingPresentationAdvance()` 재호출 → **방금 만든 새 태스크를 또 cancel** → 그 태스크도 즉시 fall-through → … 자기지속 연쇄.
- 결과: dwell 중 갱신이 한 번이라도 도착하면(연속 발화의 통상 케이스) **dwell이 끝날 때까지 MainActor가 태스크 생성/취소 + `floatingCaptionDwellDuration()` 재계산을 스핀** — 이 함수는 매회 `normalizedTranscriptForComparison`(정규식)을 2회 호출(2442-2443행). 리뷰 01의 C1(가드 누락)이 지목한 바로 그 원인의 구체적 결과이며, 지연보다는 CPU/에너지 소모 문제(승격 타이밍 자체는 스핀 폴링 덕에 대략 유지됨).
- 수정: sleep 뒤 `guard !Task.isCancelled else { return }` **한 줄**. (01·C1 수정과 동일)

#### N2. 빈 completed × 스로틀 상호작용 — 꼬리 텍스트가 다음 발화까지 미표시
- 위치: `OpenAIRealtimeTranscriber.swift:252 + 292-300`
- 06의 4.1(트레일링 플러시 없음)과 02의 E2(빈 completed가 버퍼 방치)가 **결합**되면: 마지막 델타가 스로틀에 걸리고 completed가 빈 transcript로 오면, 그 꼬리는 completed에서도 발행 안 되고 **다음 발화의 첫 델타에서야** 표시. 두 수정(트레일링 플러시 + completed 무조건 리셋)이 함께 필요함을 확인.

#### N3. 타자기 애니메이션 지연은 한국어에서 최악
- `chunkedForTranscriptStreaming`이 공백마다 분할하므로 어절이 짧은 한국어(평균 2-4자+공백)는 청크 수가 가장 많음 → 360자 델타에서 ~0.8-0.9초. **이 앱의 주 사용자층 언어에서 애니메이션 지연이 가장 큼.**

#### N4. `utterance.rate` 미설정 (Apple 더빙)
- `TranslatedSpeechOutput.swift:26-28` — rate를 만지지 않으므로 백로그 시 가속 캐치업 여지가 그대로 남아 있음(업그레이드 U-D2에 반영).

### 1-C. 코드로 검증 불가능한 추정치 (외부 시스템/API 동작 — 정직하게 구분)

| 06 ID | 주장 | 판정 |
|---|---|---|
| 1.1/1.2 | 캡처 버퍼 21–64ms, SCK 파이프라인 50–150ms | ⚠️ **OS 동작 추정치.** 코드에 버퍼 크기 설정이 없음은 확인(= OS 기본에 맡김도 사실). 실측하려면 콜백 타임스탬프 로깅 필요 — U-M1 참조 |
| 3.2 일부 | Gemini 서버 기본 VAD ≈ 0.5–1.5초 | ⚠️ **외부 API 추정치.** "설정이 없다"는 사실이고, 기본값의 크기는 실측 필요 |
| — | OpenAI 서버 ASR 델타 200–600ms, final 추론 200–500ms | ⚠️ **외부 추정치** |
| 버짓 테이블 | 경로별 합계 | ⚠️ 위 추정치를 포함하므로 **±수백 ms 오차 가능** — 단 각 경로의 상대 비교와 "클라이언트 정책이 지배" 결론은 코드 확정분만으로 성립 |

**총평: 06의 코드 기반 주장은 전부 정확했고, 오히려 재검증에서 가중 요인 2건(N1, N2)과 한국어 최악 케이스(N3)가 추가됨. 외부 추정치는 실측 계측(U-M1)으로 확정하는 것이 다음 단계.**

---

## Part 2 — 사용자 관점 업그레이드 카탈로그

사용자가 느끼는 증상 6가지로 묶음. 각 항목: 구현 스케치 / 예상 절감 / 리스크 / 난이도 / 검증 방법.

### 시나리오 A — "말이 끝났는데 마지막 단어가 한참 있다 뜬다"

#### U-A1. 델타 스로틀 트레일링 플러시 ⭐ P0
- 위치: `OpenAIRealtimeTranscriber.swift:292-320` (3개 함수 동형)
- 구현 스케치:
```swift
private var pendingFlushTask: Task<Void, Never>?

private func appendRealtimeTranscriptionDelta(_ delta: String) {
    realtimeTranscriptionText += delta
    let now = Date()
    let elapsed = now.timeIntervalSince(lastRealtimeTranscriptionPublishAt)
    guard elapsed >= Self.realtimeTranscriptPublishInterval else {
        scheduleTrailingFlush(after: Self.realtimeTranscriptPublishInterval - elapsed)
        return
    }
    pendingFlushTask?.cancel()
    lastRealtimeTranscriptionPublishAt = now
    publishRecognizedTranscript(realtimeTranscriptionText)
}

private func scheduleTrailingFlush(after delay: TimeInterval) {
    guard pendingFlushTask == nil else { return }   // 이미 예약됨
    pendingFlushTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self else { return }
        self.pendingFlushTask = nil
        self.publishRecognizedTranscript(self.realtimeTranscriptionText)  // 락 필요 — 02·B6 수정과 함께
    }
}
```
- 함께: `completed` 핸들러(247-262행)에서 transcript 유무와 무관하게 버퍼+`lastPublishAt` 리셋(N2 해소), 발행 간격 80→50ms 하향 검토.
- 절감: 발화 꼬리 최대 **~0.5초** (발화의 ~50%에서 발생) + 평균 지연 80→50ms 시 델타당 ~15ms.
- 리스크: 낮음. 버퍼 접근 스레딩(02·B6)과 함께 처리해야 안전.
- 난이도: 하 (함수 3개 × ~10줄). 검증: delta→(80ms 내 delta)→침묵 시퀀스 단위 테스트로 마지막 델타 발행 확인.

#### U-A2. Gemini `realtimeInputConfig` VAD 명시 설정 ⭐ P0
- 위치: `GeminiLiveTranslationService.swift:135-155` + 인코더블(458-479행)
- 구현 스케치 — setup 메시지에 추가:
```swift
struct GeminiLiveRealtimeInputConfig: Encodable {
    let automaticActivityDetection: GeminiLiveActivityDetection
}
struct GeminiLiveActivityDetection: Encodable {
    let startOfSpeechSensitivity: String  // "START_SENSITIVITY_HIGH"
    let endOfSpeechSensitivity: String    // "END_SENSITIVITY_HIGH"
    let silenceDurationMs: Int            // 250
    let prefixPaddingMs: Int              // 120
}
// GeminiLiveSetup에 let realtimeInputConfig: GeminiLiveRealtimeInputConfig? 추가
```
- 절감: 발화당 **0.4–1.2초 추정** — Gemini 경로 최대 레버. 실측으로 확정(U-M1).
- 리스크: 중 — 너무 민감하면 문장 오분할 → 번역 품질 저하. 250ms에서 시작해 A/B.
- 난이도: 하 (인코더블 구조체 2개 + 필드 1개). 검증: 동일 음성 파일로 before/after 발화종료→캡션 시간 실측.

#### U-A3. OpenAI 번역 모드에도 turn_detection + 입력 포맷 전송 — P1
- 위치: `OpenAIRealtimeTranscriber.swift:180-196`
- 전사 모드(163-178행)와 동형으로 `turnDetection: .lowLatencyServerVAD` + `format: rate 24000` 추가. 엔드포인트가 필드를 거부하면 무해하게 무시되는지 확인 필요(02·D1의 프로토콜 검증과 함께).
- 절감: 턴당 200–400ms 추정. 난이도: 하.

### 시나리오 B — "플로팅 자막이 실제 말보다 몇 초 뒤처진다"

#### U-B1. dwell 재설계: 제자리 확장 + 캡 하향 ⭐ P0
- 위치: `TranslationSessionStore.swift:87-90, 2424-2450`
- 구현 3단계:
  1. **prefix 확장은 무조건 제자리 갱신** — `canUpdateFloatingPresentationImmediately`(2424-2434행)에서 `normalizedPresented.count < 28` 조건 삭제. 확장(기존 텍스트가 후보의 접두)은 이미 읽은 내용이 그대로 남으므로 가독성 손실이 없음. `presentFloatingSourceText`가 `floatingPresentedAt = Date()`로 dwell을 리셋하니, 확장 갱신 시엔 리셋하지 않는 분기 필요(안 그러면 dwell이 영원히 연장됨):
```swift
if isWholeTextPrefix(normalizedPresented, of: normalizedCandidate) {
    presentFloatingSourceText(candidate, resetsDwell: false)
    return
}
```
  2. **최대 dwell 3.6 → 2.2초, 최소 1.4 → 1.2초** — 06 버짓 기준 연속 발화 체감 지연 상한이 3.6→2.2초.
  3. **dwell을 "미독 델타"에 비례** — 현재는 제시된 전체 길이 기준(2442-2445행). 직전 제시와 새 후보의 공통 접두를 빼고 새로 등장한 글자 수로 계산하면 짧은 이어짐은 빨리 넘어감:
```swift
let unreadLength = normalizedCandidate.count - commonPrefixLength(normalizedPresented, normalizedCandidate)
let dwell = 0.9 + Double(unreadLength) / 28.0
```
- 절감: 연속 발화 플로팅 지연 **최대 2.5초** (제품 내 최대 단일 개선).
- 리스크: 중 — dwell은 가독성 장치이므로 너무 줄이면 자막이 날아감. 사용자 설정(빠름/보통/느림 3단)으로 노출하는 것을 권장 — 자막 속도 선호는 사용자마다 다름.
- 난이도: 중. 검증: 긴 낭독 음성으로 "엔진 발행 시각 vs 플로팅 표시 시각" 로그 비교 + 실사용 가독성 확인.

#### U-B2. 스핀 루프 가드 (N1) ⭐ P0 — **한 줄**
- 위치: `TranslationSessionStore.swift:2475-2478` (+ 2601-2605의 동형)
```swift
floatingPresentationTask = Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
    guard !Task.isCancelled else { return }   // ← 추가
    promoteQueuedFloatingPresentationIfReady()
}
```
- 절감: 지연이 아니라 **dwell 내내 도는 MainActor 스핀 제거** — CPU/에너지 + 스핀이 밀어내던 다른 MainActor 작업(캡션 갱신 포함)의 지연 감소.
- 리스크: 없음. 검증: 연속 발화 중 CPU 사용률 before/after.

#### U-B3. 타자기 애니메이션 총량 캡 — P1
- 위치: `StreamingTranscriptText.swift:109-112, 143-163`
- 구현: 총 애니메이션 시간이 ~200ms를 넘지 않도록 청크 수를 상한:
```swift
let targetChunkCount = 14                          // 14 × ~14ms ≈ 200ms
let chunkSize = max(6, remainingText.count / targetChunkCount)
// chunkedForTranscriptStreaming에서 공백/구두점 분할 제거하고 순수 크기 분할
// (또는 공백 분할 유지하되 delay를 200ms/chunks.count로 동적 계산)
```
- 함께: `renderedText`의 AttributedString 재구성(56-62행)을 `Text(settled) + Text(appearing)` 연결로 교체(04·D1), UTF-16/Character 혼용(95 vs 102행) 통일(04·D2).
- 절감: final 버스트에서 **최대 0.7초 → ≤0.2초**, 한국어 최악 케이스(~0.9초) 해소.
- 리스크: 낮음 — 타이핑 감이 다소 거칠어지나 지연 대비 이득이 큼. 난이도: 하.

### 시나리오 C — "번역이 원문보다 한참 늦거나 아예 굳는다"

#### U-C1. 번역 전용 URLSession + 짧은 타임아웃 + 재시도 ⭐ P0
- 위치: `OpenAITranslationService.swift:3-52`
```swift
private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 30
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
}()
// URLSession.shared → Self.session
// 429/5xx 시 Retry-After 존중 1회 재시도 (지터 0.5-1.5초)
```
- 절감: 최악 정지 **60초 → 10초**. 단일 슬롯 파이프라인(5.1)이라 이 1건이 전체 번역 흐름을 좌우.
- 리스크: 없음. 난이도: 하. (5행의 사문 `model` 프로퍼티도 이때 삭제)

#### U-C2. 번역 스트리밍 (`"stream": true`) — P1
- `/v1/responses`의 SSE 스트림을 `URLSession.bytes(for:)`로 소비, `response.output_text.delta` 이벤트를 기존 `progress` 클로저(3200-3207행에 이미 배관 존재!)로 흘리면 됨 — **스토어 쪽 수정 불필요**.
- 절감: 세그먼트당 체감 300–800ms (첫 토큰 도착 시점부터 표시).
- 난이도: 중. 검증: 긴 문단 번역 시 부분 텍스트가 점진 표시되는지.

#### U-C3. 꼬리만 재번역 + LRU 캐시 교체 — P1
- 위치: `TranslationSessionStore.swift:2848-2975`
- 구현: `translateTranscript`가 전 세그먼트를 순회하는 대신, 마지막 확정 세그먼트 인덱스를 기억하고 그 이후(통상 꼬리 partial 1개)만 번역. 캐시는 배열 `removeAll{==key}` 대신 `Dictionary + 세대 스탬프` LRU:
```swift
struct TranslationCache {
    private var store: [String: (value: String, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    mutating func value(for key: String) -> String? { ... tick 갱신 ... }
    mutating func insert(_ value: String, for key: String) {
        // 2000 초과 시 tick 최소 항목 제거 (O(n) 1회 or min-heap)
    }
}
```
- 절감: 갱신당 MainActor 캐시 부기(현 ~20만 문자 비교) 제거 + Apple MT 세그먼트당 30–250ms × 재번역 세그먼트 수 감소 → 번역 지연 0.1–0.9초 → **0.05–0.4초**.
- 리스크: 중 — 확정 세그먼트 판정 로직이 정확해야 과거 오역이 안 굳음. 정리(cleanup) 재구성 시 전체 재번역 1회는 유지.
- 난이도: 중상. 검증: 기존 언어후보 테스트 + 신규 세그먼트 캐시 단위 테스트.

### 시나리오 D — "더빙이 갈수록 밀려서 나중엔 딴 얘기를 하고 있다"

#### U-D1. OpenAI/Gemini TTS 백로그 캡 ⭐ P0
- 위치: `OpenAIRealtimeAudioOutput.swift:36-71`
```swift
private var scheduledFrames: AVAudioFramePosition = 0   // queue에서만 접근

private func playPCM16Data(_ data: Data, sampleRate: Double) {
    ...
    // 현재 재생 위치 기준 백로그 계산
    if let nodeTime = player.lastRenderTime,
       let playerTime = player.playerTime(forNodeTime: nodeTime) {
        let backlogSeconds = Double(scheduledFrames - playerTime.sampleTime) / sampleRate
        if backlogSeconds > 3.0 {
            // 정책: 새 버퍼 드롭(현재 턴 뒷부분 유실) 또는 player.stop()+재스케줄(옛 턴 폐기)
            delegateNotifyDubbingBehind()   // UI에 "더빙 지연" 상태
            return
        }
    }
    scheduledFrames += AVAudioFramePosition(buffer.frameLength)
    player.scheduleBuffer(buffer) { [weak self] in /* 필요 시 회계 */ }
    ...
}
```
- 함께: `pause()` 시 `player.stop()`으로 이미 스케줄된 오디오 플러시(현재는 일시정지해도 계속 말함 — 03·F4), OpenAI 경로에 interrupted 동형 처리.
- 절감: **무제한 드리프트(10분당 ~1.5분) → ≤3초 고정.** 더빙 기능의 실사용 가능성을 결정하는 수정.
- 리스크: 중 — 드롭 정책 선택 필요. 라이브 통역 도구로는 "오래된 턴 폐기"(최신 유지)가 정합적.
- 난이도: 중. 검증: 10분 밀집 음성 파일 재생 → 원문 발화 시각 vs 더빙 재생 시각 드리프트 측정.

#### U-D2. Apple 더빙 큐 캡 + 백로그 시 가속 — P1
- 위치: `TranslatedSpeechOutput.swift`
- 구현: `queuedSpeechKeys.count`(이미 큐 깊이의 근사)가 N(예: 3) 초과 시 `synthesizer.stopSpeaking(at: .word)`로 현재 발화만 남기고 스킵하거나, 새 utterance에 `utterance.rate = min(0.62, base + 0.05 × backlog)` 적용(현재 rate 미설정 — N4).
- 절감: 수 분 드리프트 → 수 초. 난이도: 하.

### 시나리오 E — "시작 버튼 누르고 한참 기다린다 / 첫 문장이 안 나온다"

#### U-E1. Gemini 연결 감지 재작업 + setup 전 오디오 버퍼링 ⭐ P0
- 위치: `GeminiLiveTranslationService.swift:56-115, 157-240`
- 구현 3부:
  1. **ping 폴링 제거** — `URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didOpenWithProtocol:)`을 받는 delegate 기반 `URLSession(configuration:delegate:delegateQueue:)`로 전환, `CheckedContinuation`으로 open을 await. 폴링 40회(최악 18.2초)와 영어 문자열 매칭(238-240행) 동시 제거.
  2. **에러 분류를 코드 기반으로** (잔존 send 재시도용): `(error as NSError).domain == NSPOSIXErrorDomain && code == ENOTCONN`.
  3. **setup 전 오디오 링버퍼**: `append()`(82-114행)에서 `isSetupComplete == false`면 폐기 대신 최근 ~3초를 링버퍼에 보관, `setupComplete` 수신 시 순서대로 플러시:
```swift
private var preSetupAudioBuffer: [Data] = []   // stateLock 보호, ~3초 캡
guard isSetupComplete else {
    bufferPreSetupChunks(audioChunks)   // 초과분은 oldest 드롭
    return
}
```
- 절감: 시작 최악 28초 절벽 제거, 통상 0.5–1.5초 → 0.3–0.8초, **Start 직후 첫 문장 유실 해소**(사용자 신뢰에 직결).
- 리스크: 낮음–중. 난이도: 중. 검증: 네트워크 스로틀(Network Link Conditioner)로 느린 연결에서 시작 시간 + 첫 발화 캡션 유무.

#### U-E2. 캡처와 WS 핸드셰이크 병렬 시작 — P2
- 위치: `TranslationSessionStore.swift:477-494` (현재 captioner 시작 → 캡처 시작 직렬)
- 구현: `async let`으로 캡처와 captioner를 병렬 기동하고, U-E1의 링버퍼가 핸드셰이크 중 오디오를 흡수.
- 절감: 세션 시작 0.3–0.8초. 리스크: 시작 실패 시 해체 순서 — 01·M1(직렬화)과 함께 설계. 난이도: 중.

### 시나리오 F — "세션이 길어지면 점점 무거워지고 자막이 버벅인다"

#### U-F1. 문단 경계 라인 회전 — P1 (01·H3와 동일 수정)
- `currentLineID`를 침묵/문단 경계에서 회전 → 갱신당 문자열 복사·diff·정규식 대상이 "현재 문단"으로 축소. 06·6.2의 "갱신당 5–100ms, 무한 성장"을 상수화. 이것 하나로 장기 세션 성능 문제의 뿌리가 잘림.
#### U-F2. 린트 백그라운드화 — P1 (06·6.3)
- `correctUnknownWords`를 스냅샷 기반 detached task로; 완료 시 원본 미변경 확인 후 적용. 정리 시점 100–500ms 메인 스레드 히치 제거.
#### U-F3. 플로팅 computed property 캐시 — P2 (06·6.4, 04·A6)
- `floatingSourceText`/`floatingTranslationText` 결과를 스토어에 저장하고 원천 텍스트/설정 변경 시에만 재계산 — 렌더당 정규식 제거.

### 계측 (모든 추정치를 사실로)

#### U-M1. 레이턴시 계측 파이프라인 ⭐ P0와 병행 권장
- 구현: `os_signpost` 기반 — (a) 캡처 콜백 수신, (b) WS send, (c) 델타 수신, (d) 스토어 발행, (e) 뷰 표시 각 지점에 signpost; Instruments에서 구간별 분포 확인. 디버그 빌드 한정 `AIRTRANSLATE_LATENCY_TRACE=1` 게이트.
- 목적: 1-C의 외부 추정치(캡처 버퍼, Gemini VAD 기본값, 서버 ASR 지연)를 실측으로 확정하고, 위 업그레이드들의 before/after를 수치로 증명. **이게 없으면 개선 효과를 주장만 하게 됨.**
- 난이도: 하–중.

---

## Part 3 — 실행 순서 제안

| 단계 | 항목 | 난이도 | 기대 효과 |
|---|---|---|---|
| 1 | U-B2 스핀 가드(1줄) + U-C1 타임아웃 + U-A1 트레일링 플러시 | 하 | 60초 정지 제거, 꼬리 0.5초, MainActor 스핀 제거 |
| 2 | U-M1 계측 | 하–중 | 이후 모든 개선의 근거 수치 |
| 3 | U-A2 Gemini VAD + U-A3 OpenAI 번역 VAD | 하 | 발화당 0.4–1.2초 (실측 확정) |
| 4 | U-B1 dwell 재설계 + U-B3 애니메이션 캡 | 중 | 플로팅 체감 최대 2.5초 + 0.5초 |
| 5 | U-D1/U-D2 더빙 백로그 캡 | 중 | 더빙 실사용 가능화 |
| 6 | U-E1 Gemini 시작 재작업 | 중 | 시작 절벽 + 첫 문장 유실 해소 |
| 7 | U-C2 번역 스트리밍 + U-C3 꼬리만 번역 | 중상 | 번역 표시 0.3–0.8초 |
| 8 | U-F1 라인 회전 + U-F2 린트 배경화 | 중상 | 장기 세션 안정화 |

> 전제: 01의 Critical(C1 가드, C2 세대 토큰, C3 레이스)은 이 로드맵과 독립적으로 최우선. 특히 C1 가드는 U-B2와 같은 수정임.
