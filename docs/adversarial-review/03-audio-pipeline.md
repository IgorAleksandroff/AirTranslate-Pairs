# 적대적 리뷰 03 — 오디오 캡처 / 재생 파이프라인

> 대상: `MicrophoneAudioCapture`, `SystemAudioCapture`, `LiveSpeechTranscriber`, `SpeechCaptioner`, `OpenAIRealtimeAudioOutput`, `TranslatedSpeechOutput` + 스토어 배선
> 리뷰일: 2026-07-06

## 최우선 순위 (Top Priorities)

| 순위 | ID | 요약 | 심각도 |
|---|---|---|---|
| 1 | A1 | 마이크 모드 + 더빙 스피커 재생 시 **음향 피드백 루프** (AEC 없음) | High |
| 2 | B1 | SCStream delegate가 nil → 시스템 오디오 캡처 사망을 감지 못함 | High |
| 3 | C1 | 마이크 디바이스 변경/연결해제 미처리 → 세션 무음 사망 | High |
| 4 | D1 | 재활용 PCM 버퍼가 소비자 사용 중 덮어쓰기됨 (앨리어싱) | High |
| 5 | F1 | 출력 라우트 변경(에어팟 연결) 미처리 → 더빙 영구 사망 가능 | High |

---

## A. 에코 / 피드백

### A1. 마이크 모드에 음향 에코 제거(AEC) 부재 — High
- 위치: `TranslationSessionStore.swift:486-494` + `MicrophoneAudioCapture.swift:30-41`
- 실패 시나리오: 마이크 입력 + GPT/Gemini 실시간 더빙 + 내장 스피커 조합 → `OpenAIRealtimeAudioOutput`이 재생한 번역 음성을 마이크가 재캡처 → 재전사·재번역되는 **자기지속 피드백 루프** (최악: 무한 재잘거림, 최소: 쓰레기 전사). `excludesCurrentProcessAudio = true`(SystemAudioCapture.swift:42)는 시스템 오디오 경로만 보호.
- 수정: `AVAudioEngine.inputNode` + `setVoiceProcessingEnabled(true)`(AEC 제공)로 마이크 캡처, 또는 최소한 `player.isPlaying` 동안 전사 입력 뮤트/게이트, 또는 마이크+더빙+스피커 조합 시 사용자 경고.

## B. SystemAudioCapture.swift

### B1. `SCStream(delegate: nil)` → 스트림 사망 미감지 — High
- 위치: 46행
- 실패 시나리오: 디스플레이 분리, macOS 화면캡처 알림 필의 "공유 중지" 클릭, SCK 내부 에러 → 오디오는 조용히 멈추는데 UI는 "듣는 중" 유지, 반사망 SCStream은 수동 중지까지 잔존.
- 수정: `SCStreamDelegate.stream(_:didStopWithError:)` 구현 → 스토어에 전달 → 에러 표면화 + 해체/자동 재시작.

### B2. `stop()`이 `stopCapture()` 실패를 `try?`로 삼키고 무조건 nil 처리 — Medium
- 위치: 54-60행
- 실패 시나리오: stop 실패 시 참조만 끊겨 캡처와 보라색 화면녹화 표시가 계속 살아있을 수 있음 — 사용자는 유휴 상태로 믿는 메뉴바 앱에서 프라이버시+배터리 문제.
- 수정: 에러 로그/표면화, 중지 확인 전까지 참조 유지 또는 재시도.

### B3. 화면녹화 TCC 권한 UX가 막다른 길 — Medium
- 위치: 20-24행
- 결함: `CGRequestScreenCaptureAccess()`는 실행당 최대 1회 프롬프트 후 즉시 false 반환; 거부 후엔 재프롬프트 없음, 허용 후엔 (구버전 동작 기준) 재실행 필요한데 안내가 상태 문자열뿐.
- 수정: `screenRecordingNotGranted` 시 기존 `openPrivacySettings()` 딥링크 + "앱 재실행" 안내를 명시적으로 제공.

### B4. 버리기 위한 `.screen` 출력(2×2px, 1fps) 부착 — Low
- 위치: 47, 64-65행
- 결함: 세션 내내 WindowServer/GPU 캡처 파이프라인 낭비 + 오디오와 동일 직렬 `sampleQueue` 공유.
- 수정: 오디오 전용 SCStream 사용(지원 macOS에서 가능) 또는 비디오 전용 큐 분리.

### B5. `audioSampleCount` 데이터 레이스 — Low
- 위치: 16, 50, 66행 — `sampleQueue`에서 쓰고 MainActor에서 리셋(무동기화); 50행 리셋이 `startCapture()` 반환 후 실행되어 초기 콜백을 소급 0화.
- 수정: 아토믹 또는 `sampleQueue.async`로 큐 국한.

### B6. `content.displays.first` 폴백 없음 — Low
- 위치: 32-34행 — Sidecar/가상 디스플레이 전용 또는 재구성 중엔 `noDisplay`로 세션 중단(시스템 오디오 캡처엔 특정 디스플레이가 본질적으로 불필요한데도).
- 수정: 실패 시 1회 재시도 + 메인 디스플레이 선택.

## C. MicrophoneAudioCapture.swift

### C1. 디바이스 변경 처리 전무 — High
- 위치: 파일 전체
- 결함: `AVCaptureSession`은 시스템 기본 입력을 따라가지 않으며, `wasDisconnectedNotification`/`.AVCaptureSessionRuntimeError`/`kAudioHardwarePropertyDefaultInputDevice` 관찰 없음.
- 실패 시나리오: 에어팟으로 시작 → 회의 중 배터리 방전 → 버퍼 전달 중단, UI는 "듣는 중", 재시작도 에러도 없음.
- 수정: 런타임 에러/연결해제 알림 관찰 → 기본 디바이스로 캡처 재시작 + 토스트.

### C2. `startRunning()`/`stopRunning()`을 MainActor에서 블로킹 호출 — Medium
- 위치: 55행, 61행
- 실패 시나리오: 블루투스 마이크는 수백 ms~수 초 소요 → Start 클릭 시 메뉴바 UI/플로팅 캡션 비치볼.
- 수정: 세션 구성+startRunning을 전용 직렬 백그라운드 큐로.

### C3. `audioSampleCount` 데이터 레이스 (B5와 동일 패턴) — Low
- 위치: 16, 52, 90행. 수정 동일.

### C4. `audioLevel(from:)`이 전달 큐에서 힙 할당 + 스칼라 RMS 루프 — Low
- 위치: 101-174행 (122행 `UnsafeMutableRawPointer.allocate`)
- 결함: 전사기로 가는 동일 큐에 지터 추가. **동일 ~75줄 함수가 `SystemAudioCapture.swift:77-150`에 복제**되어 있음.
- 수정: `withUnsafeTemporaryAllocation` + `vDSP_rmsqv`로 교체하고 한 곳으로 추출.

### C5. 비 float 분기가 16bit 정수 가정 — Low (잠재)
- 위치: 159-167행. `mBitsPerChannel` 확인 후 `Int16` 바인딩.

### C6. 뽑힌 마이크의 stale uniqueID → 기본 마이크 폴백 없이 throw — Low
- 위치: `MicrophoneDeviceCatalog.swift:17-23` + 스토어 폴백
- 수정: uniqueID 미스 시 `AVCaptureDevice.default(for: .audio)` 폴백 + 토스트.

### C7. 디바이스 목록이 수동 새로고침 시에만 갱신 — Low
- 위치: `TranslationSessionStore.swift:669-674`
- 수정: connect/disconnect 알림 관찰로 자동 갱신.

## D. LiveSpeechTranscriber.swift

### D1. 재활용 `AVAudioPCMBuffer`가 소비자 사용 중 변조될 수 있음 — High
- 위치: 55-56, 72-76, 325-342행
- 결함: 48슬롯 링의 재사용 버퍼에 쓰고 `AsyncStream`(`bufferingNewest(32)`)으로 yield하는데, `SpeechAnalyzer`가 버퍼를 보유 중인 동안 링이 한 바퀴 돌면(스트림에 32개 + 분석기 내부 큐 > 여유 16슬롯, 에셋 페이징/CPU 압박 시 발생 가능) `frameLength = 0` + 샘플 덮어쓰기(332, 312-315행)가 **분석기가 읽는 중인 오디오를 오염** → 재현 거의 불가능한 인식 왜곡.
- 수정: 스트림 경계 너머로 가변 버퍼 공유 금지 — yield마다 할당(16k 모노 Int16은 저렴) 또는 소비자 반납 후에만 재사용하는 체크아웃/반납 풀.

### D2. `inputContinuation` 무동기화 접근 — Medium
- 위치: 65, 134-135, 179, 200-201행 — 캡처 큐에서 읽고(`append`) 다른 스레드의 `start()`/`stop()`에서 쓰기.
- 실패 시나리오: 버퍼 in-flight 중 Stop → 옵셔널 torn read → 크래시 또는 finish 후 yield.
- 수정: 기존 `stateLock`으로 보호.

### D3. 16kHz 모노 하드코딩 + 유입 포맷 무검증 — Medium
- 위치: 58-63, 246-323행
- 결함: 유입 `CMSampleBuffer`의 실제 샘플레이트/채널 수를 확인하지 않고 16k 모노 스탬프. 스토어의 관례적 동기화(`TranslationSessionStore.swift:483-485`의 16k/24k 선택)가 깨지면 잘못된 속도로 재생된 오디오가 무음으로 인식 저하. 294-316행은 인터리브 스테레오 입력 시 L,R,L,R 쓰레기 생성.
- 수정: `mSampleRate`/`mChannelsPerFrame` 읽어 assert/변환(AVAudioConverter) 또는 로그 후 드롭.

### D4. `bufferingNewest(32)`가 스톨 시 가장 오래된 오디오 무음 드롭 — Medium
- 위치: 132-134행
- 실패 시나리오: 온디바이스 모델 페이지인/CPU 스파이크 → 문장 중간 ~2초 증발, 사용자 신호 없음.
- 수정: `yield` 반환값 `.dropped` 계수 → "처리 지연" 상태 표면화, 그리고/또는 연속성 유지를 위해 newest 드롭으로 전환 검토.

### D5. `stop()`의 비구조화 Task 해제가 `start()` 재예약과 경합 — Low
- 위치: 198-222행 — 빠른 Stop→Start 시 release가 새 세션이 예약한 로케일을 해제할 수 있음.
- 수정: stop을 async화하거나 start가 저장된 teardown task를 await.

### D6. 델리게이트 콜백이 임의 Task 실행기 스레드에서 호출 — Low
- 위치: 142-149, 151-171행 — 현재는 스토어의 전 메서드가 즉시 @MainActor 홉해서 무사하나 취약한 계약.
- 수정: 계약 문서화 또는 정의된 큐로 전달.

## E. SpeechCaptioner.swift

### E1. 참조 0건인 사장 코드가 배포에 포함 — Medium
- 위치: 파일 전체 (grep 결과 외부 참조 없음)
- 결함: SFSpeechRecognizer의 알려진 함정(1분 세션 제한 재시작 부재, 임의 큐 델리게이트, 가용성 미처리)을 안은 채 방치 — 재연결 시 미묘하게 실패.
- 수정: 삭제하거나 재사용 전 수리.

### E2. (부활 시) 완료 후 request/task 미정리 + 임의 큐 델리게이트 — Low
- 위치: 35-49행.

## F. OpenAIRealtimeAudioOutput.swift

### F1. `AVAudioEngineConfigurationChange`(라우트 변경) 미처리 — High
- 위치: 파일 전체
- 실패 시나리오: 더빙 중 에어팟 연결(이 앱의 전형적 사용례) → 엔진 정지 + 스케줄된 버퍼 전부 드롭, 캐시된 `format`으로 `configuredFormat`이 stale 반환 → 다음 청크의 `engine.start()`가 새 하드웨어와 그래프 불일치 → 최선: 발화 중 공백, 최악: **start()가 계속 throw하여 세션 끝까지 더빙 사망**(에러는 68-70행에서 삼켜짐).
- 수정: `.AVAudioEngineConfigurationChange` 관찰 → 연결 재구축(`configuredFormat` 무효화) + 엔진 재시작.

### F2. `engine.start()` 실패 무음 삼킴 — Medium
- 위치: 60-70행 (`catch { engine.stop() }`)
- 실패 시나리오: 출력 디바이스 일시 불가 → 소리 없음인데 UI는 더빙 켜짐 표시.
- 수정: 델리게이트로 상태/토스트 표면화 + 백오프 재시도.

### F3. 첫 청크에 엔진 시작 후 세션 끝까지 미정지 — Medium
- 위치: 61-66행 — 무음 중에도 오디오 IO 유닛 상시 가동(배터리 + "오디오 사용 중" 표시 상시 점등).
- 수정: completion handler로 잔여 버퍼 추적 → 배수 후 엔진 정지(또는 워치독).

### F4. `scheduleBuffer` 큐 무제한 — Medium
- 위치: 64행
- 결함: TTS가 실시간보다 빠르게 도착 → 긴 발화 시 재생 지연이 무한 증가 + 재생 전까지 `AVAudioPCMBuffer` 메모리 고정. 스토어의 `pause()`는 신규 청크만 차단해 **일시정지 중에도 이미 스케줄된 오디오가 계속 말함**.
- 수정: completion handler로 큐 길이(초) 추적 → N초 초과 시 드롭/압축, pause 시 player 플러시.

### F5. 고정 1.6× 게인 + 하드 클리핑 — Low
- 위치: 8, 55행 — 풀스케일 근처 콘텐츠 왜곡. 소프트 리미터 또는 `player.volume`로 대체.

### F6. `assumingMemoryBound(to: Int16.self)` 정렬 UB 가능성 — Low
- 위치: 49-52행 — `loadUnaligned` 또는 `withMemoryRebound`가 정답.

## G. TranslatedSpeechOutput.swift

### G1. `AVSpeechSynthesisVoice(language:)` nil 시 시스템 기본 음성으로 발화 — Medium
- 위치: 27행
- 실패 시나리오: 대상 한국어인데 한국어 음성 미설치 → **한국어 텍스트를 영어 발음으로 낭독**.
- 수정: nil 확인 → `speechVoices()`에서 언어 접두 매칭 폴백 → 없으면 "음성 미설치" 표면화.

### G2. 중복제거 키 제거가 삽입 키와 어긋남 → 문장 영구 뮤트 — Medium
- 위치: 45-49행
- 결함: 제거 시 `utterance.voice?.language`로 키를 재구성하는데, voice가 nil이었거나(→ `Locale.current` 폴백) 로케일 민감 folding이 다르면 삽입 키와 불일치 → `queuedSpeechKeys`에서 영원히 안 빠짐.
- 실패 시나리오: "OK", "네" 같은 짧은 상용구가 **한 번 발화된 뒤 세션 내내 다시는 안 나옴**.
- 수정: 계산된 키를 `ObjectIdentifier(utterance)` 키 맵에 저장했다가 그 값으로 제거.

### G3. `queuedSpeechKeys`를 MainActor와 신시사이저 델리게이트 큐 양쪽에서 변조 — Low
- 위치: 7, 24, 37-43행. 델리게이트 본문 @MainActor 홉 또는 락.

### G4. 볼륨이 enqueue 시점 고정 — Low
- 위치: 28행. 문서화 또는 flush-and-respeak.

## H. 크로스커팅 (스토어 배선)

### H1. Pause가 캡처를 계속 가동 (오디오만 폐기) — Medium
- 위치: `TranslationSessionStore.swift:581-592`
- 결함: 일시정지 중에도 SCStream 녹화(보라 표시)와 마이크가 켜져 있고 `append()`에서 `isPaused`로 버릴 뿐 — "일시정지 = 캡처 안 함"이라는 사용자 기대와 불일치(프라이버시) + 배터리.
- 수정: pause 시 캡처 중지/서스펜드, 또는 동작을 명확히 표기.

### H2. 16k/24k 계약이 4개 파일의 중복 리터럴로만 존재 — Medium
- 위치: `TranslationSessionStore.swift:483-485` vs `LiveSpeechTranscriber.swift:60` vs OpenAI/Gemini 상수
- 결함: 한쪽만 수정되면 잘못 스탬프된 버퍼로 피치 시프트 오디오가 무음 유입(D3 연계).
- 수정: 단일 `AudioPipelineFormat` 진실 공급원 + 변환 지점에서 `mSampleRate` assert.

### H3. 모든 샘플 버퍼를 3개 소비자에 무조건 팬아웃 — Low
- 위치: `TranslationSessionStore.swift:3621-3624, 3667-3670` — 비활성 2개가 버퍼당 NSLock만 잡고 early-return. 활성 캡셔너로만 라우팅.

### H4. `stop()`의 `captureStopTask` fire-and-forget — Low
- 위치: `TranslationSessionStore.swift:536-538` + 465-468행 — `stopCapture()` 행 시 아무도 관찰 안 함, 녹화 표시 잔존. 타임아웃 + 에러 표면화.

### H5. 음성인식 TCC 딥링크 부재 — Low
- 위치: `MicrophoneAudioCapture.swift:67-79`, `LiveSpeechTranscriber.swift:224-230`, `openPrivacySettings()`(`TranslationSessionStore.swift:655-662`)는 mic/screen 패널만 커버
- 수정: `SpeechError.notAuthorized` → `Privacy_SpeechRecognition` 패널 딥링크 매핑.

---

## 잘 되어 있는 것 (보정용)

- `excludesCurrentProcessAudio = true`로 시스템 오디오 모드의 자기 TTS 디지털 재캡처는 올바르게 차단.
- 실시간 Core Audio 렌더 스레드 위 작업 없음 — 전부 직렬 DispatchQueue 델리게이트 콜백(락/할당 합법).
- `withUnsafeTemporaryAllocation`(pcmBuffer), `bufferingNewest` 백프레셔 등 의도적 설계 흔적 — 결함은 그 메커니즘의 가장자리에 있음.
