<p align="center">
  <img src="icon.png" width="128" alt="Verto app icon" />
</p>

<h1 align="center">Verto</h1>

<p align="center">
  <img alt="AI Coded 100%" src="https://img.shields.io/badge/AI%20Coded-100%25-brightgreen?style=flat-square&labelColor=444" />
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=flat-square&labelColor=444&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&labelColor=444&logo=swift&logoColor=white" />
  <a href="../LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-D6A184?style=flat-square&labelColor=444" /></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> · <b>English</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">A native SwiftUI translation app for iOS with text translation, bilingual voice conversations, and in-place camera translation.</p>

---

## Quick start

1. Open `Verto.xcodeproj` in Xcode.
2. Select the `Verto` scheme.
3. Choose an iPhone Simulator running iOS 17 or later.
4. Press Run.

The project builds without extra configuration. A build with no online relay uses the system Translation framework, which requires a real device running iOS 18 or later. System translation is unavailable in the Simulator.

### Online translation

Online translation uses the Cloudflare Worker in `tools/translate-relay` to connect to Cloud Translation v3. Deploy the relay with [`tools/translate-relay/README.md`](../tools/translate-relay/README.md), then create the local configuration:

```bash
cp Secrets.local.xcconfig.example Secrets.local.xcconfig
```

Add the host and shared secret to `Secrets.local.xcconfig`. Git ignores this file. Keep the committed `Secrets.xcconfig` free of real credentials.

### Command-line build

If `xcode-select` points to the Command Line Tools or an older Xcode, select Xcode explicitly:

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

## Project

- Xcode project: `Verto.xcodeproj`
- App name: 译境 in Simplified Chinese and Verto in the other interface languages
- Interface languages: Simplified Chinese, English, Japanese, Korean, and Spanish
- String catalogs: `Verto/Localizable.xcstrings` and `Verto/InfoPlist.xcstrings`
- Bundle ID: `com.yspritan.verto`
- Minimum system: iOS 17
- Main frameworks: SwiftUI, Observation, AVFoundation, PhotosUI, Speech, and Translation
- Permissions: camera translation uses the camera, voice conversations use the microphone, and the SFSpeechRecognizer path also requests speech-recognition access

The interface uses native `TabView`, `Form`, `Picker`, `Menu`, and accessibility semantics. `AppTheme` and each screen own the colors, spacing, and outer layout. On iOS 26 and later, the system renders Liquid Glass. Earlier systems use the matching native control appearance.

## Features and implementation

### Text translation

Tap the source card to edit it. The card itself expands and collapses while the editor keeps one identity throughout. Text, dictation, and language changes enter a draft first. Tap `Done and translate` to submit it. The result screen supports language swapping, speech, copy, favorites, and sharing.

A configured build uses Cloud Translation v3 through the relay. A build without a relay uses system translation. A new submission cancels the active request, and successful results are cached in process by service, language pair, and source text. The source language supports automatic detection. Language swapping becomes available after detection. Cloud Translation v3 provides no alternative translations, so the alternative action appears only when a service returns alternatives.

### Voice conversation

The voice screen continuously shows the active transcript and a live translation preview. Sentence-boundary settings live in [`VoiceTiming`](../Verto/Voice/VoiceTranscription.swift). The recognition stream continues with the next sentence after submission, while final translations fill their bubbles asynchronously. Speech playback is queued into gaps in the conversation, and microphone input pauses during playback.

Bilingual automatic detection creates one recognition track for each language in the pair, then selects the active language from language probability, recognition confidence, and text volume. Users can also lock either language manually. Incoming calls, backgrounding, and tab changes stop capture. The conversation remains in the current app session.

On iOS 26 and later, Verto uses SpeechAnalyzer and SpeechTranscriber when the system supports them. Other environments use SFSpeechRecognizer. Translation prefers an Apple Translation session and switches to the same translation service as the text and camera screens when that system capability is unavailable.

### Camera translation

The camera screen can take a photo or load one from the photo library. Text recognition runs on device. Each translation is placed over the recognized quadrilateral and follows the source image's angle, background color, and text color. Tap a translated block to compare the source and translation, then copy it, speak it, or save it to history.

System Vision provides the baseline recognizer. After a PP-OCRv6 pack is downloaded, the camera uses the Core ML detection and recognition models. Settings offers Lightweight, Balanced, and Highest accuracy tiers, with download size and recognition score read directly from [`OCRModelTier`](../Verto/Camera/OCRModelPack.swift). Korean always uses system text recognition. The Lightweight pack contains no Japanese kana, so Japanese also uses system text recognition with that tier.

Recognized lines are grouped into paragraphs by column, spacing, angle, and type size. [`TextDetectionPostProcess`](../Verto/Camera/TextDetectionPostProcess.swift) owns those rules. Photo output keeps the direction shown in the viewfinder. The recognition copy follows `AVCaptureDevice.RotationCoordinator`, and recognized quadrilaterals are mapped back into the original image coordinates.

The page is deduplicated and translated in batches. Recognition results appear first, then translations update each block as their batches arrive. A failed block can retry on its own. Changing the language pair translates the same photo again.

Camera access is requested when the screen opens. A denied permission shows an explanation and an entry point to system Settings. When no camera is available, the screen directs the user to the photo library.

### Languages, history, and settings

The language picker switches source and target languages and searches by name, alias, or language code. History and favorites share one translation store. Tapping a history item refills the text screen.

Settings shows the effective translation service for the current build. It also controls voice playback, automatic speech on the text screen, OCR models, and appearance. The in-house model and LLM translation are disabled roadmap items. Preferences and the most recent language pair are stored in UserDefaults.

### Navigation and motion

Text, voice, and camera are the three top-level areas of a native `TabView`, and each tab keeps its state. The system temporarily hides the tab bar during focused text entry. With Reduce Motion enabled, layout moves directly to its final state while the necessary opacity changes remain.

Text-card motion runs on the actual card. [`TextEntryMotionProfile`](../Verto/Screens/TextTranslateView.swift) owns the motion parameters. Automated tests verify interaction and final states, while screen recordings confirm that the animation is visibly clear.

## Simulator limitations

- The iOS Simulator cannot run SpeechTranscriber or the system Translation framework.
- The Simulator has no camera, so viewfinder, capture, flash, and device-orientation behavior require an iPhone.
- Vision and Core ML text recognition can run in the Simulator after an image is selected from the photo library.
- System offline translation, language-model downloads, dual-track speech recognition, headphone routing, and physical haptics require a real device.

`VertoTests/SpeechAvailabilityProbeTests`, `VertoTests/VisionAvailabilityProbeTests`, and `VertoTests/PaddleOCRProbeTests` inspect the available system capabilities. The probes report the current environment, and their results stay with the test artifacts.

## Automated tests

`VertoUITests` covers text translation, favorites, language search, voice conversations, playback settings, camera overlays, history, and tab state. `--uitest-canned-translation`, `--uitest-canned-speech`, `--uitest-canned-camera`, and `--uitest-reset-settings` provide repeatable test data. These injected services keep the real network, microphone, TTS, and camera outside the UI suite.

`LocalizationTests` checks all five language resources, format placeholders, and plural rules. Unit tests also cover translation routing, caching, the voice state machine, OCR geometry, and model-file verification.

List available simulators with `xcrun simctl list devices available`, then run:

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<device name>' \
  CODE_SIGNING_ALLOWED=NO
```

## Roadmap

The in-house on-device translation model and bring-your-own-key LLM translation remain planned work and appear as disabled choices in Settings. The protocol entry point for streaming speech translation is [`StreamingSpeechTranslating`](../Verto/Voice/AppleTranslationService.swift). The current voice session uses speech recognition, text translation, and speech playback.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
