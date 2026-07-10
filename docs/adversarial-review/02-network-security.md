# 적대적 리뷰 02 — 네트워크 / API 서비스 / 보안

> 대상: `OpenAIRealtimeTranscriber`, `GeminiLiveTranslationService`, `OpenAITranslationService`, `AppleTranslationService`, `OpenAIAPIKeyStore`, `GeminiAPIKeyStore`, `FoundationTranscriptPolisher`, `ModelAvailabilityChecker`
> 리뷰일: 2026-07-06

## 최우선 순위 (Top Priorities)

| 순위 | ID | 요약 | 심각도 |
|---|---|---|---|
| 1 | B4 | 소켓 에러를 영어 문자열로 판별 → **비영어 macOS에서 Gemini Live 시작 실패** | High |
| 2 | A1 | Gemini API 키가 URL 쿼리로 전송 → 에러/로그 유출 | High |
| 3 | B1+B2 | 재연결/킵얼라이브 없음 → 네트워크 순단에 세션 영구 사망 | High |
| 4 | D1 | OpenAI 번역 모드가 미문서화 엔드포인트 사용 의심 → 무증상 실패 | High |
| 5 | C1 | 무제한 오디오 스트리밍 → 유료 키 과금 폭탄 | High |
| 6 | E2 | 빈 completed 이벤트 시 델타 버퍼 미초기화 → 문장 겹침 | Medium |

---

## A. API 키 처리

### A1. Gemini API 키가 URL 쿼리 파라미터로 전송 — High
- 위치: `GeminiLiveTranslationService.swift:56-64`
- 결함: WebSocket URL에 `?key=<apiKey>` 형태로 키를 부착.
- 실패 시나리오: URLSession/CFNetwork 디버그 로그, TLS 검사 프록시의 접근 로그, 그리고 특히 연결 실패 시 `NSError`의 `userInfo`에 전체 URL이 포함되어 `didFail` 델리게이트(265행)를 거쳐 **에러 UI에 키가 그대로 노출**될 수 있음.
- 수정: `URLRequest`의 `x-goog-api-key` 헤더로 전송하고, 표면화하는 에러에서 `key=` 쿼리를 제거하는 정제(sanitize) 단계 추가.

### A2. macOS 레거시 키체인에서 `kSecAttrAccessible` 무시됨 — Medium
- 위치: `OpenAIAPIKeyStore.swift:46`, `GeminiAPIKeyStore.swift:46`
- 결함: `kSecUseDataProtectionKeychain: true` 없이 저장하면 macOS는 레거시 파일 키체인을 사용하므로 `AfterFirstUnlockThisDeviceOnly` 속성이 사실상 무효(백업/마이그레이션 포함 가능).
- 수정: `baseQuery()`에 `kSecUseDataProtectionKeychain as String: true` 추가(엔타이틀먼트 필요) + 기존 레거시 항목 마이그레이션 처리.

### A3. 저장 시 delete-then-add 비원자성 — Low
- 위치: 양쪽 키 스토어 42-48행
- 결함: `SecItemDelete` 결과 무시 + delete와 add 사이 크래시/실패 창이 존재. 잠금 상태(`errSecInteractionNotAllowed`)에서 기존 키 유실 또는 `errSecDuplicateItem` 혼란 발생.
- 수정: `SecItemUpdate` 우선 → `errSecItemNotFound` 시 `SecItemAdd` 폴백(표준 upsert 패턴).

### A4. 키 스토어 파일 전체 복제 — Medium (유지보수)
- 위치: `GeminiAPIKeyStore.swift` ≡ `OpenAIAPIKeyStore.swift` (86줄 전체, service/account 문자열만 상이 — 직접 diff로 확인함)
- 실패 시나리오: A2/A3 수정을 한쪽에만 적용하면 공급자 간 보안 수준이 갈라짐.
- 수정: service/account/에러문구를 파라미터로 받는 제네릭 `APIKeyStore` 하나로 통합.

### A5. 키 메모리 위생 — Low
- 위치: `OpenAIAPIKeyStore.swift:27`, `GeminiLiveTranslationService.swift:53`, `OpenAIRealtimeTranscriber.swift:65`
- 결함: 불변 `String`으로 취급되어 zero-out 불가, 메모리 덤프에 잔존. Swift 앱 일반 수준이지만 A1(URL 문자열/컴포넌트/태스크 설명으로 복사 증가)이 이를 악화.
- 수정(선택): `Data`로 유지하고 복사 최소화. A1 수정이 우선.

### A6. 키체인 읽기 에러를 "키 없음"으로 강제 변환 — Low
- 위치: `OpenAIAPIKeyStore.swift:9` (`try?`), 소비처 `ModelAvailabilityChecker.swift:74`
- 실패 시나리오: 키체인 잠금/ACL 거부 시 "API 키 없음"으로 표시 → 사용자가 멀쩡한 키를 덮어씀.
- 수정: `hasAPIKey`에서 "없음"과 "읽기 실패"를 구분해 표기.

---

## B. WebSocket 생명주기

### B1. 재연결 로직 전무 — High
- 위치: `OpenAIRealtimeTranscriber.swift:215-228`, `GeminiLiveTranslationService.swift:248-269`
- 결함: `receiveLoop`가 `didFail` 1회 보고 후 종료하지만 소켓 객체가 남아 있어 `append()`(OpenAI:100, Gemini:89)가 죽은 소켓에 계속 전송.
- 실패 시나리오: 회의 중 와이파이 2초 순단 → 세션 영구 정지 + 이후 매 오디오 청크마다 send 실패 콜백(OpenAI:118, Gemini:111)이 `didFail`을 초당 수십 회 스팸.
- 수정: 수신 실패 시 락 안에서 `webSocketTask`를 nil 처리(append 즉시 드롭) → 지수 백오프 재연결(세션 핸드셰이크 재실행) → 재시도 소진 후에만 `didFail` 1회 표면화. 최소한 "failed" 플래그로 청크별 에러 스팸 억제.

### B2. 일시정지/무음 중 킵얼라이브 핑 없음 — Medium
- 위치: 양 서비스 전체 (`GeminiLiveTranslationService.swift:175`의 `sendPing`은 시작 시에만 사용)
- 실패 시나리오: 일시정지 중 NAT/프록시/서버 유휴 타임아웃으로 half-open → 재개 시 첫 발화 유실 + B1 실패 모드 진입.
- 수정: 연결 중 15-20초 주기 `sendPing` 태스크 운영, 핑 실패를 B1 재연결 트리거로 사용.

### B3. OpenAI가 핸드셰이크 확인 전에 `session.update` 전송 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:85-87`
- 결함: Gemini 쪽은 연결 전 전송 실패(ENOTCONN)를 40회 핑 대기로 우회(157-173행)하는데 OpenAI 쪽엔 그 대기가 없음.
- 실패 시나리오: 느린 네트워크에서 `start()`가 위양성 throw → 전사 세션이 시작조차 안 됨.
- 수정: 동일한 연결 대기(더 좋게는 `didOpenWithProtocol` 델리게이트) 적용, F1과 함께 공통화.

### B4. 로케일 의존 문자열 매칭으로 소켓 에러 분류 — High
- 위치: `GeminiLiveTranslationService.swift:238-240`
- 결함: `error.localizedDescription`을 영어 문구 "socket is not connected"와 비교. 비영어 macOS(이 앱의 주 사용자층인 한국어 포함)에선 POSIX 에러 문구가 현지화되어 매칭 실패.
- 실패 시나리오: `waitForWebSocketConnection`(166행)과 `send` 재시도 루프(215행)가 첫 시도에 즉시 rethrow → **비영어 사용자에게 Gemini Live `start()`가 사실상 항상 실패**.
- 수정: `(error as NSError).domain == NSPOSIXErrorDomain && code == ENOTCONN` 등 에러 코드 기반 분류 + `NSURLErrorDomain .networkConnectionLost` 처리.

### B5. 공유 가변 상태 비동기화 접근 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:69-70, 84, 88, 131-134, 217`, `GeminiLiveTranslationService.swift:75, 122-127, 250`
- 결함: `@unchecked Sendable` 클래스에서 `append()`/`setPaused()`만 `stateLock`을 잡고, `start()`/`stop()`/`receiveLoop`는 무락으로 `webSocketTask`/`outputMode`/`language`/`receiveTask` 접근.
- 실패 시나리오: stop 직후 start 시 이전 receive 루프가 새 `webSocketTask`를 읽어(OpenAI:217) **새 세션의 첫 메시지(setupComplete/첫 전사)를 가로채 소실**; TSan 감지 가능한 데이터 레이스.
- 수정: 모든 공유 가변 접근을 락으로 보호, receive 루프는 인스턴스 변수 재조회 대신 캡처한 소켓 참조(`receiveLoop(for task:)`) 사용 + 세대(generation) 카운터 비교.

### B6. 전사 버퍼의 크로스 스레드 무락 변경 — Low
- 위치: `OpenAIRealtimeTranscriber.swift:292-320` vs `stop()`/`resetRealtimeTranscriptBuffers()`(138/348-355행)
- 결함: receive 태스크에서 append, 임의 스레드에서 reset — Swift `String` 데이터 레이스.
- 수정: 버퍼 리셋도 동일 락으로 묶거나 상태를 receive 루프에 국한.

### B7. 백프레셔가 발화 중간 오디오를 무음 드롭 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:113`, `GeminiLiveTranslationService.swift:106`
- 결함: 전송 중 48개 초과 시 `reserveAudioSendSlot()` 실패 → 청크를 `continue`로 폐기.
- 실패 시나리오: 업링크 혼잡 시 발화 **중간의** 80-100ms 조각들이 사라져, 공급자는 구멍 난 오디오로 "자신 있게 틀린" 번역 생성. 사용자/델리게이트에 신호 전무.
- 수정: (a) 유한 링버퍼로 큐잉하고 가장 오래된 연속 구간 드롭, (b) 지속 고갈 시 델리게이트에 "네트워크 지연" 상태 통지.

### B8. 세션 간 슬롯 계정 오염 — Low
- 위치: OpenAI 115-116, 136행 / Gemini 108-109, 131행
- 결함: `stop()`이 `pendingAudioSendCount = 0`으로 리셋한 뒤, 이전 소켓의 in-flight 완료 콜백이 새 세션 카운터를 감소(최대 48회 유령 release).
- 수정: 전송 완료 클로저에 세션 세대 토큰 캡처, 이전 세대 release 무시.

### B9. Close code/reason 폐기 — Medium
- 위치: `GeminiLiveTranslationService.swift:262-267`, `OpenAIRealtimeTranscriber.swift:222-226`
- 결함: Gemini Live는 쿼터/인증/세션한도 문제를 주로 close 프레임 reason으로 전달하는데 `closeCode`/`closeReason`을 전혀 읽지 않음.
- 실패 시나리오: "API 키 무효"/"쿼터 초과"가 "작업을 완료할 수 없습니다"로만 표시 → 진단 불가.
- 수정: 수신 에러 시 `closeCode`/`closeReason`을 디코드해 표면화 에러에 포함.

---

## C. 비용 / 세션 한도

### C1. 무제한 연속 오디오 스트리밍, 세션 캡 없음 — High (비용)
- 위치: 양 서비스 `append()` 경로 (OpenAI:93-121, Gemini:82-114)
- 실패 시나리오: 세션 켠 채 자리 비움 → 밤새 8시간+ 무음이 유료 realtime 오디오 입력으로 과금.
- 수정: 클라이언트 측 유휴 감지(N분간 RMS 임계 미달 → 자동 일시정지+알림) + 설정 가능한 세션 시간 상한.

### C2. Gemini Live 세션 수명(`goAway`/재개) 미처리 — Medium
- 위치: `GeminiLiveTranslationService.swift:494-529`(디코드 모델), 135-155(setup)
- 결함: setup에 `sessionResumption`/`contextWindowCompression` 미설정, 디코드 모델에 `goAway` 필드 없음 → 서버의 종료 예고가 `try?`에 조용히 버려지고 세션이 대화 중 사망(B1 연쇄).
- 수정: `goAway`/`sessionResumptionUpdate` 디코드 추가, setup에서 재개 요청, `goAway` 수신 시 재개 핸들로 투명 재연결.

### C3. 일시정지 중 연결을 무기한 유지 — Low
- 위치: `OpenAIRealtimeTranscriber.swift:123-127`
- 수정: N분 이상 일시정지 시 연결 해제 후 재개 시 지연 재연결.

### C4. REST 번역기에 타임아웃/429 백오프 없음 — Low
- 위치: `OpenAITranslationService.swift:35`
- 결함: `URLSession.shared` 기본 60초 타임아웃이 캡션 파이프라인을 최대 1분 정지; 429/5xx는 재시도 없이 단발 실패.
- 수정: `timeoutIntervalForRequest ≈ 10s` 전용 세션 + `Retry-After` 존중하는 1회 지터 재시도.

---

## D. 프로토콜 정합성

### D1. OpenAI "translations" WS 엔드포인트/이벤트 패밀리가 공개 문서와 불일치 — High (검증 필요)
- 위치: `OpenAIRealtimeTranscriber.swift:77`(`wss://api.openai.com/v1/realtime/translations?model=…`), 581행(`session.input_audio_buffer.append`), 237-276행(`session.input_transcript.delta` 등)
- 결함: 공개 Realtime API는 `wss://api.openai.com/v1/realtime?model=…`(전사 분기 75행은 올바름), 클라이언트 이벤트 `input_audio_buffer.append`, 서버 이벤트 `conversation.item.input_audio_transcription.*` / `response.output_audio_transcript.*` 를 사용. `/v1/realtime/translations` 경로와 `session.*` 이벤트 패밀리는 문서에 없음.
- 실패 시나리오: `translationOnly` 모드가 404/close에 연결 → `try? decode` + `default: return`(287행)이 전부 삼켜 **무증상 실패**(마이크는 도는데 아무것도 안 나오고 에러도 없음).
- 수정: 최신 OpenAI 문서 대조 검증. 표준 Realtime API 대상이면 URL/이벤트 체계 교체. 최소한 예기치 않은 소켓 종료/미지 이벤트를 표면화.

### D2. 소켓 부재 시 설정 전송이 조용히 "성공" — Low
- 위치: `OpenAIRealtimeTranscriber.swift:203` (`guard let webSocketTask else { return }`)
- 수정: 소켓 없으면 throw.

### D3. ~~샘플레이트 불일치~~ → **오탐으로 정정** (레이턴시 감사에서 재검증)
- 원 주장: 상수 24kHz vs 캡처 16kHz 불일치. **실제로는 `TranslationSessionStore.swift:483-494`가 엔진별로 캡처 레이트를 전환**(`usesOpenAIRealtimeAudio ? 24_000 : 16_000`)하므로 OpenAI 경로는 진짜 24kHz 캡처 — 청크는 정확히 80ms, 피치 시프트 없음.
- 잔존 리스크(Low): OpenAI 세션이 `rate: 24000`을 선언(168행)하는데 485행 변경 시 조용히 깨짐 + 번역 모드는 포맷 자체를 미전송(180-196행). 단일 `AudioPipelineFormat` 진실 공급원(리뷰 03 H2)으로 해결.

### D4. 언어 코드를 `prefix(2)`로 절단 — Low
- 위치: `OpenAIRealtimeTranscriber.swift:588`, `GeminiLiveTranslationService.swift:553`
- 결함: 현 7개 언어는 무사하지만 3글자 코드("yue")나 스크립트 구분(zh-Hans/zh-Hant)이 조용히 뭉개짐.
- 수정: `Locale.language.languageCode` 또는 공급자별 명시 매핑 테이블.

### D5. Gemini 최상위 `{"error":{...}}` 프레임 처리는 추측성 사문 — Low
- 위치: `GeminiLiveTranslationService.swift:276-284, 527-529`
- 수정: B9 구현이 본질; JSON error 경로는 실측되면 유지.

---

## E. JSON 파싱 / 무음 데이터 유실

### E1. `try?` 디코드가 이상 프레임을 무기록 폐기 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:230-233`, `GeminiLiveTranslationService.swift:271-274`
- 결함: 스키마 변경/비UTF8 프레임 시 무음 폐기. 특히 OpenAI 수신 루프는 `.data`(바이너리) 메시지를 통째로 무시(220행) — Gemini는 처리함(256-258행).
- 실패 시나리오: 공급자의 사소한 스키마 변경 → 캡션이 그냥 멈춤, 에러도 로그도 없음 → 지원 불가능한 버그.
- 수정: OpenAI 루프에도 `.data` 처리 추가; 디코드 실패를 os_log(내용 마스킹)로 계수, N회 연속 실패 시 "프로토콜 오류" 상태 표면화.

### E2. 빈 transcript의 `completed`가 델타 버퍼를 방치 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:252, 271-272`
- 결함: `guard let transcript, !transcript.isEmpty else { return }`이 아래의 버퍼 리셋까지 건너뜀.
- 실패 시나리오: 속삭임/무발화 턴이 빈 completed로 끝나면 `realtimeTranscriptionText`가 남아, 다음 발화 델타가 이전 문장에 **이어 붙어** 캡션에 표시.
- 수정: `completed` 수신 시 transcript 유무와 무관하게 버퍼/`lastPublishAt` 리셋, 빈 경우 publish만 생략.

### E3. 스로틀에 트레일링 플러시 없음 — Low
- 위치: `OpenAIRealtimeTranscriber.swift:292-320`
- 결함: 마지막 publish 후 80ms 내 델타는 버퍼링만 되고, 이후 델타/completed가 안 오면 마지막 단어들이 무기한 미표시.
- 수정: 80ms 후 dirty면 publish하는 원샷 트레일링 플러시.

### E4. 델리게이트 콜백마다 새 `LiveSpeechTranscriber` 할당 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:357-359` (`proxyTranscriber`), 비용 근거 `LiveSpeechTranscriber.swift:52-75`
- 결함: 매 델타/청크/에러마다(초당 12회+) AVAudioFormat+48슬롯 버퍼 배열을 가진 무거운 객체를 새로 생성. `===` 동일성 비교하는 델리게이트는 영원히 불일치.
- 수정: 델리게이트 시그니처를 소스 enum/프로토콜로 변경하거나, 프록시 인스턴스 1개를 장수명 보유.

---

## F. 중복 코드

### F1. 두 스트리밍 서비스 간 ~200줄 복제 — Medium
- 위치: `OpenAIRealtimeTranscriber.swift:141-157, 361-438` ≡ `GeminiLiveTranslationService.swift:360-376, 378-455`
- 결함: 슬롯 계정, CMSampleBuffer→PCM16 변환, base64 청킹이 그대로 복제(청크 상수만 상이). 이미 동작이 갈라짐: Gemini엔 연결 대기/재시도(B3/B4)와 `.data` 처리(E1)가 있고 OpenAI엔 없음.
- 수정: 공용 `PCM16AudioChunker`(변환+청킹) + `WebSocketAudioSender`(슬롯+전송+연결대기) 추출.

### F2. Float→Int16 변환의 반올림/비대칭 — Low
- 위치: `OpenAIRealtimeTranscriber.swift:412`, `GeminiLiveTranslationService.swift:429`
- 수정: F1 추출 시 `Int16((clamped * 32767).rounded())`로 정리.

---

## G. Apple / 로컬 서비스

### G1. 가용성 캐시 무기한 (부정 결과 포함) — Medium
- 위치: `AppleTranslationService.swift:88-97`
- 실패 시나리오: "미지원 쌍" 에러 → 사용자가 시스템 설정에서 언어팩 다운로드 → 재시도해도 **앱 재시작 전까지 계속 실패** (캐시가 88-90행에서 단락).
- 수정: `.installed` 외 상태는 캐시하지 않거나 TTL/`prepare()` 시 무효화.

### G2. unsupported 이중 처리(사문) — Low
- 위치: `AppleTranslationService.swift:94-96` throw 후 26-28, 60-62행에서 재확인
- 수정: throw 또는 상태 반환 중 하나로 통일, 사문 제거.

### G3. `TranslationSession` 캐시 무기한 — Low
- 위치: `AppleTranslationService.swift:100-112`
- 수정: translate 실패 시 해당 캐시 세션 축출 후 재구성.

### G4. 폴리셔: 청크 1개 실패가 전체 폐기 + 취소 불가 — Low
- 위치: `FoundationTranscriptPolisher.swift:21-27`
- 실패 시나리오: 8청크 중 7번째가 throw(가드레일 거부 등) → 앞서 다듬은 결과 전부 폐기; 초대형 전사는 취소 없이 ANE를 수 분 점유.
- 수정: 청크별 catch 후 원문 폴백(25행의 빈 응답 폴백과 대칭), 청크 사이 `Task.isCancelled` 확인.

### G5. 폴리셔 프롬프트 인젝션 — Low
- 위치: `FoundationTranscriptPolisher.swift:96-102`
- 결함: 전사 텍스트를 프롬프트에 직접 보간 → 발화로 지시문 주입 가능(로컬 모델·로컬 출력이라 저위험).
- 수정: 명시적 구분자(begin/end 마커)로 감싸고 "사이는 데이터"로 지시.

### G6. `downloadSpeechAssets`가 미지원 로케일에서도 무음 성공 — Low
- 위치: `ModelAvailabilityChecker.swift:124-131`
- 수정: 미지원 로케일이면 서술적 에러 throw.

---

## H. 테스트

### H1. 스트리밍 프로토콜 테스트가 Gemini 해피패스뿐 — Medium
- 위치: `Tests/AirTranslateCoreTests/GeminiLiveTranslationServiceTests.swift:1-103`
- 결함: `OpenAIRealtimeTranscriber.handleEventText` 테스트 전무(델타 버퍼링/스로틀/E2 버그는 이벤트 시퀀스 테스트로 잡혔을 것), error 프레임/interrupted/키스토어 왕복/슬롯 계정 미검증.
- 수정: 시퀀스 테스트 추가 — 예: delta→빈 completed→delta에서 이전 문장 미결합 단언.

### H2. 프로브 델리게이트 레이스는 테스트로 불가시 — Low
- 위치: 동 파일 63-103행
- 수정: CI에서 핵심 테스트를 TSan으로 실행.
