# AirTranslate 적대적 리뷰 종합 보고서

> 리뷰일: 2026-07-06 · 기준: `master` @ `dd458cc` (v1.3.6) · 소스 14,816줄 / 테스트 1,021줄
> 방법: 영역별 심층 적대적 리뷰 6건(코어 스토어 / 네트워크·보안 / 오디오 / UI·UX·현지화 / 빌드·테스트·릴리스 / **엔드투엔드 레이턴시**) + `swift build`·`swift test` 실측 검증
> 총 발견: **약 240건** (Critical 6 · High 45+ · Medium 90+ · Low 다수)

## 문서 구성

| 파일 | 영역 | 핵심 발견 |
|---|---|---|
| [01-core-store.md](01-core-store.md) | TranslationSessionStore (3,813줄) | 취소가 실행을 가속하는 디바운스 버그, 번역 루프 이중화, 크래시 시 전사 전체 유실, god-object 분해 설계 12 seam |
| [02-network-security.md](02-network-security.md) | API 서비스 / WebSocket / 키 관리 | 키 URL 노출, 영어 문자열 에러 판별(비영어 사용자 시작 실패), 재연결 전무, 과금 폭탄 |
| [03-audio-pipeline.md](03-audio-pipeline.md) | 오디오 캡처 / 재생 | 마이크 피드백 루프(AEC 없음), SCStream 사망 미감지, 디바이스 변경 미처리, 버퍼 앨리어싱 |
| [04-ui-ux.md](04-ui-ux.md) | Views / Support / 현지화 | 종료 훅 데이터 유실, 캡션 판독성(스크림 없음), 키보드 접근 불가, ja/zh 54% 영어 노출 |
| [05-build-test-release.md](05-build-test-release.md) | 빌드 / 테스트 / 릴리스 | 릴리스가 dev plist 배포, 공증 없음, CI 전무, 테스트가 실 머신 상태 오염 |
| [06-latency.md](06-latency.md) | 엔드투엔드 레이턴시 (정량) | 플로팅 dwell 최대 3.6초, Gemini VAD 미설정 +0.5–1.5초, 더빙 드리프트 무제한, 경로별 레이턴시 버짓 테이블 |
| [07-latency-verification-and-upgrades.md](07-latency-verification-and-upgrades.md) | **레이턴시 재검증 + 업그레이드 카탈로그** | 06의 전 주장 라인 단위 재대조(전부 확정), 신규 발견 2건(dwell 중 MainActor 스핀 루프, 빈 completed×스로틀 결합), 사용자 시나리오 6종별 구현 스케치·절감치·실행 순서 |

---

## Critical 6건 (즉시 수정)

1. **취소된 디바운스 태스크가 페이로드를 즉시 실행** — `TranslationSessionStore.swift:2601-2605, 2475-2478`. `try? await Task.sleep` 후 `Task.isCancelled` 가드가 없어 cancel()이 억제 대신 **가속**으로 동작 → 메인 스레드 핫루프 + 발화 중 전사 오염. **2줄 수정.** → [01 · C1]
2. **번역 태스크 이중 구동** — `TranslationSessionStore.swift:3211-3222`. 옛 태스크가 새 태스크의 등록을 클로버링 → 중복 과금 + 번역 영구 정지 가능. 세대 토큰으로 해결. → [01 · C2]
3. **오디오 큐 ↔ MainActor 캡셔너 참조 데이터 레이스** — `TranslationSessionStore.swift:262-264, 1263-1267, 3621+`. `nonisolated(unsafe)` 참조를 무동기화 읽기/쓰기 — UB, 세션 초입 오디오 유실~크래시. → [01 · C3]
4. **메인 윈도우 닫으면 종료 시 전사 저장 안 됨** — `AirTranslateApp.swift:15-17`. `prepareForTermination()`이 ContentView의 `onReceive`에 배선 — 메뉴바 앱인데 창 닫으면 구독자 소멸 → Dock 종료 시 **세션 전체 유실**. `AppDelegate.applicationWillTerminate`로 이동. → [04 · H1]
5. **더빙 재생 큐 무제한 → 드리프트 무한 성장** — `OpenAIRealtimeAudioOutput.swift:64`, `TranslatedSpeechOutput.swift:29`. 밀집 발화 10분에 더빙이 **~1.5분 뒤처지고** 계속 벌어짐(OpenAI 경로엔 인터럽트/플러시도 없음). 백로그 2–3초 캡. → [06 · 7.1/7.2]
6. **번역 REST 60초 타임아웃이 단일 슬롯 파이프라인 정지** — `OpenAITranslationService.swift:35`. 요청 1건 행 → 캡션은 흐르는데 번역이 최대 1분 동결. 전용 세션 10초 타임아웃 + 스트리밍. → [06 · 5.2, 02 · C4]

> 참고: 레이턴시 감사에서 리뷰 02의 D3(샘플레이트 불일치)이 **오탐**으로 정정됨 — 스토어가 엔진별 캡처 레이트를 이미 전환함. [06 · §0]

## 크로스커팅 테마 (반복 발견된 구조적 문제)

1. **데이터 유실 표면이 넓음** — 주기 자동저장 없음(크래시=전부 유실), Gemini 모드 저장 오염, 4KB 프리뷰로 파일 절단, 종료 훅 소실, 무확인 삭제 2곳, 미저장 편집 무음 폐기. *전사가 이 앱의 핵심 산출물인데 보호 장치가 가장 약함.*
2. **Stringly-typed 상태** — 권한 감지를 현지화 문자열 부분 매칭으로(ja/zh에서 미동작), 소켓 에러를 영어 문구 매칭으로(비영어 사용자 Gemini 시작 실패), 번역 상태를 `AppText.translating` 매직 센티널로, API 키 피드백을 statusMessage 스크랩으로. → 시맨틱 enum/typed Result로 전환하는 하나의 방향성 있는 수정 계열.
3. **statusMessage/오디오레벨 파이어호스** — 오디오 콜백(10-100Hz)이 Observable을 무조건 재작성 → 사이드바·툴바·메뉴바 아이콘(icns 재디코드!)·캡션 창이 초당 수십 회 재조립. 스로틀 + 변경 시에만 할당 + 시맨틱 상태 분리.
4. **복원력 전무** — WebSocket 재연결/킵얼라이브 없음, SCStream 사망 미감지, 마이크/출력 디바이스 변경 미처리, Gemini `goAway` 미처리. *네트워크 순단이나 에어팟 배터리 하나로 세션이 조용히 죽는 앱.*
5. **복붙 중복** — 키 스토어 2×86줄, PCM 변환 ~200줄×2, 오디오레벨 ~75줄×2, 창 구성 2곳(이미 갈라짐), 카피 enum 파일별 중복. 이미 동작 드리프트 발생(Gemini엔 연결 대기 있고 OpenAI엔 없음).
6. **테스트 인프라 부재** — CI 없음, `swift test`는 CLT 환경에서 컴파일 불가(실측), 프로토콜 seam 없어 코어 상태머신 테스트 불가능, 기존 테스트는 실제 UserDefaults에 되쓰기.
7. **현지화 반쪽** — 226키 중 104개만 ja/zh 제공(에러/상태 메시지 전부 영어), 수제 시스템이 String Catalog의 복수형/폴백/도구를 전부 포기, 한국어 조사 오류.
8. **God object** — 스토어 3,813줄에 책임 12개. [01]에 행 범위까지 특정한 분해 설계와 추출 순서(TranscriptLibrary → TranslationPipeline → FloatingCaptionPresenter → Accumulator) 수록.
9. **레이턴시: 병목은 네트워크가 아니라 클라이언트 정책** — 엔진 자체는 0.3–1.2초 수준인데 플로팅 dwell(최대 3.6초), 타자기 애니메이션(final 버스트에 최대 0.7초), 80ms 스로틀 무플러시(꼬리 0.5초), Gemini VAD 미설정(+0.5–1.5초)이 그 위에 가산됨. [06]에 경로별 버짓 테이블과 수정 후 목표치 수록.

---

## 우선순위 로드맵

### P0 — 즉시 (저비용 · 고효과, 대부분 수 줄)
| 항목 | 위치 | 근거 |
|---|---|---|
| 디바운스 `Task.isCancelled` 가드 2곳 | 01·C1 | 2줄로 핫루프+전사 오염 제거 |
| 릴리스 plist `local`→`release` | 05·A1 | 한 단어 |
| 소켓 에러 코드 기반 분류(ENOTCONN) | 02·B4 | 비영어 사용자 Gemini 시작 실패 해소 |
| 빈 `completed` 시 버퍼 리셋 | 02·E2 | 캡션 문장 겹침 해소 |
| 종료 훅 AppDelegate 이동 | 04·H1 | 데이터 유실 |
| `git restore Release/GITHUB-RELEASE-*.md` | 05·A7 | 대기 중인 파괴적 삭제 |
| 번역 태스크 세대 토큰 | 01·C2 | 이중 과금/번역 정지 |
| 삭제 확인 다이얼로그(전사·API 키) | 04·F1/E3 | 원클릭 파괴 방지 |
| 80ms 스로틀 트레일링 플러시 | 06·4.1 | 발화 꼬리 ~0.5초 절감 |
| Gemini `realtimeInputConfig` VAD 설정 | 06·3.2 | 발화당 0.4–1.2초 절감 (Gemini 최대 레버) |
| 번역 세션 타임아웃 10초 | 06·5.2 | 60초 정지 계급 제거 |

### P1 — 단기 (1-2주 단위 작업)
- **주기 자동저장** (01·H1) + Gemini 저장 오염 수정 (01·H2) + 4KB 절단 수정 (01·H6) — 데이터 유실 3종
- **WebSocket 재연결 + 킵얼라이브 + close reason 표면화** (02·B1/B2/B9) — 세션 복원력
- **캡셔너 참조 동기화** (01·C3) + 스트리밍 서비스 락 정리 (02·B5/B6)
- **Gemini 키 → `x-goog-api-key` 헤더** (02·A1) + Keychain `kSecUseDataProtectionKeychain` (02·A2)
- **디바이스 변경 처리** — 마이크 연결해제 (03·C1), 출력 라우트 변경 (03·F1), SCStream delegate (03·B1)
- **캡션 배경 스크림** (04·A8) + 창 위치 영속화 (04·A1) + 중복 Window scene 제거 (04·A2)
- **status 파이어호스 스로틀** (01·M9, 04·B1/G3/H4/C2) + 시맨틱 상태 enum (04·G1)
- **레이턴시 P1 묶음** — 플로팅 dwell 캡 2.0초 + prefix 확장 제자리 갱신 (06·4.2), 타자기 애니메이션 ≤200ms 캡 (06·4.5), 더빙 백로그 캡 (06·7.1/7.2), Gemini 시작 재작업(ping 폴링 → 델리게이트, setup 전 오디오 버퍼링) (06·9.3)
- **CI 구축** (05·A3) + 테스트 격리 (05·B5) + 풀 Xcode 요구 문서화 (05·A4)
- **공증 파이프라인** (05·A2) + README Gatekeeper 안내 갱신

### P2 — 중기 (구조 개선)
- **스토어 분해** — [01]의 12-seam 설계, 추출 순서: TranscriptLibrary → TranslationPipeline → FloatingCaptionPresenter → LiveTranscriptAccumulator
- **프로토콜 seam 도입** (05·C1/C2) → 상태머신·이벤트 파서 테스트 스위트 (05·B1/B2)
- **중복 통합** — 제네릭 APIKeyStore (02·A4), 공용 PCM16Chunker/WebSocketAudioSender (02·F1), 오디오레벨 함수 (03·C4), 창 구성 (04·A4)
- **String Catalog 마이그레이션** (04·I1) + ja/zh 매트릭스 완성 (04·I2)
- **비용 안전장치** — 유휴 자동 일시정지 + 세션 시간 캡 (02·C1), Gemini `goAway`/재개 (02·C2)
- **마이크 AEC**(voice processing) 또는 더빙 중 게이트 (03·A1)
- **CaptionLine 상태 enum**(센티널 제거, 01·M12) + 라인 분할·번역 꼬리만 처리 (01·H3/H4)
- **키보드 접근성** — 설정 사이드바 `List(selection:)` 전환 (04·E7), VO 캡션 라벨 (04·A9)
- **AirTranslateCore 실질화** — 순수 로직 이동 (05·B6)

## 검증된 강점 (보정)

- API 키는 Keychain(`AfterFirstUnlockThisDeviceOnly`) + `SecureField` — 리포/코드에 시크릿 전무 (grep 검증).
- 스크립트 전반 `set -euo pipefail` + 안전한 경로 처리, 버전 표기 7곳 현재 일관(1.3.6/136).
- `excludesCurrentProcessAudio`로 시스템 오디오 모드의 자기 TTS 재캡처 차단; 실시간 렌더 스레드 위 작업 없음.
- `TranscriptTextProcessor`는 충실히 테스트됨; README 4개 언어 상호 일관.
