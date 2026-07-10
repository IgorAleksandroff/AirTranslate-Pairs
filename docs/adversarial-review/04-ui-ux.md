# 적대적 리뷰 04 — UI / UX / 접근성 / 현지화

> 대상: `Views/*` 전체, `Support/*` 전체, `AppText.swift`, `AirTranslateApp.swift`
> 리뷰일: 2026-07-06

## 최우선 순위 (Top Priorities)

| 순위 | ID | 요약 | 심각도 |
|---|---|---|---|
| 1 | H1 | 메인 윈도우 닫은 뒤 종료하면 **전사 저장 훅이 안 돌아 데이터 유실** | Critical |
| 2 | A8 | 플로팅 캡션에 배경 스크림 없음 → 밝은 배경에서 **판독 불가** (설정 프리뷰와 불일치) | High |
| 3 | A1/A2 | 캡션 창이 토글마다 위치를 잊음 + 좀비 중복 구현 존재 | High |
| 4 | E1-E3 | API 키: 검증 없음, 피드백을 공유 status 문자열에서 긁어옴, 원클릭 무확인 삭제 | High |
| 5 | B1/G3/H4/C2 | status/오디오레벨 파이어호스가 사이드바·툴바·메뉴바 아이콘 재조립 폭풍 유발 | High |

---

## A. 플로팅 캡션 창 (Support/ + FloatingCaptionWindowView)

### A1. 숨김/표시 토글마다 창 위치 소실 — High
- 위치: `FloatingCaptionWindowController.swift:42-46`
- 결함: `close()`가 `window = nil` → 다음 `open()`이 `makeWindow` + 최초 위치 재계산. 실행 간 위치 영속화도 전무.
- 실패 시나리오: 화상회의 창 밑에 캡션을 끌어다 놓음 → 쉬는 시간에 숨김 → 다시 표시 → 메인 화면 하단 중앙으로 스냅백.
- 수정: close 시 패널 인스턴스 유지(`orderOut(nil)`), 프레임을 UserDefaults에 저장/복원(보더리스 패널엔 `setFrameAutosaveName` 불안정 — `NSStringFromRect` 수동 저장 + `NSScreen.screens` 대조로 오프스크린 복원 방지).

### A2. 플로팅 캡션 창의 경쟁 구현 2개 — High
- 위치: `AirTranslateApp.swift:23-39`(SwiftUI `Window` scene) vs `FloatingCaptionWindowController.swift`
- 결함: 아무도 `openWindow(id: .floatingCaptions)`를 호출하지 않는 SwiftUI scene이 Window 메뉴에 등록되고, 설정도 다름(activating, Cmd-` 순환 참여). `closeOrphanFloatingWindows`(92-99행)는 이를 죽이기 위해 존재하며 **제목이 현지화된 "Floating Captions"와 같은 아무 창이나** 매칭.
- 실패 시나리오: Window 메뉴에서 scene 창을 열면 activating 중복 캡션 뷰 생성; 패널을 열면 조용히 닫힘.
- 수정: `Window` scene 삭제(+ `defaultWindowPlacement`), 소유자 하나만 유지. scene 삭제 시 `closeOrphanFloatingWindows`와 제목 매칭 휴리스틱도 제거 가능.

### A3. 창 변조 부작용이 매 SwiftUI 업데이트(=매 전사 델타)마다 실행 — Medium
- 위치: `FloatingWindowConfigurator.swift:12-37`
- 결함: `updateNSView`가 캡션 스트리밍 중 초당 여러 번 발화 → `identifier`/`level`/`collectionBehavior`/`minSize` 재할당 + `keepWindowVisible` → `setFrame`.
- 실패 시나리오: 사용자가 패널을 화면 밖으로 반쯤 끌어 치우는 중 캡션 갱신이 프레임을 다시 안으로 **홱 끌어당김** — 사용자 손과 싸움.
- 수정: Coordinator에 마지막 입력값 저장해 실제 변경 시에만 실행; 위치 클램프는 렌더가 아니라 `didChangeScreenParametersNotification` 시점에.

### A4. 창 구성 코드 중복 + 이미 갈라짐 — Medium
- 위치: `FloatingWindowConfigurator.swift:16-24` vs `FloatingCaptionWindowController.swift:68-81` — 컨트롤러는 `.ignoresCycle` 포함, 컨피규레이터는 미포함.
- 수정: 단일 `configure(_ panel:)` 공용 함수 또는 컨피규레이터 제거.

### A5. "원문+번역" 모드에서 원문 비고 번역만 있으면 아무것도 안 그림 — Medium
- 위치: `FloatingCaptionWindowView.swift:41-58`
- 결함: 렌더링 전체가 `!sourceText.isEmpty` 가드 뒤, 폴백 분기는 둘 다 빈 경우만 처리. provider-realtime 모드에선 `floatingSourceText`가 정당하게 빈데 번역은 존재 가능(스토어 1092-1115행).
- 수정: `else if sourceText.isEmpty && !translationText.isEmpty` 분기 추가.

### A6. `floatingSourceText`/`floatingTranslationText`가 body 평가당 4-6회 재계산 — High
- 위치: `FloatingCaptionWindowView.swift:70-101` → `floatingCaptionTail`(스토어 1576행) → `FloatingCaptionTextFormatter.swift:20-41`
- 결함: 접근마다 NSRegularExpression 치환 + 문자별 폭 누적(최대 `maxLines × 288`자)이 실행되는데 body가 매 전사 토큰마다 돎.
- 실패 시나리오: 6줄·특대 캡션 + 빠른 발화 → 초당 10회+ × ~6회 정규식이 메인 스레드에서 오디오 콜백과 경쟁.
- 수정: body 상단에서 로컬 let으로 1회 계산, 이상적으론 스토어가 포맷된 tail을 캐시하고 텍스트/줄수/크기 변경 시에만 무효화.

### A7. 전체 창 드래그 표면이 모든 마우스 입력 흡수 + 드래그 메커니즘 중복 — Medium
- 위치: `FloatingCaptionWindowView.swift:7-24` + `FloatingCaptionDragSurface.swift:23-25`
- 결함: `hitTest`가 모든 지점에서 self 반환 → 19행 `WindowDragGesture()`와 20행 `allowsWindowActivationEvents`는 사문, 창 안의 어떤 것도 클릭 수신 불가. 창 자체에서 닫을 방법도 전무(호버 닫기, 우클릭 메뉴 없음).
- 수정: 드래그 메커니즘 하나 삭제(nonactivating 패널엔 AppKit 표면이 동작하는 쪽), `DragView`에 `menu(for:)`/`rightMouseDown`으로 "캡션 숨기기" 제공.

### A8. 캡션 배경 스크림 없음 — 판독성이 배경에 전적으로 의존 — High
- 위치: `FloatingCaptionWindowView.swift:103-119`, 배경 투명(Controller:78-80)
- 결함: 흰 텍스트 + 그림자 2개뿐. 설정의 `FloatingCaptionPreview`(SettingsView.swift:1044-1057)는 `.black.opacity(0.72)` 필 위에 캡션을 보여주는데 **실제 창엔 그 필이 없음**.
- 실패 시나리오: 흰 문서/밝은 영상 위에 캡션 → 흰 배경 위 흰 글자 — 캡션 제품의 핵심 사용례에서 기능 상실.
- 수정: `.black.opacity(0.6-0.75)` 라운드 배경(사용자 토글 가능) 렌더 — 프리뷰와 일치시키기.

### A9. 캡션이 VoiceOver에 라이브 콘텐츠로 보이지 않음 — Medium
- 위치: `FloatingCaptionWindowView.swift` 전체 — 라벨/`.updatesFrequently`/announcement 전무, `.nonactivatingPanel`이라 VO 도달 자체가 어려움.
- 수정: `.accessibilityElement(children: .ignore)` + 원문/번역 결합 라벨 + `.updatesFrequently`, 확정 라인만 announcement 게시 검토.

### A10. 재오픈 시 패널 재사용해도 `NSHostingView` 교체 — Low
- 위치: Controller 31-32행 — 뷰 상태(스트리밍 애니메이션) 폐기 + 재할당. 재오픈 시 `orderFrontRegardless()`만.

### A11. 최초 위치가 `NSScreen.main`만 사용 — Low
- 위치: Controller 83-90행 — 멀티 디스플레이에서 마지막 사용 화면 기억 없음(A1과 복합). 영속 프레임으로 복원.

### A12. 문자 폭 모델이 비ASCII 전부를 1.0으로 취급 — Low
- 위치: `FloatingCaptionTextFormatter.swift:7-17` — é/ü 등 악센트 라틴 오분류 → 랩 지점 불일치 → `.truncationMode(.tail)`이 꼬리 텍스트를 조용히 삼킴.
- 수정: 실제 폰트로 `NSLayoutManager` 측정 또는 최소한 Unicode East Asian Width 기반 버킷.

---

## B. 메뉴바 (MenuBarPanelController / Installer / MenuBarStatusView)

### B1. 메뉴바 아이콘이 SwiftUI 업데이트 안에서 매번 재렌더(디스크 읽기 포함 가능) — High
- 위치: `MenuBarPanelInstaller.swift:11-13` + `MenuBarPanelController.swift:37-41, 100-114`
- 결함: `updateNSView` → `install` → `update(session:)` → `rootView` 재할당 + `MenuBarMiniAppIconRenderer.image()`가 **매 호출마다 icns 디코드 + 18px 리드로**. `ContentView`가 `statusMessage`를 읽는데 스토어는 캡션 없을 때 매 오디오 콜백마다 이를 재작성(스토어 3634-3636행) → "발화 대기" 단계에서 초당 여러 번 실행. `updateNSView` 안 AppKit 변조는 state-modification-during-update 위험이기도 함.
- 수정: 렌더된 `NSImage`를 `static let` 캐시; 설치를 `applicationDidFinishLaunching`으로 이동하고 `MenuBarPanelInstaller` 삭제; 값이 실제 변한 경우에만 toolTip/접근성 타이틀 갱신.

### B2. running/paused 변경마다 status item 파괴·재생성 — Medium
- 위치: Controller 124-138행 (`refreshStatusItemPositionIfNeeded` — removeStatusItem 후 재추가)
- 실패 시나리오: 캡처 시작 → 메뉴바 아이콘이 깜빡 사라졌다 다른 슬롯에 재등장 가능, 열려 있던 팝오버는 앵커 고아화. 아이콘이 상태 무관 동일하므로 관찰 가능한 이득 전무.
- 수정: 함수 삭제; 상태별 아이콘 원하면 `button.image` 제자리 교체.

### B3. "AppleInterfaceStyle" UserDefaults로 수동 다크모드 감지 — Medium
- 위치: Controller 116-122행 — 시스템 "자동" 외관에선 키가 없어 다크 메뉴바에 aqua 강제.
- 수정: `button.appearance` 설정 자체를 제거(status bar 버튼은 올바른 외관 상속) 또는 `NSApp.effectiveAppearance.bestMatch(from:)`.

### B4. 팝오버 `contentSize` 360×430 하드코딩 — Low
- 위치: Controller 17행 — 콘텐츠는 동적(실행 중 타일 추가, 현지화 길이). `sizingOptions = [.preferredContentSize]`.

### B5. "View" 타일이 토글인데 라벨은 "Show Floating Captions" — Medium
- 위치: `MenuBarStatusView.swift:57-71`
- 실패 시나리오: 캡션 표시 중 VO 사용자가 "Show... ON"을 듣고 앞으로 가져오려 활성화 → 오히려 숨겨짐.
- 수정: 상태 의존 라벨(`isFloatingCaptionVisible ? hide : show`) + 중복 "Hide" 타일(73-85행, 열린 게 없어도 활성) 삭제.

### B6. Start/Stop 타일이 `isSelected: !session.isRunning` — Low
- 위치: 101-111행 — 유휴 상태가 하이라이트로 렌더되어 어포던스 반전. `isSelected: session.isRunning`.

### B7. 메뉴바 표면에서 Quit/설정/키보드 접근 불가 — Medium
- 위치: MenuBarStatusView 전체 + Controller 86행(`.leftMouseDown`만 응답)
- 실패 시나리오: 메인 창 닫은 사용자가 종료하려면 메인 창을 다시 열어 앱 메뉴 사용해야 함.
- 수정: 우클릭 `NSMenu`(Quit/Settings) — `sendAction(on: [.leftMouseDown, .rightMouseDown])` 분기, 또는 팝오버 푸터 행.

### B8. `LazyVGrid(.adaptive)` 열 수가 Pause 타일 등장 시 리플로우 — Low
- 위치: 56행 — 캡처 시작 시 5번째 타일 삽입으로 포인터 밑 타일 재배치. 고정 열 또는 비활성 슬롯 예약.

---

## C. CaptionBoardView

### C1. `TimelineView(.animation(minimumInterval: 0.08))`가 유휴/비가시 상태에서도 영원히 12.5fps 틱 — Medium
- 위치: 662행, 550행(`opacity(isRunning ? 1 : 0)`으로 항상 계층에 존재)
- 실패 시나리오: 메인 창 밤새 열어둠 → 아무것도 안 하며 CPU/에너지 소모(Activity Monitor에 표시).
- 수정: `paused: !isRunning || isPaused` + 미실행 시 스트립 자체를 계층에서 제거(opacity 대신 뷰 스왑).

### C2. `latestAudioLevel`이 매 오디오 버퍼 콜백마다 헤더 재렌더 — Medium
- 위치: 44행 + 스토어 3630/3680행, 693행 `.animation(.spring, value:)`가 버퍼당 새 스프링 시작(초당 수십).
- 수정: 스토어에서 발행 스로틀(최대 10Hz, >1dB 변화 시만), TimelineView가 샘플링하도록.

### C3. `ForEach(session.lines)`가 토큰마다 전체 배열 diff (전체 문자열 Equatable) — Medium
- 위치: 89-99행 — 매 partial 갱신이 `lines[last]` 교체 → SwiftUI가 전 행 diff, `CaptionLine` 합성 `==`가 행당 최대 4,000자 비교.
- 수정: `CaptionLineView: Equatable`을 `(id, revision, showsTranslationPane)` 키로 + `.equatable()`, `CaptionLine.==`을 id+revision으로 캡 검토.

### C4. 자동 스크롤 onChange 2개 중복 발화 — Low
- 위치: 101-113행 — 새 라인이 id와 revision 둘 다 변경 → 같은 프레임에 두 핸들러. 103행 즉시 스크롤이 두 번째 핸들러의 250ms 코얼레싱 무력화. 단일 onChange로 통합.

### C5. `ScrollableTranscriptText` 변경 감지가 동일 길이 변경 놓침 — Medium
- 위치: 372-380행 — `revision`/`utf16.count` 비교라 린트가 "teh "→"the " 같은 동일 길이 치환 시 stale 텍스트 표시.
- 수정: 이미 383행에서 계산하는 `textView.string != text`를 권위로.

### C6. Reduce Motion 미존중 — Low
- 위치: 95-99행 라인 전환 + 헤더 스프링, ContentView 토스트, 복사 피드백 — `StreamingTranscriptText`만 존중. `accessibilityReduceMotion` 읽어 전환/스프링 제거.

### C7. `TranscriptPane` 높이 360 하드코딩 — Low
- 위치: 246행 — 최소 560pt 창에선 비좁고 큰 화면에선 절반 낭비. `frame(minHeight: 240, maxHeight: .infinity)`.

### C8. 복사 피드백 `Task.sleep`이 disappear 시 미취소 — Low
- 위치: 277-287행 (+ `TranscriptLibraryView.swift:346-356` 중복). `.task(id:)` 기반 공용 모델로.

---

## D. StreamingTranscriptText

### D1. body 평가마다(10-18ms 간격) 2런 `AttributedString` 신규 구성 — High
- 위치: 56-62행 — `settledText` 2,400자 근처에서 최대 ~100Hz로 전체 attributed 문자열 할당+레이아웃, 플로팅 창에선 원문+번역 **2개 인스턴스 동시**.
- 수정: `Text(settled) + Text(appearing).foregroundColor(...)` 연결(캐시 유리) 또는 settled Text 메모이즈; 더 좋게는 접미 Text 오버레이에 `.opacity`만 애니메이트해 문자열 재계산 제거.

### D2. UTF-16 길이와 Character 수 혼용 — Medium
- 위치: 102행 — `utf16.count`로 게이트하고 `dropFirst(visibleText.count)`(grapheme)로 슬라이스. 이모지/결합 자모에서 괴리 → 빈 `remainingText`로 애니메이션 고착 또는 스킵.
- 수정: 한 가지 통화로 통일 — `hasPrefix` 후 `newText[visibleText.endIndex...]` + `count` 비교.

### D3. 재타깃 시 반투명 텍스트가 풀 불투명으로 스냅 — Low
- 위치: 114-139행, 72-75행 — ASR 갱신마다 가시적 플리커. 새 스트림이 현재 가시 상태에서 이어가도록.

### D4. disappear 시 flush 없이 cancel — Low
- 위치: 20, 31-33행 — 재등장 시 전체 델타 재애니메이션. onDisappear에서 settle.

---

## E. SettingsView (1,314줄)

### E1. API 키 "검증" 부재 + 피드백을 공유 `statusMessage`에서 스크랩 — High
- 위치: 642-664행 + 스토어 680-716행
- 실패 시나리오 1: 잘린 키 붙여넣기 → "Keychain에 저장됨" 초록불 → 실패는 몇 분 뒤 회의 중 암호 같은 연결 에러로 표면화. 시나리오 2: 캡처 중 오디오 콜백이 save와 read 사이에 statusMessage 재작성 → "Receiving Mac audio (48000 samples)..."가 빨간 피드백으로 표시(현재는 둘 다 메인 액터라 희박하지만 리팩터 한 번이면 레이스).
- 수정: 스토어 메서드가 typed `Result` 반환 → 그걸로 피드백 렌더; 비동기 "키 확인" 단계(저렴한 models 리스트 요청 1회) + 스피너 + 명시적 무효 키 에러.

### E2. 피드백 색을 현지화 상수와 문자열 동등성으로 결정 — High
- 위치: 614-640행 — `if apiKeyFeedback == AppText.openAIAPIKeySaved { return .green }`. 카피 수정이나 다른 경로(OSStatus 에러 텍스트)의 문자열이면 색이 무너짐. E1과 동일 근본 원인(stringly-typed 채널).

### E3. "API 키 제거"가 확인 없는 원클릭 파괴 동작 — Medium
- 위치: 171-178 / 521-528행 — 휴지통 아이콘이 저장 버튼에서 8pt 거리. 오클릭 시 복구 불가.
- 수정: 전사 전체삭제 플로우처럼 `confirmationDialog`.

### E4. SecureField에 `.onSubmit` 없음 — Low
- 위치: 158 / 508행 — 붙여넣고 Return 습관이 조용히 무시됨. `.onSubmit(saveOpenAIAPIKey)`.

### E5. `apiKeyFeedback` 영구 잔존 — Low
- 위치: 6-9행 — 하루 뒤 돌아와도 "방금 저장된 것처럼" 표시. 카테고리 변경 시 클리어 또는 자동 만료.

### E6. 설정 루트 `frame(width: 900, height: 650)` 고정 — Medium
- 위치: 31행 — macOS 텍스트 크기 접근성 확대 시 라벨(1242행 `width: 208`) 절단. `frame(minWidth:minHeight:)` + Grid로.

### E7. 설정 사이드바가 키보드로 사용 불가 — High
- 위치: 934-989행 — 카테고리 버튼 9개 전부 `.focusable(false)` + `.focusEffectDisabled()` → Full Keyboard Access/Tab이 도달 불가, **키보드 전용 사용자는 General 패널을 영영 못 벗어남**.
- 수정: 해당 모디파이어 제거, `List(selection:)`으로 구현(방향키/VO 컨테이너/선택 트레잇 무료). 동일 안티패턴: `SidebarView.swift:557-558, 579-580, 683-684`.

### E8. 영구 `.disabled(true)` 토글을 라이브 설정처럼 표시 — Medium
- 위치: 139-145행 ("Auto-detect input") — VO는 이유 없이 "dimmed"만 읽음. 죽은 컨트롤 대신 안내 행("일시 사용 불가")으로.

### E9. 하드코딩 ASCII `"->"` — Low
- 위치: 136행 — 모든 언어에서 "English -> Korean". `AppText.languageSummary` 사용.

### E10. 동일 문자열 2개짜리 퇴화 localized 호출 — Low
- 위치: 688-690행 — `localized(english: "GPT Realtime", korean: "GPT Realtime")`. 상수화 또는 4개 언어 채우기.

### E11. 모놀리식 설정 파일 — Medium
- 위치: 파일 전체 — 9개 페이지 빌더 + 12개 private 컴포넌트 + 150줄 카피 enum. `SettingsCopy`와 `SettingsSidebarCopy`에 `liveTranslationVolume` 중복 정의(SettingsView:887, SidebarView:404).
- 수정: `Settings/` 폴더로 분할(카테고리별 파일 + `SettingsComponents.swift`), 카피는 `AppText`로 합병.

### E12. 플로팅 캡션 프리뷰가 실제 설정 미반영 정적물 — Low
- 위치: 1044-1062행 — 바로 아래 설정(크기/줄수/모드)이 프리뷰에 안 보임 + A8의 "거짓 스크림". `session` 설정값으로 구동.

### E13. `onAppear`/`onChange` 안에서 스토어 변조 — Low
- 위치: 33-36 + 666-673행 — `requestedSettingsCategoryID = nil` 뷰 업데이트 중 쓰기. `consumeRequestedCategory()` 패턴으로.

---

## F. TranscriptLibraryView

### F1. 개별 전사 삭제에 확인 없음 (전체 삭제엔 있음) — High
- 위치: 203-208행 — 사용자가 마우스 오가는 편집기 바로 밑 파괴 버튼, 원클릭 영구 삭제.
- 수정: 동일 `confirmationDialog` 또는 `FileManager.trashItem`으로 휴지통 이동(undo 가능).

### F2. 포커스 강탈 루프 — High
- 위치: 426-430행 — `focusedDraftEditor`가 설정만 되고 클리어 안 되며 `updateNSView`가 매번 first responder 재주장.
- 실패 시나리오: 원문 패널의 Writing Tools 버튼 클릭(→ `.source` 포커스 기록) → 번역 패널 클릭해 타이핑 → 바인딩 갱신마다 업데이트 패스가 **커서를 원문 패널로 되끌어감**.
- 수정: Coordinator에서 `textDidBeginEditing`/`didEndEditing`으로 양방향 동기화, 또는 Writing Tools 호출 후 클리어.

### F3. `updateNSView`마다 `@State` 딕셔너리 쓰기 예약 → 자기지속 업데이트 처닝 — Medium
- 위치: 412-414, 432-434행 — `onTextViewResolved`가 매 업데이트 패스에 `DispatchQueue.main.async` 상태 쓰기.
- 수정: `makeNSView`에서 1회만 해결, `dismantleNSView`에서 클리어. updateNSView에서 콜백 호출 금지.

### F4. 확인 다이얼로그 취소 버튼이 "Close" — Low
- 위치: 36행 — `AppText.cancel`(AppText.swift:71 존재)로 교체.

### F5. 760×500 고정 시트에 좌우 편집기 2개 — Low
- 위치: 28행 — 30분 전사를 ~230pt 폭 컬럼에서 편집. `minWidth/minHeight` + 리사이즈 가능하게.

### F6. 편집 중 전사 전환/목록 변동 시 미저장 편집 무음 폐기 — Medium
- 위치: 41-43 + 358-367행 — dirty 체크 없이 선택 변경. dirty 추적 + 확인 또는 전사 ID별 초안 스태시.

### F7. 전사 행에 선택 상태 접근성 값 없음 — Low
- 위치: 121-133행 — 색으로만 전달. `.accessibilityAddTraits(.isSelected)` 추가(SettingsView 977행처럼).

---

## G. SidebarView

### G1. 현지화된 status 문자열 부분 매칭으로 권한 감지 — High
- 위치: 365-368행 — `statusMessage.contains("permission") || contains("권한")`. **일본어("権限")/중국어("权限") UI에선 절대 매칭 안 됨** → 번역된 권한 에러를 읽는 바로 그 사용자들에게 프라이버시 설정 바로가기가 안 뜸. "permission" 포함 미래 메시지에 오탐도.
- 수정: 시맨틱 `session.needsPermissionAction: Bool` 노출(스토어는 readiness 상태를 앎) — UI 문자열 파싱 금지. 동병: 377/390행과 `CaptionBoardView.swift:585`의 `statusMessage == AppText.ready` 비교.

### G2. 부작용 있는 `onAppear`가 세션 상태 변조 — Medium
- 위치: 166-172행 — 사이드바 (재)등장마다 GPT 모드면 `usePreferredLanguageForOpenAIOutput()`이 사용자가 방금 고른 대상 언어를 조용히 재작성. `refreshMicrophoneInputDevices()`도 여기서만 실행 → 창 열린 채 USB 마이크 꽂으면 메뉴 미갱신.
- 수정: 1회성 설정은 스토어 init/start로, 디바이스 갱신은 `wasConnectedNotification`(또는 메뉴 열림 시), 선호 언어 적용은 모드 전환의 명시적 부작용으로.

### G3. StatusPill이 raw 파이어호스 상태를 렌더 + 콜백당 사이드바 전체 재조립 — Medium
- 위치: 38-43행 + 스토어 3634행 — "Receiving Mac audio (482000 samples, -23 dB)…"는 개발자 텔레메트리지 사용자 카피가 아님.
- 수정: `debugStatus` 분리, 필엔 상태 enum(Ready/Listening/Paused/Error) 렌더 + 상세 텍스트 스로틀.

### G4. 저장된 target == source 상태 방지 없음 — Medium
- 위치: 599-601행 — 대상 피커는 현 소스만 필터하나 스왑 엣지케이스/영속 상태로 동일쌍 가능 → Picker 선택에 매칭 태그 없음(체크마크 소실). 소스 피커는 무필터라 대상과 같은 소스 선택 허용 → 시작 시점에야 `sameLanguageTranslationUnavailable` 실패.
- 수정: `useQuickSourceLanguage`에서 쌍 유효성 강제(자동 스왑) + 즉시 반영.

### G5. `ProcessingEngine.current(for:)` body당 4회+ 재계산 — Low
- 위치: 447-448행 등 — 관찰 프로퍼티 다수 읽어 의존성 확대. body 로컬 1회 계산.

### G6. `.apple` 케이스의 `missingAPIKeyTitle`이 "OpenAI API key required" 반환 — Low
- 위치: 354-363행 — 현재 도달 불가하나 다음 리팩터의 지뢰. `""`/assert.

### G7. ja/zh에서 퀵설정 라벨 절단 — Low
- 위치: 81-93행(500행 `width: 86` 고정 라벨) — Grid 유연 컬럼으로.

---

## H. ContentView + AirTranslateApp

### H1. 전사 저장 종료 훅이 메인 윈도우 콘텐츠 안에 있음 — Critical
- 위치: `AirTranslateApp.swift:15-17` — `prepareForTermination()`이 `ContentView`의 `onReceive(willTerminateNotification)`에 배선.
- 실패 시나리오: 메뉴바 앱인데 메인 창은 닫힘 가능(마지막 창 닫히면 WindowGroup 콘텐츠 해체). 캡처 세션 중 메인 창 닫고(캡션은 플로팅 중) Dock에서 종료 → 구독자가 없어 `prepareForTermination` 미실행 → `autoSaveDescription`("캡처 중지 또는 앱 종료 시 저장")의 약속과 달리 **세션 전체 전사 유실**.
- 수정: 기존 `AppDelegate`에 `applicationWillTerminate(_:)`(비동기 저장이면 `applicationShouldTerminate`) 구현 + 세션 참조 주입.

### H2. `WindowGroup`이 하나의 세션을 공유하는 메인 창 다중 생성 허용 — Medium
- 위치: `AirTranslateApp.swift:11` — Cmd-N은 제거됐지만 Merge All Windows/dock 메뉴 등으로 중복 가능 → `MenuBarPanelInstaller` 2개가 컨트롤러를 동시 구동, 사이드바 2개가 G2 부작용 경쟁.
- 수정: 메인 scene을 `Window`(단일 인스턴스)로.

### H3. 전체 계층에 `.animation(value:)` 2개 — Medium
- 위치: `ContentView.swift:91-92` — 토스트 발화 시 서브트리의 모든 애니메이터블 프로퍼티에 암시 애니메이션 → "전사 저장됨" 토스트 뜨는 순간 새 캡션 행들이 스프링으로 **출렁**.
- 수정: 토스트 뷰에만 스코프하거나 변조 지점에서 `withAnimation`.

### H4. 툴바 `accessibilityValue(statusMessage)`가 오디오 콜백마다 툴바 재렌더 — Medium
- 위치: `ContentView.swift:35` — G3 수정의 스로틀/시맨틱 상태에 바인드.

### H5. 토스트 VO announcement 없음 + 잘못된 trait — Low
- 위치: 17-21행 — 일시적 토스트에 `.updatesFrequently`는 부적합. `toastSequence` 증가 시 `AccessibilityNotification.Announcement` 게시.

### H6. 플로팅 창 가시성을 3개 뷰가 각자 `@State`로 캐시 + NotificationCenter 동기화 — Low
- 위치: `ContentView.swift:57`, `CaptionBoardView.swift:6`, `MenuBarStatusView.swift:6` — 컨트롤러의 `@Observable` 프로퍼티 하나로 통합, 알림 배관 삭제.

---

## I. AppText.swift (현지화 아키텍처)

### I1. 수제 현지화 시스템이 플랫폼 기능 전부 포기 — High
- 위치: 파일 전체 (226키, eager `static let`)
- 결함: (a) 프로세스 시작 시 1회 해석·캐시 — macOS 앱별 언어 변경 시 재시작 전까지 동결, 안내 전무; (b) 번역가가 Swift 소스로 작업 불가; (c) `Locale.preferredLanguages.first`만 봐서 순서 폴백 무시(ja→ko→en 사용자가 ja 미제공 키에서 한국어가 아닌 **영어**를 받음); (d) String Catalog면 기존 번역 대상 언어들에서 es/fr/de가 공짜.
- 수정: String Catalog(`String(localized:)`)로 마이그레이션, 이행기엔 AppText를 얇은 파사드로. 이 하나가 I2-I4를 흡수.

### I2. 2인자 `localized(english:korean:)` 오버로드가 UI의 ~54%를 ja/zh 사용자에게 영어로 노출 — High
- 위치: 30-37행 — 226키 중 104개만 ja/zh 제공. 모델 상태(141-147행), 권한(613-617행), 전사 설정(458-491행), 라이브러리(483-545행), **모든 에러/상태 메시지(746-878행)** 는 영어 폴백.
- 실패 시나리오: 중국어 사용자가 일관된 zh 사이드바를 보다가 설정 → Transcript에서 전부 영어, 에러 다이얼로그는 항상 영어.
- 수정: 매트릭스 완성 또는 ja/zh 미지원이면 `interfaceLanguage`에서 제거해 일관된 영어 제공.

### I3. 복수형 처리 부재 — Medium
- 위치: 701-703행 — `"\(count) lines"` 전 수량 공통("1 lines"), 미래 ru/pl 복수 카테고리는 설계상 불가. String Catalog 자동 복수 변형 또는 stringsdict.

### I4. 한국어 조사 오류 — Low
- 위치: 683-690행 — `"\(detected)이 감지되었습니다"` — detected="영어"면 "영어이 감지되었습니다"(비문). 조사 중립 카피("감지된 언어: \(detected)") 또는 종성 인식 헬퍼.

### I5. 스크린샷 env-var 분기가 현지화 코어 안에 — Low
- 위치: 13-15행 (+ 스토어 404행) — 단일 `DemoMode` 플래그로 격리.

### I6. AppText 우회 인라인 문자열 산재 — Low
- 위치: SidebarView 82/99/127/181행, MenuBarStatusView 다수, SettingsView 1023행 + 파일별 private 카피 enum(`liveTranslationVolume` 중복 정의) — 검토 가능한 단일 문자열 테이블 부재, 동일 개념("Selected")이 독립 번역됨.
- 수정: 전 카피를 AppText(→ String Catalog)로 통합, 뷰별 카피 enum 삭제.
