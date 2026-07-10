# 적대적 리뷰 06 — 엔드투엔드 레이턴시 감사

> 대상: 오디오 캡처 → PCM 변환/청킹 → 전사 엔진(Apple/OpenAI/Gemini) → 번역 → 표시(보드/플로팅) → 더빙, 전 구간 정량 분석
> 리뷰일: 2026-07-06 · 라인 번호는 현 워킹트리 기준 검증됨

## 사용자 체감 영향 기준 Top 6

| 순위 | ID | 요약 | 절감 기대치 |
|---|---|---|---|
| 1 | 4.2 | **플로팅 캡션 dwell 큐가 최대 3.6초 지연** — 제품 내 최대 인위적 지연 | 최대 2.5초 |
| 2 | 3.2 | Gemini에 VAD 설정 전무 → 서버 기본값의 트레일링 침묵 대기 | 발화당 0.4–1.2초 |
| 3 | 7.1/7.2 | 더빙 백로그 무제한 → 10분 밀집 발화에 **~1.5분 지연** 누적 | 무제한 → ≤3초 캡 |
| 4 | 5.2 | 번역 REST 60초 타임아웃 → 단일 슬롯 파이프라인 1분 정지 가능 | 60초 → 10초 + 스트리밍 |
| 5 | 4.1 | 80ms 스로틀에 트레일링 플러시 없음 → 발화 꼬리 최대 ~0.5초 미표시 | 꼬리당 최대 0.5초 |
| 6 | 9.3 | Gemini 시작 최악 ~28초 + 선행 발화 유실 | 절벽 제거 + 첫 문장 복구 |

## ⚠️ 이전 리뷰 정정

리뷰 02의 **D3(24kHz 상수 vs 16kHz 캡처 불일치)는 오탐**으로 확인됨. `TranslationSessionStore.swift:483-494`가 엔진별로 캡처 샘플레이트를 전환함(`usesOpenAIRealtimeAudio ? 24_000 : 16_000`) — OpenAI 경로는 실제 24kHz 캡처라 3840B 청크 = 정확히 80ms, Gemini는 16kHz에 3200B = 100ms. 피치 시프트 버그 없음.
잔존 리스크: OpenAI 전사 세션이 `rate: 24000`을 선언(`OpenAIRealtimeTranscriber.swift:168`)하는데 485행을 바꾸면 조용히 깨짐 — 단일 진실 공급원 필요성(리뷰 03 H2)은 유효.

---

## 1. 캡처 측 버퍼링

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 1.1 | AVCaptureAudioDataOutput 버퍼 주기 제어 불가 — 16kHz에서 버퍼당 **32–64ms**, 24kHz에서 21–43ms. macOS API로 축소 불가, 추가 누적은 없음(델리게이트에서 동기 전달) | `MicrophoneAudioCapture.swift:33-41, 83-99` | 21–64ms 고정 바닥 | Low (본질) |
| 1.2 | SCStream 오디오 주기 ~15–50ms/버퍼 + SCK 내부 파이프라인 자체가 첫 콜백 전 ~50–150ms | `SystemAudioCapture.swift:37-48, 63-75` | 버퍼 주기 + 50–150ms | Low (본질) |
| 1.3 | **잘된 것**: 오디오 핫패스는 MainActor 홉 없음 — `didOutput`이 nonisolated로 캡처 큐에서 직접 `append()` 호출, 레벨 보고(8버퍼마다)만 홉 | `TranslationSessionStore.swift:3620-3693` | 0ms | — |
| 1.4 | RMS 레벨 계산이 오디오 전달과 같은 직렬 큐에서 힙 할당+전 샘플 스캔 | `MicrophoneAudioCapture.swift:101-174` 등 | <1ms | Low |
| 1.5 | 시작 지연: `startRunning()` 블로킹(50–300ms, MainActor에서), SCK 콘텐츠 조회+시작 200–800ms, 빠른 stop/start는 이전 해체(~100–300ms)를 먼저 대기 | 위 + `TranslationSessionStore.swift:465-468` | 세션 시작 시 250–1100ms | Medium |

**홉별 청크 길이**: 캡처 버퍼(21–64ms) → 통째 변환 → base64. 통상 버퍼(24kHz에서 ≤2048B)가 청크 상한(3840/3200B)보다 **작아서** 사실상 캡처 버퍼당 1청크 — 80/100ms 상한은 정상 상태에선 사문. 실효 WS 전송 주기 = 캡처 주기.

## 2. 청킹 / 전송 주기

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 2.1 | base64+JSON 오버헤드: OpenAI ~530kbps 업스트림(초당 25–45 메시지), Gemini ~350kbps — 광대역 무해, 핫스팟(~1Mbps 업)에선 큐잉 100ms+ | 인코더들 | 평시 0 / 약한 업링크 100ms+ | Low |
| 2.2 | **48슬롯 in-flight 윈도우가 오디오를 무음 폐기.** 슬롯은 메시지(=캡처 버퍼) 단위라 48슬롯 ≈ **1–2초 분량**. 2초 Wi-Fi 스톨 → 윈도우 참 → 스톨 중 발화 전부 폐기 → 사용자에겐 "캡션이 건너뜀". 지연이 쌓이는 대신 데이터가 사라지는 구조(신호 전무). 수정: 슬롯 고갈 시 로컬 링버퍼(~10초 캡)에 모아 드레인 시 플러시, 최소한 "연결 저하" 상태 표면화 | `OpenAIRealtimeTranscriber.swift:13, 106-120, 141-157`; `GeminiLiveTranslationService.swift:36, 95-113` | ~1–2초 스톨 후 데이터 유실 | **High** |
| 2.3 | 청크당 `JSONEncoder()` 생성 + 샘플당 바이트 append 루프(vDSP화 가능) | `OpenAIRealtimeTranscriber.swift:111, 407-414` | <1ms | Low |

## 3. 서버 설정 레이턴시 노브

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 3.1 | **잘된 것**: OpenAI VAD는 이미 공격적으로 튜닝됨 — threshold 0.42 / prefix 120ms / silence 220ms (기본값 0.5/300/500 대비 발화 final당 ~280ms 절약). 잔여: final은 침묵 220ms + final 추론(~200–500ms) 후 도착. silence를 150–180ms로 내리면 오분할 리스크 대가로 ~50ms 추가 절감 | `OpenAIRealtimeTranscriber.swift:511-542` (173행에서 사용) | final이 발화 종료 후 ~420–720ms (거의 최적) | Low |
| 3.2 | **Gemini는 `realtimeInputConfig`/VAD 설정 전무** — setup에 모델/모달리티/번역 설정만 있고 서버 기본 활동 감지(체감 ~0.5–1.5초 침묵 창) 적용. Gemini 번역 흐름이 턴 기반이라 **모든 캡션이 이 트레일링 침묵을 상속**. 수정: `automaticActivityDetection`에 `endOfSpeechSensitivity: END_SENSITIVITY_HIGH` + `silenceDurationMs` 200–300 설정. **Gemini 경로 최대의 서버 측 레버 — 발화당 0.4–1.2초 절감** | `GeminiLiveTranslationService.swift:135-155, 458-479` | 현재 발화당 +0.5–1.5초 | **High** |
| 3.3 | OpenAI 번역 전용 세션도 `turn_detection` 미전송 → 엔드포인트 기본 턴 분할 대기 | `OpenAIRealtimeTranscriber.swift:180-196` | 턴당 +200–400ms 추정 | Medium |

## 4. 클라이언트 측 인위적 지연 (캡션 경로)

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 4.1 | **80ms 델타 발행 스로틀에 트레일링 플러시 없음.** 억제된 텍스트는 다음 델타 또는 `completed`(침묵 220ms + final 추론 ~300ms) 도착 시에야 발행 → 구절 마지막 델타가 스로틀 창에 걸리면(발화의 ~50%) **마지막 단어가 ~400–600ms 미표시**. 수정: 억제 시 `interval - elapsed` 후 원샷 플러시 태스크(다음 발행 시 취소), 간격도 50ms로 | `OpenAIRealtimeTranscriber.swift:14, 292-320` | 델타당 0–80ms, 꼬리 최대 ~500ms | **High** |
| 4.2 | **플로팅 캡션 dwell 큐 — 제품 최대의 인위적 지연.** dwell = clamp(1.1 + len/32, **1.4초, 3.6초**). dwell 중 도착한 새 문장은 단일 슬롯 큐(newest-wins)에 파킹, dwell 후 50ms 바닥 타이머로 승격. 탈출구는 0.45초 조기 수정 창과 제시 텍스트 <28자일 때의 prefix 확장뿐. 시나리오: 연속 발화 + 100자 캡션 → dwell ≈ 3.6초 → **엔진이 이미 전달한 텍스트보다 라이브 자막이 최대 3.6초 뒤처짐**, 세션 내내 매 라인마다. 가독성 트레이드오프지만 체감 지연 1위 기여자. 수정: (a) prefix 확장은 28자 제한 무관하게 제자리 갱신 허용(확장은 가독성 무해), (b) 최대 dwell 2.0–2.4초 캡, (c) dwell을 전체 길이가 아닌 *미독* 델타에 비례 | `TranslationSessionStore.swift:87-90, 2399-2498` | 0–3.6초 (플로팅 창) | **Critical** (플로팅 사용자) |
| 4.3 | 장기 세션 코얼레싱: `.thirtyMinutesOrMore` + 4000자 이상 라인에서 보드 갱신 350ms(final 175ms) 스로틀 — 유계·의도적 | `TranslationSessionStore.swift:82-84, 2036-2090` | 0–350ms (옵트인) | Low |
| 4.4 | 정리 디바운스: 침묵(-50dB, 마지막 인식 후 >1.5초) + 700ms 후 `organizeCurrentTranscript` → 다듬은 텍스트+재번역이 **발화 종료 ~2.2초 후** 가시적 재작성으로 등장 (Apple 경로만) | `TranslationSessionStore.swift:2596-2666` | 침묵 후 ~2.2초 재작성 | Medium |
| 4.5 | **타자기 애니메이션 지연 (플로팅).** ≤360자 델타를 4–8자 청크 × 10–18ms sleep으로 애니메이트하는데 청크가 공백/구두점마다도 분할되어 청크 수 ≈ 단어 수. 최악: 360자 델타 ≈ 65단어 ≈ 70청크 × 10ms ≈ **이미 수신한 데이터 뒤로 0.7초**; 200자 VAD-final 수정 ≈ 0.4초. 발화 final 버스트(사용자가 가장 기다리는 순간)가 가장 느리게 애니메이트. 수정: 총 애니메이션 ≤200ms 되게 청크 크기 스케일(`max(8, len/20)`) 또는 >120자 델타는 애니메이션 스킵 | `StreamingTranscriptText.swift:4-5, 109-139, 143-163` | 큰 델타에서 0–0.7초 | Medium-High |
| 4.6 | 보드 자동 스크롤 코얼레싱 250ms(장기 모드) + 0.22초 스크롤 애니메이션 — 미용상 | `CaptionBoardView.swift:99-134` | ≤250ms (스크롤만) | Low |
| 4.7 | 번역 디바운스: 평시 45ms / 버스트 초기 70ms / 장기 모드 4k자↑ 450ms, 10k자↑ **900ms** | `TranslationSessionStore.swift:3233-3247` | 45–900ms | Low/Medium |

## 5. 번역 경로

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 5.1 | 번역은 partial마다 트리거되어 **단일 슬롯** `latestTranslationRequest`로 컨플레이션, **단일** `translationTask`가 직렬 소비 — in-flight 1건이 끝날 때까지 모든 새 텍스트 대기 | `TranslationSessionStore.swift:3139-3223` | 큐 대기 = in-flight 번역 시간 | High |
| 5.2 | **`URLSession.shared` 기본 타임아웃 60초 + 비스트리밍 `/v1/responses`.** 요청 1건 행 → 단일 슬롯 파이프라인이 최대 **60초간 "Translating…"** 표시, partial은 계속 쌓임. 수정: 전용 세션 `timeoutIntervalForRequest 8–10초` + 1회 재시도, 이상적으론 `"stream": true`로 `progress` 증분 반영(세그먼트당 체감 300–800ms 절감) | `OpenAITranslationService.swift:3-52` | 최악 60초 정지 | **Critical** |
| 5.3 | **갱신마다 전체 전사 재번역 순회.** 세그먼트 캐시로 엔진 호출은 신규분만이지만: (a) 캐시 키 부기가 갱신당 ~20만 비교(MainActor), (b) 꼬리 partial 세그먼트는 매번 재번역, (c) Apple `translate` 세그먼트당 30–250ms. 번역 캡션의 원문 대비 지연: **Apple 0.1–0.9초, OpenAI 텍스트 모델 0.9–4초**. 수정: 변경된 꼬리만 번역 + Dictionary LRU | `TranslationSessionStore.swift:2848-2975` | 번역 지연 0.1–4초 | High |
| 5.4 | Apple 경로는 번역 전 `organizeCurrentTranscript`를 기다리지 않음(양호). 장기 모드만 enqueue 전 전체 라인 정규식을 MainActor 동기 실행 | `TranslationSessionStore.swift:3225-3231` | 1–20ms | Low |
| 5.5 | `updateTranslation`이 progress 콜백마다 번역 전문에 `organizeTranscript`(MainActor) | `TranslationSessionStore.swift:3271-3305` | 갱신당 1–15ms | Medium |

## 6. 메인 스레드 경합 = 지연

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 6.1 | 엔진 이벤트마다 `Task { @MainActor }` 홉 — 불가피, 이벤트당 1–5ms × 스트림당 ~12/s | `TranslationSessionStore.swift:3695-3813` | 이벤트당 1–5ms | Low |
| 6.2 | `appendCaption` → 전체 커밋 텍스트에 대한 다중 `TranscriptTextProcessor` 패스(정규식 정규화, n-gram, 수정 매칭)를 초당 수 회 MainActor에서. 10k자에서 partial당 5–20ms, 50k자(연속 발화 1시간 = 한 라인, `currentLineID` 미회전)에서 **20–100ms** → 모든 갱신의 표시 지연+지터. 수정: 꼬리만 증분 diff 또는 문단별 라인 회전 | `TranslationSessionStore.swift:1882-1974`; `TranscriptTextProcessor.swift:23-66, 399-497` | 갱신당 5–100ms, 무한 성장 | **High** |
| 6.3 | **린트 켜면 NSSpellChecker가 MainActor에서 전문 순회** — 호출당 1–10ms(IPC성), 노이즈 낀 5k자 전사에서 **한 번에 100–500ms 프리즈**, 정확히 다음 발화 시작 시점에. OpenAI/Gemini에선 자동 비활성 — Apple 경로만. 백그라운드 executor로 | `TranslationSessionStore.swift:2724-2820` | 정리당 100–500ms 히치 | **High** (린트 시) |
| 6.4 | `floatingTranslationText` 등이 SwiftUI computed property 안에서 렌더마다 정규식 실행 | `TranslationSessionStore.swift:1092-1115, 3416-3434` | 프레임당 0.5–5ms | Medium |
| 6.5 | 렌더 폭풍: partial마다 `lines[index]` 교체 → Observable 무효화 → `textView.string =` 전체 재설정+ensureLayout. 표시 텍스트 4000자 캡(`CaptionLine.swift:5, 39-45`)이 2–10ms로 유계 — 좋은 방어 설계 | `CaptionBoardView.swift:328-435` | 갱신당 5–25ms | Medium |

## 7. 더빙 지연

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 7.1 | **무제한 `scheduleBuffer` 큐.** TTS는 실시간의 2–6배 속도로 도착해 턴 오디오가 즉시 전량 인큐; 번역 오디오가 원문보다 길면(교차 언어 통상) 백로그가 연속 발화 중 **절대 배수 안 됨** — 드리프트 ≈ Σ(번역 길이) − 재생 경과. 예: 번역이 15% 길면 밀집 발화 10분 후 **~90초 지연**, 상한 없음. Gemini `interrupted`는 player를 멈추지만 **OpenAI 경로엔 인터럽트/플러시 전무**. 수정: 스케줄 프레임 vs `player.playerTime` 추적, 백로그 >2–3초면 오래된 턴 드롭/최신만 스케줄 + "더빙 지연 중" 상태 노출 | `OpenAIRealtimeAudioOutput.swift:36-71`; 피더 `TranslationSessionStore.swift:3733-3749, 3779-3795` | 무제한; 밀집 10분당 ~1.5분 | **Critical** (더빙 사용자) |
| 7.2 | **Apple 더빙**: `AVSpeechSynthesizer` 발화 직렬화(합성+발화 ≈ 1× 실시간)인데 번역 텍스트는 원 화자 속도로 도착 → 백로그가 경과 시간의 ~10–40%씩 성장 → **10분 후 1–4분 지연**. 중복 방지는 있으나 stale 큐 발화를 절대 안 버림. 수정: 큐 깊이 캡(~2 발화) + 오래된 미발화 유닛 폐기, 백로그 시 `utterance.rate` 상향 | `TranslatedSpeechOutput.swift:18-35`; `TranslationSessionStore.swift:3440-3462, 3566-3576` | 장기 세션에서 수 분 | **High** |
| 7.3 | 첫 더빙 오디오: 첫 버퍼에서 `engine.start()` 30–100ms, 샘플레이트 변경 시 재연결이 큐 드롭 | `OpenAIRealtimeAudioOutput.swift:61-102` | 1회성 30–100ms | Low |

## 8. Apple 음성 엔진 설정

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 8.1 | **잘된 것**: `[.volatileResults, .fastResults]`로 빠른 partial 활성(오디오 뒤 ~150–600ms), `prepareToAnalyze` 선호출로 첫 발화 모델 로드 지연(0.5–2초) 회피 | `LiveSpeechTranscriber.swift:113-149` | partial 150–600ms (거의 최적) | — |
| 8.2 | `bufferingNewest(32)`: 분석기 스톨 시 32버퍼 × 32–64ms = **1–2초** 큐 지연 후 oldest 드롭(지연 대신 전사 공백). 무음 드롭에 신호 없음이 진짜 문제 | `LiveSpeechTranscriber.swift:55-56, 131-135` | 스톨 시 최대 1–2초 | Medium |
| 8.3 | 48버퍼 재사용 풀이 32슬롯 스트림+분석기 보유분과 겹칠 이론적 가능성 → 오염 → 인식 오류 → 재시도(간접 지연). 리뷰 03 D1과 동일 사안 | `LiveSpeechTranscriber.swift:55, 325-342` | 간접 | Low |

## 9. 네트워크 / 연결 수립

| ID | 발견 | 위치 | 지연 기여 | 심각도 |
|---|---|---|---|---|
| 9.1 | TCP_NODELAY: `URLSessionWebSocketTask`는 소켓 옵션 미노출 — 조치 불가(기록). `NWConnection`+`NWProtocolWebSocket` 이관 시 `.noDelay` + 진짜 연결 상태 콜백(9.3도 해결) | — | ~0–40ms | Low |
| 9.2 | OpenAI 시작: `resume()` 직후 `sendSessionUpdate` await ≈ TLS+WS 핸드셰이크 150–500ms. 캡처는 그 뒤에 시작(오디오 유실은 없으나 직렬화) → "듣는 중"까지 0.4–1.3초. 수정: 캡처를 핸드셰이크와 병행 시작 + ≤2초 오디오 버퍼링 → 시작 0.3–0.8초 절감 | `OpenAIRealtimeTranscriber.swift:83-91`; `TranslationSessionStore.swift:477-494` | 시작 시 150–500ms | Medium |
| 9.3 | **Gemini 시작 최악 ~28초.** ping 폴링 40회(백오프 100→500ms, Σ ≈ 18.2초) + setup 완료 50ms 폴링 최대 10초. 통상 0.4–1.5초. 가중 요인: (a) 연결 실패 판정이 **현지화된** 에러 문자열 매칭(비영어 로케일에서 첫 일시 오류에 start 중단 — 리뷰 02 B4), (b) **`isSetupComplete` 전 도착 오디오는 폐기**(89행 가드) → Start 직후 첫 ~0.5–1.5초 발화가 캡션 안 됨. 수정: ping 폴링 대신 `didOpenWithProtocol` 델리게이트, 에러는 코드 매칭, setup 전 오디오 버퍼링 후 재생 → 시작 0.3–17초 절감 + 첫 문장 복구 | `GeminiLiveTranslationService.swift:74-240` | 통상 0.5–1.5초 / 최악 ~28초 + 선행 발화 유실 | **High** |
| 9.4 | 수신 에러 시 재연결 없이 영구 종료(3개 WS 서비스 공통) → 연결 1회 끊김 = 수동 재시작 전까지 캡션 정지(무한 지연). 리뷰 02 B1과 동일 사안 | 각 `receiveLoop` | 세션 치명 | **High** |

---

## 경로별 레이턴시 버짓 (발화 → 보드 캡션 표시, 정상 네트워크 정상 상태)

### 경로 A — Apple SpeechAnalyzer + Apple 번역 (16kHz)

| 단계 | 현재 | 수정 후 |
|---|---|---|
| 캡처 버퍼 (마이크/SCK) | 30–65ms | 30–65ms (바닥) |
| 변환 + AsyncStream yield | ~1ms (분석기 스톨 시 1–2초) | ~1ms |
| SpeechAnalyzer volatile 결과 | 150–600ms | 150–600ms (바닥) |
| MainActor 홉 + 누적/정규식 | 5–30ms (전사와 함께 성장) | 2–5ms (증분 diff) |
| 표시 (표준 모드) | ~0ms (장기: ≤350ms) | 동일 |
| 렌더 | 5–25ms | 5–15ms |
| **원문 캡션 합계** | **~0.25–0.75초** | **~0.2–0.7초** |
| 번역: 디바운스+큐+Apple MT+정리 | +0.1–0.9초 | +0.08–0.4초 (꼬리만 번역) |
| **번역 캡션 합계** | **~0.4–1.6초** | **~0.3–1.1초** |
| 침묵 후 정리 재작성 | +2.2초 (린트 시 +0.1–0.5초 히치) | 백그라운드, 히치 없음 |

### 경로 B — OpenAI Realtime (24kHz)

| 단계 | 현재 | 수정 후 |
|---|---|---|
| 캡처 버퍼 | 21–45ms | 21–45ms |
| 인코드/전송 + 업링크 | 20–60ms | 20–60ms |
| 서버 ASR 델타 | 200–600ms | 200–600ms (바닥) |
| 80ms 발행 스로틀 | 평균 40ms, **꼬리 최대 ~500ms** | ≤50ms (트레일링 플러시 + 50ms 간격) |
| MainActor + 누적 + 렌더 | 10–40ms | 5–20ms |
| **partial 캡션 합계** | **~0.3–1.25초** | **~0.3–0.8초** |
| 발화 final (VAD 220ms + final 추론) | 발화 종료 후 +0.4–0.7초 | +0.35–0.65초 |
| 번역 전용 모드 | + 기본 turn_detection 0–400ms | 튜닝 시 −200–400ms |

### 경로 C — Gemini Live (16kHz)

| 단계 | 현재 | 수정 후 |
|---|---|---|
| 캡처 + 전송 | 35–70ms | 35–70ms |
| 서버 VAD (미설정 기본값) + 번역 턴 | **0.8–2.5초** | 0.4–1.2초 (명시 VAD 설정) |
| 수신 → MainActor → 라인 갱신 | 5–20ms | 5–20ms |
| **캡션 합계** | **~0.9–2.6초** | **~0.5–1.3초** |
| 세션 시작 | 통상 0.5–1.5초, **최악 ~28초**, 선행 오디오 폐기 | 0.3–0.8초, 절벽 없음, 오디오 버퍼링 |

### 플로팅 캡션 오버레이 (전 경로 가산)

| 단계 | 현재 | 수정 후 |
|---|---|---|
| dwell/승격 큐 | **0–3.6초** (최소 dwell 1.4초) | 0–2.0초, 순수 확장은 ~0 |
| 타자기 애니메이션 | 큰 델타에서 0–0.7초 | ≤0.2초 |
| 승격 타이머 바닥 | 50ms | 50ms |

### 더빙 (가산, 현재 무제한)

| 출력 | 현재 드리프트 | 수정 후 |
|---|---|---|
| OpenAI/Gemini TTS | 무한 성장; 밀집 10분당 ~1.5분 | ~2–3초 캡 |
| Apple AVSpeechSynthesizer | 경과의 ~10–40%씩 성장; 수 분 | ~2발화 캡 |

---

## 잘 되어 있는 것 (보정)

- OpenAI VAD는 이미 기본값 대비 발화당 ~280ms 아끼는 공격적 튜닝 (3.1).
- 오디오 핫패스에 MainActor 홉 없음 (1.3).
- Apple 엔진은 `.volatileResults/.fastResults` + `prepareToAnalyze` 선호출로 거의 최적 (8.1).
- 표시 텍스트 4000자 캡이 렌더 비용을 유계화 (6.5).
- 리뷰 02 D3(샘플레이트 불일치)은 오탐 — 엔진별 레이트 전환이 이미 구현돼 있음.
