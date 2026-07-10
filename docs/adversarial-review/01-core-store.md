# 적대적 리뷰 01 — TranslationSessionStore (코어 상태 저장소)

> 대상: `TranslationSessionStore.swift` (3,813줄 전체), `TranscriptTextProcessor.swift`, `Models/*` + 스레딩 맥락 확인용 캡처/전사 서비스
> 리뷰일: 2026-07-06

## 최우선 순위 (Top Priorities)

| 순위 | ID | 요약 | 심각도 |
|---|---|---|---|
| 1 | C1 | 취소된 디바운스 태스크가 **억제 대신 즉시 실행**됨 (`Task.isCancelled` 가드 누락) | Critical |
| 2 | C2 | `translationTask = nil` 무조건 클로버링 → 번역 루프 2개 동시 구동 | Critical |
| 3 | C3 | 오디오 큐 ↔ MainActor 간 캡셔너 참조 데이터 레이스 | Critical |
| 4 | H1 | 주기적 저장 없음 → **크래시 시 세션 전사 전체 유실** | High |
| 5 | H2 | Gemini 모드에서 Apple 경로 정리 로직이 저장 데이터 오염 | High |

---

## CRITICAL

### C1. 취소된 디바운스 태스크가 페이로드를 즉시 실행 — Critical
- 위치: `TranslationSessionStore.swift:2601-2605`(`scheduleTranscriptCleanup`), `2475-2478`(`scheduleFloatingPresentationAdvance`)
- 결함: `try? await Task.sleep(...)`이 `CancellationError`를 삼키고 `Task.isCancelled` 가드 없이 `organizeCurrentTranscript()` / `promoteQueuedFloatingPresentationIfReady()`로 낙하 → **cancel()이 억제기가 아니라 가속기로 동작**.
- 실패 시나리오: `appendCaption`(1925행)과 realtime 갱신 경로(3012, 3095행)는 "새 인식이 도착했으니 정리를 하면 안 되기 때문에" cancel하는데, 취소된 태스크의 sleep이 즉시 throw하고 정리가 곧바로 실행됨 → 발화 중간에 partial 커밋(`currentPartialText = ""`, 2647행), `committedSourceText` 재작성, 재번역 발사. -50dB 미만 무음 콜백(~초당 10회, 3638/3688행)과 결합하면 정규식+동기 `NSSpellChecker`(2724-2758행)를 포함한 무거운 재구성이 메인 스레드에서 초당 여러 번 실행 — UI 버벅임 + 인식기 재전송 시 전사 중복/왜곡. 플로팅 캡션 경로에서도 동일 결함이 dwell 타이머를 우회해 캡션 깜빡임 유발(2481-2498행).
- 수정: sleep 후 `guard !Task.isCancelled else { return }` (2087, 960행에 이미 쓰는 패턴). **2줄짜리 수정으로 가장 효율 높음.**

### C2. `translationTask = nil` 클로버링 → 동시 번역 루프 — Critical
- 위치: `TranslationSessionStore.swift:3211-3213, 3222` (`processPendingTranslationRequests`)
- 결함: 태스크가 자신이 현행 태스크인지 확인 없이 완료/취소 시 무조건 `translationTask = nil`.
- 실패 시나리오: `resetLiveSessionState`(1371행)가 태스크 A를 cancel → 새 캡션이 태스크 B 생성(3176행) → `translator.translate`에서 서스펜드돼 있던 A가 나중에 재개되어 `catch is CancellationError`에서 `translationTask = nil` → B의 등록이 지워짐 → 다음 `requestTranslation`이 태스크 C 생성 → **B와 C가 동시에 `latestTranslationRequest`를 소비**: 공급자 중복 호출(OpenAI 이중 과금), `updateTranslation` 교차 쓰기, `pendingTranslationSourceText` 오염(영구 비어있지 않음 → 3158행 가드로 번역 조용히 정지).
- 수정: 세대 카운터(`translationGeneration`)로 태그하고 `gen == translationGeneration`일 때만 nil 처리.

### C3. `nonisolated(unsafe)` 캡셔너 참조의 데이터 레이스 — Critical
- 위치: 선언 262-264행, 재할당 1263-1267행(`startCaptioners`), 읽기 3621-3624/3667-3670행(오디오 큐)
- 결함: `transcriber`/`openAITranscriber`/`geminiLiveTranslator`가 MainActor에서 재할당되는 동안 배경 DispatchQueue의 오디오 델리게이트가 무동기화로 읽음.
- 실패 시나리오: 오디오 흐르는 중 Stop→Start → 오디오 스레드가 읽는 순간 `startCaptioners()`가 쓰기 — UB. 최선: 정지된 옛 전사기에 버퍼 유입(세션 초입 오디오 유실), 최악: torn read 크래시. 게다가 모드와 무관하게 **매 버퍼를 3개 엔진 전부에 팬아웃**(낭비 + 각 엔진의 내부 "미시작" 가드에 의존).
- 수정: 락 보호(`OSAllocatedUnfairLock`)된 불변 "활성 캡셔너" 핸들을 `startCaptioners`에서 원자적으로 교체, 현재 모드 엔진에만 append.

---

## HIGH

### H1. 주기적 영속화 없음 — 크래시/강제종료/정전 시 전사 전체 유실 — High
- 위치: `stageTranscriptForSave`(1683-1694행, 메모리 전용), `flushPendingTranscriptSave`(1697-1724행)는 `stop()`(524행)/`prepareForTermination()`(652행)/자동감지 확인(611행)에서만 호출
- 실패 시나리오: 2시간 강의 세션 중 앱 크래시(또는 C1의 UI 프리즈로 사용자가 강제종료) → 디스크에 아무것도 안 써졌으므로 **앱의 핵심 산출물인 전사가 통째로 증발**.
- 수정: `activeAutosaveSourceText/TranslatedText`를 고정된 "현재 세션" 파일에 디바운스 기록(15-30초 또는 N자마다), `stop()` 시 최종 이름으로 승격.

### H2. Gemini 모드에서 Apple 경로 정리가 저장 데이터 오염 — High
- 위치: `scheduleTranscriptCleanup`(2596-2599행)이 `isUsingOpenAIRealtime`만 제외하고 Gemini는 미제외; 2608-2666, 1697-1701행
- 결함: `isUsingOpenAIRealtime`(343행)은 OpenAI 번역 모델만 확인 → Gemini 모드에서 무음 트리거(+C1로 인해 거의 상시) `organizeCurrentTranscript()`가 Gemini 라이브 라인에 대해 Apple 스타일 재구성 텍스트를 `committedSourceText`에 기록 — Gemini 파이프라인이 전혀 사용/갱신하지 않는 버퍼.
- 실패 시나리오: `flushPendingTranscriptSave`가 스테이징된 `activeAutosaveSourceText`(3130행) 대신 오염된 `visibleTranscript()`를 우선 → 저장된 "원문"이 마지막 정리 시점 기준이 되어 **그 뒤 발화 꼬리가 조용히 소실** + 번역 파일과 포맷 불일치.
- 수정: `scheduleTranscriptCleanup`/`organizeCurrentTranscript`를 `!isUsingProviderRealtimeTranslation`으로 가드, provider-realtime 모드에선 스테이징 텍스트를 절대 덮어쓰지 않기.

### H3. 단일 CaptionLine 무한 성장 + 인식 이벤트마다 전체 전사 재작성 — High
- 위치: `appendCaption`(1927-1973행, 세션 내내 `currentLineID` 1개 재사용), `CaptionLine.swift:26-36`
- 결함: 세션 전체가 하나의 계속 자라는 `CaptionLine`. 매 partial 인식마다 전체 전사 문자열 5개(`sourceText` 등)를 복사한 새 CaptionLine 생성 + O(n) `displayText` 재계산 — 초당 여러 번. 프레젠테이션 스로틀(2036-2047행)은 사용자가 옵트인해야 하는 `.thirtyMinutesOrMore` 모드에만 적용 → **기본 모드의 긴 회의는 스로틀 0**.
- 실패 시나리오: 90분 기본 모드 세션 → ~200KB 문자열이 인식기 콜백 속도로 5배 복사 + 전체 배열 변조로 모든 SwiftUI 옵저버 무효화 → 비치볼.
- 수정: 무음 경계에서 문단별 라인 분리, 크기 임계 초과 시 무조건 코얼레싱, display tail 지연 계산.

### H4. 번역 요청마다 전체 전사 재처리 + O(n²) 캐시 부기 — High
- 위치: `translateTranscript`(2848-2905행), 2955-2970행
- 결함: 갱신마다 누적 전사 전체를 순회 번역(캐시 히트 여부 무관), `rememberTranslationCacheKey`가 세그먼트·요청마다 `removeAll { $0 == key }`(키에 전체 세그먼트 텍스트 포함, 2944행), 축출 루프의 `while` 안 `contains`는 O(n²)이자 사문.
- 실패 시나리오: 500세그먼트 전사 → 인식 갱신마다 메인 액터에서 수백만 문자 비교.
- 수정: 마지막 확정 세그먼트 이후 꼬리만 번역, 순서 배열을 제대로 된 LRU(Dictionary+연결리스트 또는 세대 스탬프)로 교체.

### H5. `NSSpellChecker` 린트가 메인 액터에서 전체 전사 동기 실행 — High
- 위치: 2707-2758행 (`lintLine`/`correctUnknownWords` ← `organizeCurrentTranscript`)
- 실패 시나리오: 린트 켜짐 + 20k자 전사 + 무음 트리거(C1이면 상시) → `guesses(forWordRange:)`(사전 서비스 호출 가능)로 전체 텍스트 단어 순회 → 수백 ms 메인 스레드 정지, 캡션 프리즈.
- 수정: 스냅샷에 대해 detached task로 이동, 원본 미변경 시에만 결과 적용.

### H6. 저장 전사 편집 왕복이 파일을 4KB 프리뷰로 절단 가능 — High
- 위치: `selectSavedTranscript`(1142-1153행), `saveSelectedTranscriptEdits`(1155-1176행), 프리뷰 생성 1610-1617행, `loadTranscriptText` 1619-1622행
- 실패 시나리오: 파일이 비UTF8/일시적 읽기 불가 → `loadTranscriptText`(엄격 `.utf8` + `try?`)가 nil → 초안이 조용히 4KB 프리뷰가 됨(4096바이트 경계에서 멀티바이트 문자 절단 가능) → 사용자가 오타 하나 고치고 저장 → **수백 KB 원본이 4KB로 덮어써짐**. 에러 표면화 전무.
- 수정: "읽기 실패"와 "빈 파일" 구분 — 읽기 실패 시 편집 비활성화+에러 표시, 프리뷰는 UTF-8 경계에서 디코드.

---

## MEDIUM

### M1. `stop()`이 진행 중 `start()` 캡처 태스크와 완전 직렬화 안 됨
- 위치: 516-539행 vs 463-513행 — `start()`가 `systemAudioCapture.start(...)`(488행)에서 서스펜드된 동안 `stopCapture()`가 동시 실행 가능.
- 수정: `stop()`이 `captureStartTask`를 await/cancel 후 stopCapture (start가 captureStopTask를 기다리는 465-468행과 대칭).

### M2. 자동감지 확인 프롬프트가 오디오 콜백에 클로버링
- 위치: 2030-2033행 vs 3631-3634, 3681-3684행 — 일시정지 중 매 오디오 레벨 콜백이 `statusMessage`를 `AppText.paused`로 덮어씀 → 사용자가 일시정지 이유를 못 봄.
- 수정: `pendingAutoDetectionLanguageChange != nil`이면 status 덮어쓰기 금지.

### M3. 복원 시 OpenAI 전사 모드 강제 변환 + 미영속화 → 매 실행 반복
- 위치: 1531-1534행 — OpenAI 모델 사용 시 전사 `.off`/번역 `.gptRealtimeTranslate` 강제. `isRestoringSelectedSettings`가 persist를 억제해 UserDefaults엔 옛 값 유지 → 강제 변환이 영원히 반복.
- 수정: 저장된 조합을 존중하거나 1회 마이그레이션 후 영속화.

### M4. 모드/언어 변경이 `isRunning` 가드 없음
- 위치: 811-835행(`useGPTRealtimeMode`/`useGeminiTranslationMode`), 130-155행(프로퍼티 setter). 세션 중 변경 시 옛 캡셔너는 돌고 라우팅 가드만 뒤집힘 → 델타 무음 드롭, 캡션 정지, 발화 중 캐시/더빙 리셋.
- 수정: setter를 `!isRunning`으로 게이트(또는 변경 시 파이프라인 재시작).

### M5. 저장 전사 ID 충돌 + 페어 섀도잉
- 위치: 1624-1681행 — `X.txt`와 `X_original.txt/X_translation.txt` 공존 시 두 항목이 id `"X.txt"` 공유(Identifiable 충돌 + 선택 모호). 레거시 `X-original.txt`와 신형 `X_original.txt`가 같은 베이스에 매핑되어 한 파일이 라이브러리에서 사라짐(1815-1829행).
- 수정: 그룹 id 네임스페이스(`"pair:X.txt"`) + 두 접미사 스타일 공존 시 모두 유지.

### M6. 페어 저장 부분 실패 → 고아 원문 + 이후 중복
- 위치: 1714-1718행 — 원문은 써지고 번역 쓰기 실패 시 정리 없이 false 반환 → 다음 flush가 새 타임스탬프 베이스 생성 → 중복+고아.
- 수정: 실패 시 부분 파일 삭제 또는 temp+rename 페어.

### M7. `loadSavedTranscripts` 실패가 라이브러리를 무음 초기화
- 위치: 1605-1607행 — 일시적 FS 에러가 "전사 전부 삭제됨"으로 보임. 이전 목록 유지 + 에러 표면화.

### M8. `deleteSelectedTranscript`가 삭제 실패 삼킴
- 위치: 1227-1229행 — 목록에서 사라졌다가 다음 로드에 부활, 피드백 없음.

### M9. didSet 연쇄 + 오디오 프레임당 Observable 변조 폭풍
- 위치: 182-196행(Gemini 켜기 → 설정 전체 영속화+캐시 리셋+가용성 새로고침이 4-5회 연쇄), 118-129행(볼륨 슬라이더 틱마다 20키 UserDefaults 쓰기), 3628-3641행(오디오 콜백 10-100Hz로 `statusMessage` 등 변조 — `@Observable`은 동일 값이어도 발화).
- 수정: didSet 부작용 배칭(`applyModeChange()`), 영속화 디바운스, **값이 실제로 변한 경우에만 할당**.

### M10. stale `refreshModelAvailability` 결과의 일시적 덮어쓰기
- 위치: 1436-1443행 — 옛 태스크가 cancel 직전에 isCancelled 체크를 통과하면 이전 언어쌍의 가용성을 새 리셋 뒤에 적용. 세대 토큰으로 해결.

### M11. `accumulatedRealtimeText` 중복제거 휴리스틱의 오탐/누락
- 위치: 3078-3086행 — `hasSuffix` 일치 시 정당한 반복("yes yes") 폐기; 엄격 접두 확장이 아닌 수정 스냅샷은 겹침 중복. 캡션과 저장 전사 양쪽에 잔존.
- 수정: 공급자 세그먼트 ID 사용 또는 최장 suffix-prefix 겹침 병합.

### M12. 에러 문자열이 전사 콘텐츠에 주입됨
- 위치: `markTranslationUnavailable`(3307-3356행), `clearPendingTranslationPlaceholders`(1382-1403행) — `error.localizedDescription`이 `CaptionLine.translatedText`에 기록되어 번역 텍스트로 취급·표시. 시스템 전체가 `AppText.translating` 매직 센티널 문자열 비교에 의존(1096, 1109, 2386, 2669, 3332, 3465행).
- 수정: `CaptionLine`에 번역 상태 enum(`.pending`/`.translated(String)`/`.failed(String)`) 도입.

### M13. `TranscriptTextProcessor.originalIndex` O(n²) + 이벤트당 O(n) 정규화
- 위치: TTP:555-587행(문자 단위로 자라는 문자열에 `hasPrefix` 반복 — 커밋 길이의 제곱), TTP:393-397행(이벤트당 전체 텍스트 정규식 정규화 수 회).
- 수정: 정규화 커밋 텍스트 증분 추적, 인덱스 비교로 교체.

### M14. 종료 경로가 캡처 해체를 기다리지 않음
- 위치: 536-538행 + 649-653행 — `stopCapture()`가 행이면 아무도 관찰 안 함, 주황 마이크 표시/SCK 스트림 잔존 가능. reply-to-terminate-later로 await.

---

## LOW

- **L1** (3751-3755, 3805-3811행): 분리된 옛 캡셔너의 `didFail`이 "Stopped"를 stale 소켓 에러로 덮어씀. `isRunning || isStarting` 가드.
- **L2** (2955-2963행): 축출 루프의 `contains` 체크는 사문(키가 유일) — 중복이 생기면 오히려 영구 보존하는 방향. 삭제.
- **L3** (2944-2946행): 캐시 키 `\t` 결합 — 세그먼트에 탭 포함 가능(개행만 분리). 비출현 구분자 또는 구조화 키 해시.
- **L4** (1412-1422행): `warmTranslationSession` 실패가 "듣는 중…"을 raw 에러로 덮어씀 + self 강한 캡처, stop 시 미취소.
- **L5** (958-969행): 공지 dismiss 소유권을 현지화 문자열 동등성으로 판정 — 시스템 언어 변경 시 오작동. 토큰 사용.
- **L6** (1831-1846행): 파일명 후보당 5회 `fileExists` 시스콜을 stop() 중 메인 액터에서. 미용상.
- **L7** (`SavedTranscript.swift:55`): `replacingOccurrences(of: ".txt")`가 이름 중간의 ".txt"도 제거(`my.txt.notes.txt` → `my.notes`). `hasSuffix`+`dropLast`.
- **L8** (1583-1602행): 저장/편집마다 목록 전체 재구축 + 파일마다 첫 4KB 읽기(메인 스레드 I/O). 증분 갱신.
- **L9** (2452-2465, 3416-3434행): 플로팅 캡션 평가마다 `organizeTranscript` 정규식 실행, computed property가 렌더마다 호출.
- **L10** (581-592행): 일시정지 중 캡처 상시 가동(오디오 콜백이 풀레이트로 MainActor 태스크 생성). 의도라면 주석, 아니면 경량 경로.
- **L11** (96-98행): `isRunning`/`isStarting`/`isPaused` 3개 독립 Bool → 불가능 상태 허용. 단일 `enum SessionState { idle, starting, running, paused, stopping }`.
- **L12** (403-439행): Product Hunt 데모 훅이 프로덕션 스토어 안에 있고 `hasOpenAIAPIKey = false`까지 조작. `#if DEBUG` 또는 별도 픽스처로.

---

## God-object 분해 설계 (구체적 seam 12개)

현재 이 클래스는 **12개의 구분 가능한 책임**을 가짐. 각 seam은 이미 결합도가 낮아(소수의 문자열/플래그로만 통신) 스토어를 얇은 코디네이터로 남기고 추출 가능:

| # | 추출 대상 | 행 범위 | 비고 |
|---|---|---|---|
| 1 | **SettingsStore** | 7-29(키), 96-258(didSet), 1446-1563(복원/영속) | M9의 didSet 연쇄가 명시적 `apply(mode:)` 전이로 |
| 2 | **SessionLifecycleController** | 441-653, 1261-1320, 1565-1571 | L11 상태머신 + M1/C2 직렬화 수정 소유 |
| 3 | **ModelAvailabilityService** | 983-1076, 1425-1444 | 이미 클로저 주입(272-273행) — 즉시 추출·테스트 가능 |
| 4 | **TranscriptLibrary** (영속화) | 330-376, 1137-1259, 1582-1880 | H1/H6/M5-M8 흡수. 라이브 상태 의존은 스테이징 문자열 2개뿐 |
| 5 | **LiveTranscriptAccumulator** | 1882-2345, 2500-2544, 2559-2594 | TTP 위의 순수 상태머신 — 파일 내 최고 테스트 가치 |
| 6 | **FloatingCaptionPresenter** | 1078-1119, 2322-2498, 3358-3434 | `floating*` 필드 9개 + Task 1개로 자기완결 |
| 7 | **TranscriptOrganizer/Linter** | 2596-2846 | 메인 액터 밖으로 (H5) |
| 8 | **TranslationPipeline** | 2848-2975, 3139-3356 | C2/H4 수정 소유, LRU 캐시는 독립 소형 타입 |
| 9 | **ProviderRealtimeMerger** | 2977-3137 | M11 소유 |
| 10 | **DubbingController** | 3440-3617 | 인터페이스: `didUpdateTranslation(String)` + `reset()` |
| 11 | **AutoDetectionPolicy 런타임** | 47-77 + 604-647, 1989-2034, 2049-2065 | 5와 페어 |
| 12 | **델리게이트 어댑터 → AudioRouter** | 3620-3813 | 5/8/9 추출 후 3줄 포워더화, 팬아웃(C3)은 AudioRouter로 |

**권장 추출 순서 (노력 대비 리스크 감소):** 4(TranscriptLibrary) → 8(TranslationPipeline) → 6(FloatingCaptionPresenter) → 5(Accumulator). 각각은 `lines`/`statusMessage`/스테이징 문자열로만 상태를 공유해 오늘 기계적으로 분리 가능.

## 긴급 수정 요약

1. **C1**: 두 디바운스 태스크에 `Task.isCancelled` 가드 — 2줄로 메인 스레드 핫루프와 발화 중 전사 오염 제거.
2. **C2**: 번역 태스크 세대 토큰 — 동시 루프와 영구 번역 정지 방지.
3. **C3**: 오디오 큐에서 쓰는 캡셔너 참조 동기화.
4. **H1**: 라이브 전사 주기 저장 — 현 설계는 크래시에 전부 잃음.
5. **H2**: Gemini 모드를 Apple 정리 경로에서 제외 — 저장 시 데이터 유실/불일치 중단.
