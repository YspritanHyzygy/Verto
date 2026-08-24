<p align="center">
  <img src="icon.png" width="128" alt="Verto 앱 아이콘" />
</p>

<h1 align="center">Verto</h1>

<p align="center">
  <a href="../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b> · <a href="README.es.md">Español</a>
</p>

<p align="center">텍스트 번역, 이중 언어 음성 대화, 카메라 번역을 제공하는 네이티브 SwiftUI iOS 앱입니다.</p>

---

## 빠른 시작

1. Xcode에서 `Verto.xcodeproj`를 엽니다.
2. `Verto` 스킴을 선택합니다.
3. iOS 17 이상이 설치된 iPhone 시뮬레이터를 선택합니다.
4. Run을 누릅니다.

추가 설정 없이 빌드할 수 있습니다. 온라인 중계를 설정하지 않은 빌드는 시스템 Translation 프레임워크를 사용합니다. 시스템 번역에는 iOS 18 이상의 실기기가 필요하며 시뮬레이터에서는 사용할 수 없습니다.

### 온라인 번역

온라인 번역은 `tools/translate-relay`의 Cloudflare Worker를 통해 Cloud Translation v3에 연결합니다. [`tools/translate-relay/README.md`](../tools/translate-relay/README.md)에 따라 중계를 배포하고 로컬 설정을 만듭니다.

```bash
cp Secrets.local.xcconfig.example Secrets.local.xcconfig
```

`Secrets.local.xcconfig`에 호스트와 공유 비밀을 입력합니다. 이 파일은 Git에서 제외됩니다. 저장소에 포함되는 `Secrets.xcconfig`에는 실제 인증 정보를 넣지 마세요.

### 명령줄 빌드

`xcode-select`가 Command Line Tools나 이전 Xcode를 가리키면 사용할 Xcode를 명시합니다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 프로젝트

- Xcode 프로젝트: `Verto.xcodeproj`
- 앱 이름: 중국어 간체 UI에서는 译境, 다른 UI 언어에서는 Verto
- UI 언어: 중국어 간체, 영어, 일본어, 한국어, 스페인어
- 문자열 카탈로그: `Verto/Localizable.xcstrings`, `Verto/InfoPlist.xcstrings`
- Bundle ID: `com.yspritan.verto`
- 최소 시스템: iOS 17
- 주요 프레임워크: SwiftUI, Observation, AVFoundation, PhotosUI, Speech, Translation
- 권한: 카메라 번역은 카메라를, 음성 대화는 마이크를 사용합니다. SFSpeechRecognizer 경로는 음성 인식 권한도 요청합니다

UI는 네이티브 `TabView`, `Form`, `Picker`, `Menu`와 접근성 의미 구조를 사용합니다. 색상, 간격, 바깥쪽 레이아웃은 `AppTheme`과 각 화면이 관리합니다. iOS 26 이상에서는 시스템이 Liquid Glass를 표시하고, 이전 시스템에서는 해당 버전의 네이티브 컨트롤 외관을 사용합니다.

## 기능과 구현

### 텍스트 번역

원문 카드를 탭하면 편집을 시작합니다. 카드 자체가 펼쳐지고 접히며 편집기는 전체 과정에서 같은 뷰로 유지됩니다. 텍스트, 받아쓰기, 언어 변경은 먼저 초안에 반영되고 `완료 후 번역`을 탭하면 제출됩니다. 결과 화면에서는 언어 교환, 읽기, 복사, 즐겨찾기, 공유를 사용할 수 있습니다.

중계가 설정된 빌드는 Cloud Translation v3를 사용합니다. 중계가 없는 빌드는 시스템 번역을 사용합니다. 새 제출은 진행 중인 요청을 취소하며, 성공한 결과는 번역 서비스, 언어 쌍, 원문을 기준으로 프로세스 안에 캐시됩니다. 원문 언어는 자동으로 감지할 수 있고 감지가 끝나면 언어를 바꿀 수 있습니다. Cloud Translation v3는 대안 번역을 제공하지 않으므로 다른 서비스가 대안을 반환할 때만 관련 동작이 표시됩니다.

### 음성 대화

음성 화면은 인식 중인 텍스트와 실시간 번역 미리보기를 계속 표시합니다. 문장 구분 설정은 [`VoiceTiming`](../Verto/Voice/VoiceTranscription.swift)에 모여 있습니다. 문장을 제출한 뒤에도 인식 스트림은 다음 문장을 처리하고, 확정 번역은 각 말풍선에 비동기로 채워집니다. 읽기는 대화가 비는 시간에 재생되며 재생 중에는 마이크 입력을 일시정지합니다.

이중 언어 자동 감지는 언어 쌍의 각 언어에 인식 트랙을 만들고 언어 확률, 인식 신뢰도, 텍스트 양을 바탕으로 현재 언어를 선택합니다. 한쪽 언어를 수동으로 고정할 수도 있습니다. 전화 수신, 백그라운드 전환, 탭 전환 시 수음을 멈추며 대화 내용은 현재 앱 세션에 유지됩니다.

iOS 26 이상에서는 시스템이 지원할 때 SpeechAnalyzer와 SpeechTranscriber를 사용합니다. 다른 환경에서는 SFSpeechRecognizer를 사용합니다. 번역은 Apple Translation 세션을 우선 사용하고, 시스템 기능을 사용할 수 없으면 텍스트 화면과 카메라 화면이 쓰는 번역 서비스로 전환합니다.

### 카메라 번역

카메라 화면에서 사진을 촬영하거나 사진 보관함의 이미지를 선택할 수 있습니다. 텍스트 인식은 기기에서 실행됩니다. 번역문은 인식된 사각형 위에 놓이고 원본 이미지의 각도, 배경색, 글자색을 사용합니다. 번역 블록을 탭하면 원문과 번역문을 비교하고 복사, 읽기, 기록 저장을 할 수 있습니다.

시스템 Vision이 기본 인식 방식입니다. PP-OCRv6 모델 팩을 다운로드하면 Core ML 검출 모델과 인식 모델을 사용합니다. 설정에서는 경량, 균형, 최고 정확도 세 등급을 선택할 수 있으며 다운로드 용량과 인식 점수는 [`OCRModelTier`](../Verto/Camera/OCRModelPack.swift)에서 직접 읽습니다. 한국어는 항상 시스템 텍스트 인식을 사용합니다. 경량 모델에는 일본어 가나가 없으므로 일본어도 시스템 텍스트 인식을 사용합니다.

인식된 줄은 열, 간격, 기울기, 글자 크기에 따라 문단으로 묶입니다. 이 판정 규칙은 [`TextDetectionPostProcess`](../Verto/Camera/TextDetectionPostProcess.swift)가 관리합니다. 사진 출력은 뷰파인더에 표시된 방향을 유지합니다. 인식용 사본은 `AVCaptureDevice.RotationCoordinator`의 방향을 따르고, 인식된 사각형은 원본 이미지 좌표로 다시 옮겨집니다.

페이지의 원문을 중복 제거한 뒤 배치로 번역합니다. 인식 결과가 먼저 표시되고 배치가 도착할 때마다 번역 블록이 갱신됩니다. 실패한 블록은 개별적으로 다시 시도할 수 있습니다. 언어 쌍을 바꾸면 같은 사진을 다시 번역합니다.

화면을 열 때 카메라 권한을 요청합니다. 권한이 거부되면 설명과 시스템 설정 진입점을 표시합니다. 사용할 수 있는 카메라가 없으면 사진 보관함에서 이미지를 선택하도록 안내합니다.

### 언어, 기록, 설정

언어 선택 화면은 원문 언어와 번역 언어를 바꾸고 이름, 별칭, 언어 코드로 검색할 수 있습니다. 기록과 즐겨찾기는 같은 번역 저장소를 사용합니다. 기록 항목을 탭하면 텍스트 화면에 내용이 채워집니다.

설정 화면은 현재 빌드가 실제로 사용하는 번역 서비스를 표시합니다. 음성 읽기 방식, 텍스트 화면 자동 읽기, OCR 모델, 화면 모드도 설정할 수 있습니다. 자체 모델과 LLM 번역은 비활성화된 로드맵 항목입니다. 설정과 최근 언어 쌍은 UserDefaults에 저장됩니다.

### 내비게이션과 모션

텍스트, 음성, 카메라는 네이티브 `TabView`의 세 최상위 영역이며 각 탭은 상태를 유지합니다. 텍스트 입력에 집중하는 동안 시스템이 탭 바를 잠시 숨깁니다. 동작 줄이기를 켜면 레이아웃은 최종 상태로 바로 이동하고 필요한 투명도 변화만 남습니다.

텍스트 카드 모션은 실제 카드에 적용됩니다. 모션 매개변수는 [`TextEntryMotionProfile`](../Verto/Screens/TextTranslateView.swift)이 관리합니다. 자동화 테스트는 조작과 최종 상태를 검증하고, 화면 녹화로 애니메이션이 분명하게 보이는지 확인합니다.

## 시뮬레이터 제한

- iOS 시뮬레이터에서는 SpeechTranscriber와 시스템 Translation 프레임워크를 실행할 수 없습니다.
- 시뮬레이터에는 카메라가 없으므로 뷰파인더, 촬영, 플래시, 실기기 방향은 iPhone에서 검증합니다.
- 사진 보관함에서 이미지를 선택한 뒤에는 Vision과 Core ML 텍스트 인식을 시뮬레이터에서 실행할 수 있습니다.
- 시스템 오프라인 번역, 언어 모델 다운로드, 이중 트랙 음성 인식, 헤드폰 경로, 물리적 햅틱은 실기기에서 검증합니다.

`VertoTests/SpeechAvailabilityProbeTests`, `VertoTests/VisionAvailabilityProbeTests`, `VertoTests/PaddleOCRProbeTests`가 사용할 수 있는 시스템 기능을 확인합니다. 프로브는 현재 환경을 보고하고 결과는 테스트 산출물에 저장됩니다.

## 자동화 테스트

`VertoUITests`는 텍스트 번역, 즐겨찾기, 언어 검색, 음성 대화, 읽기 설정, 카메라 오버레이, 기록, 탭 상태를 다룹니다. `--uitest-canned-translation`, `--uitest-canned-speech`, `--uitest-canned-camera`, `--uitest-reset-settings`가 반복 가능한 테스트 데이터를 제공합니다. UI 테스트는 주입된 서비스를 사용하며 네트워크, 마이크, TTS, 카메라의 실제 경로는 별도로 검증합니다.

`LocalizationTests`는 다섯 언어의 리소스, 형식 자리표시자, 복수형 규칙을 확인합니다. 단위 테스트는 번역 라우팅, 캐시, 음성 상태 머신, OCR 좌표 처리, 모델 파일 검증도 다룹니다.

`xcrun simctl list devices available`로 사용할 수 있는 시뮬레이터를 확인한 뒤 실행합니다.

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<기기 이름>' \
  CODE_SIGNING_ALLOWED=NO
```

## 로드맵

기기에서 실행되는 자체 번역 모델과 개인 API 키를 사용하는 LLM 번역은 계획 중입니다. 설정 화면에서는 비활성화된 선택지로 표시됩니다. 스트리밍 음성 번역 프로토콜 진입점은 [`StreamingSpeechTranslating`](../Verto/Voice/AppleTranslationService.swift)에 있습니다. 현재 음성 세션은 음성 인식, 텍스트 번역, 음성 읽기를 조합합니다.

## 라이선스

이 프로젝트는 [Apache License 2.0](../LICENSE)으로 배포됩니다.
