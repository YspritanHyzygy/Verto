<p align="center">
  <img src="icon.png" width="128" alt="译境 app icon" />
</p>

<h1 align="center">译境 (Verto)</h1>

<p align="center">
  <img alt="AI Coded 100%" src="https://img.shields.io/badge/AI%20Coded-100%25-brightgreen?style=flat-square&labelColor=444" />
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=flat-square&labelColor=444&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&labelColor=444&logo=swift&logoColor=white" />
  <a href="../LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-D6A184?style=flat-square&labelColor=444" /></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> · <b>English</b> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">A native SwiftUI translation app for iOS — text, voice conversation, and camera —<br />built on a real translation and continuous speech-recognition pipeline, and doubling as a proving ground for a home-grown translation model and LLM translation engines.</p>

---

## Project

- Xcode project: `Verto.xcodeproj`
- App name: 译境 (Chinese for “realm of translation”); shown as “Verto” in non-Chinese UI languages
- UI languages: Simplified Chinese, English, Japanese, Korean, Spanish (switchable per app in iOS Settings; Simplified Chinese is the source language, string catalogs at `Verto/Localizable.xcstrings` + `Verto/InfoPlist.xcstrings`)
- Bundle ID: `com.yspritan.verto`
- Minimum OS: iOS 17
- Stack: SwiftUI, native TabView, Observation, AVFoundation, PhotosUI, Speech (SpeechAnalyzer/SFSpeechRecognizer), Translation; on iOS 26+ the system tab bar automatically adopts Liquid Glass.
- Permissions: voice conversation needs microphone access; the iOS 17–25 fallback path additionally needs speech-recognition access (both usage descriptions are provided via the project's INFOPLIST_KEY_*).

## Features

### Text translation

Tapping the source text expands the real source card from its resting height to the full viewport on a single `.spring(duration: 0.45, bounce: 0.12)`; the software keyboard requests focus on the next runloop and rises in parallel with the expansion. When the tab bar hides or the keyboard safe area changes, the spring retargets with preserved velocity — no waiting for layout to settle, no snapshot overlays, no cross-fade hand-off at the end. Text, dictation, and language changes are first saved as a draft; only tapping the terracotta circular check “Done & Translate” in the top-right commits it and fires a real translation. The result view supports swapping languages, reading the result aloud, copy, favorite, share, and alternative translations.

**Engine & cache**: the text tab talks to Google Translate's unofficial free endpoint (`translate.googleapis.com`, `client=gtx`, no API key needed). Submissions show a loading state; failures show a localized error message with a retry button; a new submission cancels the in-flight request. Successful results are cached in an in-process LRU (200 entries) keyed by engine, language pair, and source text — repeated translations are served synchronously without touching the network; failures are never cached, so a retry always goes out for real. The source language supports auto-detect (`sl=auto`): the language bar shows the detected language and swapping is enabled only once detection lands; single-sentence translations carry Google's alternative renderings (not provided for multi-sentence input; the “alternatives” entry hides when there are none).

### Voice conversation translation

Tap the microphone to start listening. While you speak, the active bubble shows the volatile transcript plus a low-opacity live rough translation (re-translation throttled at 350 ms, with masked source text and generation numbers dropping stale responses to prevent flicker). A sentence finalizes automatically once the volatile text has been stable ≥0.9 s and RMS silence lasts ≥0.55 s (or tap to end manually; 55 s hard cap).

**Recognition never waits for translation**: finalization is just a cut point on the recognition stream (`finalize(through: nil)`). A finalized sentence lands on screen immediately (rough-translation preview + translating state) while the authoritative translation fills its bubble asynchronously, with in-bubble retry on failure; recognition keeps running for the next sentence with zero words lost at the boundary (track state is split at the consumption baseline). Auto-speak is queued into the gaps when nobody is talking, and audio input is suspended during playback to prevent re-capture.

**Bilingual auto-detection (default)**: the center microphone auto-identifies within the language pair — one recognition track per language fed the same audio in parallel, the winner scored from NLLanguageRecognizer language probability + recognition confidence + text volume (with hysteresis against per-character flip-flops). The detected language decides the bubble side and translation direction, so Chinese and English can be mixed freely; a failing track never interrupts the utterance (the remaining tracks keep going). Tap a language button to lock one side manually, tap again to return to auto; the status area shows the current mode (“Listening · English / 中文”, or a single language).

**Recognition stack**: on iOS 26+ with runtime availability (`SpeechTranscriber.isAvailable` and non-empty supportedLocales) it runs SpeechAnalyzer with multiple attached SpeechTranscriber modules (fully on-device, microphone permission only; degrades to a single track if modules fail); otherwise it falls back to multiple SFSpeechRecognizer instances running in parallel (iOS 17–25 and the Simulator; both permissions).

**Latency essentials**: the recognition chain is session-persistent — the analyzer is built during prepare with `.processLifetime` model residency and a `prepareToAnalyze` warm-up; sentences are cut with `finalize(through: nil)` instead of tear-down/rebuild (a rebuild costs a seconds-long model load per sentence); half-duplex across TTS playback and inter-sentence gaps is maintained by the suspended audio source dropping buffers (no per-sentence audio-session setActive cycling); `.fastResults` accelerates the first volatile; finalization thresholds are 0.9 s stable volatile + 0.55 s silence; winner selection may switch freely without hysteresis within the first 0.7 s of speech.

**Translation routing**: Apple's Translation framework comes first — on iOS 26+ it constructs `Translation.TranslationSession(installedSource:target:)` directly (on 26.4+ a separate `.lowLatency` session handles partials); on iOS 18–25 sessions are borrowed through a resident host view at AppShell's root. On the Simulator / iOS 17 / missing language packs / framework errors it automatically falls back to the Google endpoint and remembers the decision per language pair (reasons logged via os.Logger).

Incoming calls, backgrounding, and tab switches all stop capture; the conversation persists across tabs (the controller is owned by AppShell). Bubbles carry speak buttons; the page header has a quick playback-mode menu (synced with Settings); the pair's “auto-detect” resolves to a concrete language on the voice tab based on the opposite side. Final translations are cached in-process (finals only — partials never enter the LRU); a failed final can be retried inside its bubble. The waveform is driven by measured microphone level (vDSP RMS).

### Camera translation

Photo picking, recognition loading state, menu-translation overlay cards, flash and exposure states.

### Languages, history & favorites

- Language picker: source/target switching, search by name/alias/code, selection and empty-result states.
- History & favorites: shared translation records, favorites filter, instant star toggle, tapping a record refills the text tab.

### Settings & appearance

The settings sheet opens from the text tab's top-right corner. The translation model is switchable — Google Translate (free) is available today, while the home-grown model and LLM translation (bring your own API key) appear as disabled “coming soon” placeholders. The “voice conversation” section selects spoken-translation behavior (text only / auto-speak after translation / speak only with headphones — wired, Bluetooth, and USB, with live route detection); general preferences include “auto-speak translations” (text tab only). Engine, playback mode, preferences, and the last language pair persist via UserDefaults; the first launch keeps the demo content, and afterwards the app starts blank with the remembered pair.

**Dark mode**: follow the system or pick an appearance manually in Settings; the adaptive palette runs through every screen and component.

### Navigation & motion

- Text, voice, and camera are the three top-level areas of a native TabView; the tab bar stays visible in normal use and each tab keeps its state — it is only temporarily hidden by the system while the text tab is in focused typing, returning after the draft is committed. iOS 26+ renders Liquid Glass through the system, iOS 17–25 uses the corresponding system tab-bar appearance; a real selection change triggers system haptic feedback.
- Focused typing places no “Done” item in the `.keyboard` toolbar; both software and hardware keyboards use the submit button pinned to the page's top-right, keeping bottom actions clear of the system tab bar.
- The typing transition has a single source of truth: whether a draft exists. The source editor keeps one identity throughout; expansion and collapse are both layout animations on the real card (the render tree interpolates every view's frame per frame, and the card face Shape recomputes its path each frame so the 22 pt continuous corner radius never distorts) — no geometry measurement, no cross-transaction validation, no phase choreography. The transition is interactive and interruptible end to end; tapping the check mid-expansion reverses smoothly with the current velocity. The result area fades out/in beneath the paper over a ~0.16 s opacity transition, its position carried by the layout spring; the check pops from 0.84× back to full size after a ~40 ms delay.
- With “Reduce Motion” on, layout switches straight to its end state (no size, position, or scale animation); the result area and header buttons keep only a ~0.12 s opacity fade; keyboard and tab bar continue to use system behavior.

## Status & roadmap

Text translation uses Google's unofficial free endpoint (network access to Google services required); voice conversation is a real recognition + translation pipeline (see above); menu OCR currently runs on local demo data. The home-grown model and LLM-based translation engines are planned and appear as placeholders in Settings — the seam for a future streaming speech-translation engine is already left at the bottom of `Verto/Voice/AppleTranslationService.swift` (a `StreamingSpeechTranslating` protocol stub, attached at the voice-session layer rather than text→text).

## Run in Xcode

1. Open `Verto.xcodeproj` in Xcode.
2. Select the `Verto` scheme.
3. Pick any iPhone Simulator running iOS 17 or newer.
4. Hit Run.

If your terminal's `xcode-select` points at the Command Line Tools or an older Xcode, prefix command-line builds with `DEVELOPER_DIR`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/VertoDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Simulator limitations

**Apple platform constraints, verified empirically**: neither SpeechTranscriber nor the Translation framework works on the iOS Simulator (no ANE, no translation models). The voice tab automatically drops to the SFSpeechRecognizer + Google fallback chain there, and as measured on the iOS 27 Simulator: **en-US cannot initialize because the system forces the local recognizer (kLSRErrorDomain 300 in both on-device and server modes), while zh-CN works fully via server-side recognition** — so speaking Chinese on the Simulator exercises the real “recognize → translate → speak” loop, while English is silently skipped by multi-track auto-detection (an English-only single track shows the notice “The simulator can't recognize this language. Test on a real device.”).

Diagnostics can be re-run anytime via `VertoTests/SpeechAvailabilityProbeTests` (report written to /private/tmp/speech-availability-probe.txt). The SpeechAnalyzer path, system offline translation, language-model downloads, the `.lowLatency` strategy, dual-track behavior on device, and headphone detection can only be verified on real hardware. UI tests inject scripted recognition and silent TTS via `--uitest-canned-speech` and never touch real audio.

## Automated tests

The project ships a `VertoUITests` UI-test target whose acceptance flows cover text translation and favoriting, language search and selection, the full voice flow (idle → listening → finalized bubble → pause), voice playback-mode selection in Settings, camera recognition results, native-TabView cross-tab switching / selection sync / state retention, “draft → Done & Translate → restored result view”, and the DEBUG “Reduce Motion” end-state regression.

UI tests uniformly launch with `--uitest-canned-translation`, `--uitest-canned-speech`, and `--uitest-reset-settings`: the first two inject fixed demo translations and scripted speech recognition (no real network, microphone, or TTS), the last resets persisted preferences so assertions stay stable.

The UI is localized, and tests run pinned to Simplified Chinese: the shared scheme's Test action sets `zh-Hans` (covering the unit tests hosted in the app), and the UI tests additionally pass `-AppleLanguages` explicitly, so the Chinese copy assertions don't depend on the simulator language; `LocalizationTests` plus an English-UI smoke test cover resource completeness and real loading per language.

Unit tests cover the conversation controller's state machine (throttling, generation-stale drops, endpoint timing, the TTS gating matrix, failure retry, cache hits, and more), the translation-routing fallback chain, playback-mode persistence, and locale mapping. Automated tests for the text-entry transition verify entering edit mode, exiting it, and the stable final state only; visibility, jumps, and ghosting are accepted by reviewing a real iPhone Simulator screen recording.

Run on any installed iPhone Simulator, for example:

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/VertoTestData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:VertoUITests
```

The Simulator can verify that selection actually changes, but not physical haptics; haptic strength and feel need a final check on a real iPhone.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
