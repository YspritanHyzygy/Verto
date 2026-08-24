<p align="center">
  <img src="icon.png" width="128" alt="Verto アプリアイコン" />
</p>

<h1 align="center">Verto</h1>

<p align="center">
  <img alt="AI Coded 100%" src="https://img.shields.io/badge/AI%20Coded-100%25-brightgreen?style=flat-square&labelColor=444" />
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=flat-square&labelColor=444&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&labelColor=444&logo=swift&logoColor=white" />
  <a href="../LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-D6A184?style=flat-square&labelColor=444" /></a>
</p>

<p align="center">
  <a href="../README.md">简体中文</a> · <a href="README.en.md">English</a> · <b>日本語</b> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">テキスト翻訳、二言語の音声会話、カメラ翻訳に対応した、SwiftUI ネイティブの iOS 翻訳アプリです。</p>

---

## クイックスタート

1. Xcode で `Verto.xcodeproj` を開きます。
2. `Verto` スキームを選択します。
3. iOS 17 以降の iPhone シミュレータを選択します。
4. Run を押します。

追加設定なしでビルドできます。オンライン中継を設定していないビルドはシステムの Translation フレームワークを使います。システム翻訳には iOS 18 以降の実機が必要で、シミュレータでは利用できません。

### オンライン翻訳

オンライン翻訳は `tools/translate-relay` の Cloudflare Worker を介して Cloud Translation v3 に接続します。[`tools/translate-relay/README.md`](../tools/translate-relay/README.md) に従って中継サーバーをデプロイし、ローカル設定を作成します。

```bash
cp Secrets.local.xcconfig.example Secrets.local.xcconfig
```

`Secrets.local.xcconfig` にホスト名と共有シークレットを入力します。このファイルは Git の対象外です。リポジトリに含まれる `Secrets.xcconfig` には実際の認証情報を入れないでください。

### コマンドラインビルド

`xcode-select` が Command Line Tools や古い Xcode を参照している場合は、使用する Xcode を明示します。

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

## プロジェクト

- Xcode プロジェクト: `Verto.xcodeproj`
- アプリ名: 簡体字中国語では译境、その他の UI 言語では Verto
- UI 言語: 簡体字中国語、英語、日本語、韓国語、スペイン語
- 文字列カタログ: `Verto/Localizable.xcstrings` と `Verto/InfoPlist.xcstrings`
- Bundle ID: `com.yspritan.verto`
- 最低 OS: iOS 17
- 主なフレームワーク: SwiftUI、Observation、AVFoundation、PhotosUI、Speech、Translation
- 権限: カメラ翻訳はカメラ、音声会話はマイクを使用します。SFSpeechRecognizer の経路では音声認識の権限も要求します

UI にはネイティブの `TabView`、`Form`、`Picker`、`Menu` とアクセシビリティセマンティクスを使っています。色、間隔、外側のレイアウトは `AppTheme` と各画面が管理します。iOS 26 以降ではシステムが Liquid Glass を描画し、それ以前のシステムでは対応するネイティブ外観を使います。

## 機能と実装

### テキスト翻訳

原文カードをタップすると編集を開始します。カード自体が展開と収納を行い、エディタは全過程で同じビューとして維持されます。テキスト、音声入力、言語変更は下書きに入り、`完了して翻訳` をタップすると送信されます。結果画面では言語の入れ替え、読み上げ、コピー、お気に入り、共有が使えます。

中継サーバーを設定したビルドは Cloud Translation v3 を使います。中継サーバーのないビルドはシステム翻訳を使います。新しい送信は進行中のリクエストをキャンセルし、成功した結果は翻訳サービス、言語ペア、原文ごとにプロセス内へキャッシュされます。原文の言語は自動検出でき、検出後に言語を入れ替えられます。Cloud Translation v3 は別訳を返さないため、別訳を返すサービスを使った場合だけ関連操作が表示されます。

### 音声会話

音声画面には認識中のテキストと翻訳プレビューが継続して表示されます。文の区切りに関する設定は [`VoiceTiming`](../Verto/Voice/VoiceTranscription.swift) に集約されています。文を送信した後も認識ストリームは次の文を処理し、確定した翻訳は各吹き出しへ非同期で反映されます。読み上げは会話の空き時間に再生され、再生中はマイク入力を一時停止します。

二言語の自動検出は、言語ペアの各言語に認識トラックを作り、言語確率、認識信頼度、テキスト量から現在の言語を選びます。片方の言語を手動で固定することもできます。着信、バックグラウンド移行、タブ切り替えで収音を停止し、会話内容は現在のアプリセッションに保持されます。

iOS 26 以降では、システムが対応している場合に SpeechAnalyzer と SpeechTranscriber を使います。その他の環境では SFSpeechRecognizer を使います。翻訳は Apple Translation セッションを優先し、システム機能が利用できない場合はテキスト画面やカメラ画面と同じ翻訳サービスに切り替わります。

### カメラ翻訳

カメラ画面では写真を撮影するか、フォトライブラリから画像を選べます。文字認識はデバイス上で実行されます。訳文は認識した四辺形の位置に重ねられ、元画像の傾き、背景色、文字色を使います。訳文のブロックをタップすると原文と訳文を比較し、コピー、読み上げ、履歴への保存ができます。

システムの Vision が基本の認識方式です。PP-OCRv6 のモデルパックをダウンロードすると、Core ML 版の検出モデルと認識モデルを使います。設定画面では軽量、バランス、最高精度の 3 段階を選べます。ダウンロード容量と認識スコアは [`OCRModelTier`](../Verto/Camera/OCRModelPack.swift) から直接読み取ります。韓国語は常にシステムの文字認識を使います。軽量モデルには日本語のかなが含まれないため、日本語もシステムの文字認識を使います。

認識した行は、段組み、間隔、傾き、文字サイズから段落にまとめられます。判定規則は [`TextDetectionPostProcess`](../Verto/Camera/TextDetectionPostProcess.swift) が管理します。写真出力はファインダーに表示された向きを保ちます。認識用の複製は `AVCaptureDevice.RotationCoordinator` の向きに従い、認識した四辺形を元画像の座標へ戻します。

ページ内の原文を重複排除してからバッチで翻訳します。認識結果が先に表示され、各バッチの到着に合わせて訳文のブロックが更新されます。失敗したブロックは個別に再試行できます。言語ペアを変えると同じ写真をもう一度翻訳します。

画面を開いたときにカメラ権限を要求します。権限が拒否された場合は説明とシステム設定への入口を表示します。利用できるカメラがない場合は、フォトライブラリから画像を選ぶよう案内します。

### 言語、履歴、設定

言語選択では原文の言語と翻訳先の言語を切り替え、名前、別名、言語コードで検索できます。履歴とお気に入りは同じ翻訳ストアを使います。履歴項目をタップするとテキスト画面に内容が戻ります。

設定画面には現在のビルドが実際に使う翻訳サービスが表示されます。音声の読み上げ方法、テキスト画面の自動読み上げ、OCR モデル、外観も設定できます。独自モデルと LLM 翻訳は無効化されたロードマップ項目です。設定と直近の言語ペアは UserDefaults に保存されます。

### ナビゲーションとモーション

テキスト、音声、カメラはネイティブ `TabView` の 3 つのトップレベル領域で、各タブは状態を保持します。テキスト入力に集中している間は、システムがタブバーを一時的に隠します。視差効果を減らす設定が有効な場合、レイアウトは最終状態へ直接移動し、必要な不透明度の変化だけを残します。

テキストカードの動きは実際のカードに適用されます。動きのパラメータは [`TextEntryMotionProfile`](../Verto/Screens/TextTranslateView.swift) が管理します。自動テストは操作と最終状態を検証し、画面録画でアニメーションの見え方を確認します。

## シミュレータの制限

- iOS シミュレータでは SpeechTranscriber とシステムの Translation フレームワークを実行できません。
- シミュレータにはカメラがないため、ファインダー、撮影、フラッシュ、実機の向きは iPhone で検証します。
- フォトライブラリから画像を選んだ後は、Vision と Core ML の文字認識をシミュレータで実行できます。
- システムのオフライン翻訳、言語モデルのダウンロード、二重トラックの音声認識、ヘッドフォン経路、物理的な触覚は実機で検証します。

`VertoTests/SpeechAvailabilityProbeTests`、`VertoTests/VisionAvailabilityProbeTests`、`VertoTests/PaddleOCRProbeTests` が利用可能なシステム機能を確認します。プローブは現在の環境を報告し、結果はテスト成果物に保存されます。

## 自動テスト

`VertoUITests` はテキスト翻訳、お気に入り、言語検索、音声会話、読み上げ設定、カメラの重ね表示、履歴、タブ状態を対象にします。`--uitest-canned-translation`、`--uitest-canned-speech`、`--uitest-canned-camera`、`--uitest-reset-settings` が再現可能なテストデータを提供します。UI テストでは注入したサービスを使い、ネットワーク、マイク、TTS、カメラの実経路は個別に検証します。

`LocalizationTests` は 5 言語のリソース、書式プレースホルダ、複数形規則を確認します。単体テストは翻訳ルーティング、キャッシュ、音声状態機械、OCR の座標処理、モデルファイルの検証も対象にします。

`xcrun simctl list devices available` で利用可能なシミュレータを確認してから実行します。

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<デバイス名>' \
  CODE_SIGNING_ALLOWED=NO
```

## ロードマップ

デバイス上で動く独自翻訳モデルと、自分の API キーを使う LLM 翻訳は計画中です。設定画面では無効な選択肢として表示されます。ストリーミング音声翻訳のプロトコル入口は [`StreamingSpeechTranslating`](../Verto/Voice/AppleTranslationService.swift) にあります。現在の音声セッションは音声認識、テキスト翻訳、読み上げを組み合わせています。

## ライセンス

本プロジェクトは [Apache License 2.0](../LICENSE) で提供されます。
