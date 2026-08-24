<p align="center">
  <img src="docs/icon.png" width="128" alt="译境 App 图标" />
</p>

<h1 align="center">译境 (Verto)</h1>

<p align="center">
  <img alt="AI Coded 100%" src="https://img.shields.io/badge/AI%20Coded-100%25-brightgreen?style=flat-square&labelColor=444" />
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=flat-square&labelColor=444&logo=apple&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&labelColor=444&logo=swift&logoColor=white" />
  <a href="LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache%202.0-D6A184?style=flat-square&labelColor=444" /></a>
</p>

<p align="center">
  <b>简体中文</b> · <a href="docs/README.en.md">English</a> · <a href="docs/README.ja.md">日本語</a> · <a href="docs/README.ko.md">한국어</a> · <a href="docs/README.es.md">Español</a>
</p>

<p align="center">一款原生 SwiftUI iOS 翻译 App，提供文字翻译、双语语音对话和相机取词翻译。</p>

---

## 快速开始

1. 用 Xcode 打开 `Verto.xcodeproj`。
2. 选择 `Verto` Scheme。
3. 选择 iOS 17 或更高版本的 iPhone 模拟器。
4. 点击 Run。

工程可以直接编译。未配置在线中转的构建会使用系统 Translation 框架，系统翻译需要 iOS 18 或更高版本的真机。模拟器无法运行系统翻译。

### 在线翻译

在线翻译通过 `tools/translate-relay` 中的 Cloudflare Worker 连接 Cloud Translation v3。先按 [`tools/translate-relay/README.md`](tools/translate-relay/README.md) 部署中转，然后创建本地配置：

```bash
cp Secrets.local.xcconfig.example Secrets.local.xcconfig
```

在 `Secrets.local.xcconfig` 中填写主机名和共享密钥。这个文件已被 Git 忽略。提交到仓库的 `Secrets.xcconfig` 必须保持为空值。

### 命令行构建

终端的 `xcode-select` 指向 Command Line Tools 或旧版 Xcode 时，可以显式指定 Xcode：

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

## 项目

- Xcode 工程：`Verto.xcodeproj`
- App 名称：中文界面显示为译境，其他界面语言显示为 Verto
- 界面语言：简体中文、English、日本語、한국어、Español
- 字符串目录：`Verto/Localizable.xcstrings` 和 `Verto/InfoPlist.xcstrings`
- Bundle ID：`com.yspritan.verto`
- 最低系统：iOS 17
- 主要框架：SwiftUI、Observation、AVFoundation、PhotosUI、Speech、Translation
- 权限：相机翻译使用相机，语音对话使用麦克风；SFSpeechRecognizer 路径还会请求语音识别权限

界面使用原生 `TabView`、`Form`、`Picker`、`Menu` 和辅助功能语义。颜色、间距和外层布局由 `AppTheme` 与各页面负责。iOS 26 及更高版本由系统呈现 Liquid Glass，较早系统使用对应的原生控件外观。

## 功能与实现

### 文字翻译

轻点原文卡进入编辑。原文卡本身完成展开和收回，编辑器在整个过程中保持同一身份。文字、听写和语言调整先进入草稿，轻点 `完成并翻译` 后提交。结果页支持交换语言、朗读、复制、收藏和分享。

已配置中转的构建使用 Cloud Translation v3，未配置中转的构建使用系统翻译。新提交会取消仍在进行的请求，成功结果按翻译服务、语言对和原文缓存在进程内。源语言支持自动检测，检测完成后可以交换语言。Cloud Translation v3 不提供备选译法，因此结果没有备选时不会显示相关入口。

### 语音对话

语音页持续显示识别中的文字和实时译文预览。断句参数集中在 [`VoiceTiming`](Verto/Voice/VoiceTranscription.swift)，识别流在句子提交后继续处理下一句，最终译文按气泡异步回填。朗读会排在无人说话的间隙播放，播放期间暂停麦克风输入。

双语自动检测为语言对中的每种语言建立识别轨道，根据语言概率、识别置信度和文本量选择当前语言。用户也可以手动锁定一侧语言。来电、进入后台和切换标签页会停止收音，对话内容仍保留在当前 App 会话中。

iOS 26 及更高版本在系统支持时使用 SpeechAnalyzer 和 SpeechTranscriber。其他环境使用 SFSpeechRecognizer。翻译优先使用 Apple Translation 会话，系统能力不可用时切换到与文字页和相机页相同的翻译服务。

### 相机翻译

相机页可以拍照或从照片库选择图片。文字识别在设备上完成，译文按照识别出的四边形覆盖在原文位置，并沿用原图中的倾角、背景色和文字颜色。轻点译文块可以查看原文与译文，随后复制、朗读或存入历史记录。

系统 Vision 是基础识别方式。下载 PP-OCRv6 模型包后，相机页会使用 Core ML 版检测与识别模型。模型包由独立的 [`PP-OCR-for-Apple`](https://github.com/YspritanHyzygy/PP-OCR-for-Apple) 工程构建并发布。设置页提供轻量、均衡和最高精度三档，并直接从 [`OCRModelTier`](Verto/Camera/OCRModelPack.swift) 读取下载大小和识别分数。韩语始终使用系统文字识别；轻量模型不含日文假名，日语也会使用系统文字识别。

识别行会按照栏位、间距、倾角和字号合并为段落。分组判据由 [`TextDetectionPostProcess`](Verto/Camera/TextDetectionPostProcess.swift) 维护。照片输出保留取景时的方向，识别副本按照 `AVCaptureDevice.RotationCoordinator` 的方向处理，识别框随后映射回原图坐标。

整页原文去重后批量翻译，识别结果会先显示，译文分批到达后逐块更新。单块失败可以单独重试。更换语言对会使用同一张照片重新翻译。

相机权限在进入页面时请求。权限被拒后，页面会说明原因并提供系统设置入口。没有可用相机时，页面会引导用户从照片库选择图片。

### 语言、历史和设置

语言选择支持源语言与目标语言切换，也可以按名称、别名和语言代码搜索。历史记录和收藏共用同一份翻译数据，轻点历史记录可以回填文字页。

设置页显示当前构建实际使用的翻译服务，并提供语音朗读方式、文字页自动朗读、OCR 模型和外观设置。自研模型与 LLM 翻译目前是禁用的计划项。设置和最后使用的语言对保存在 UserDefaults 中。

### 导航与动效

文字、语音和相机是原生 `TabView` 的三个顶层区域，各标签页保留自己的状态。文字页专注输入时，系统会暂时隐藏标签栏。开启减弱动态效果后，布局直接切换到终态，必要的透明度变化仍会保留。

文字卡动画作用在实际卡片上。具体动效参数保存在 [`TextEntryMotionProfile`](Verto/Screens/TextTranslateView.swift)，自动化测试验证交互和终态，屏幕录制用于检查动画是否清楚可见。

## 模拟器限制

- iOS 模拟器无法运行 SpeechTranscriber 和系统 Translation 框架。
- 模拟器没有相机，取景、拍照、闪光灯和实机方向需要在 iPhone 上验证。
- 从照片库选择图片后，Vision 与 Core ML 文字识别可以在模拟器中运行。
- 系统离线翻译、语言模型下载、双轨语音识别、耳机路由和实体触觉需要真机验证。

可用的系统能力由 `VertoTests/SpeechAvailabilityProbeTests`、`VertoTests/VisionAvailabilityProbeTests` 和 `VertoTests/PaddleOCRProbeTests` 检查。探针会报告当前运行环境，README 不保存某次运行的结果。

## 自动化测试

`VertoUITests` 覆盖文字翻译、收藏、语言搜索、语音对话、朗读设置、相机译文覆盖、历史记录和标签页状态。测试通过 `--uitest-canned-translation`、`--uitest-canned-speech`、`--uitest-canned-camera` 和 `--uitest-reset-settings` 注入可重复的数据，不会访问真实网络、麦克风、TTS 或相机。

`LocalizationTests` 检查五种语言资源、格式占位符和复数规则。单元测试还覆盖翻译路由、缓存、语音状态机、OCR 几何与模型文件校验。

先用 `xcrun simctl list devices available` 找到可用模拟器，再运行：

```bash
xcodebuild test \
  -project Verto.xcodeproj \
  -scheme Verto \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=<设备名>' \
  CODE_SIGNING_ALLOWED=NO
```

## 路线图

自研端侧翻译模型和自带 API Key 的 LLM 翻译仍在计划中，设置页会把它们显示为不可选项。流式语音翻译的协议入口位于 [`StreamingSpeechTranslating`](Verto/Voice/AppleTranslationService.swift)，当前语音会话仍使用识别、文字翻译和朗读组成的管线。

## 许可证

本项目以 [Apache License 2.0](LICENSE) 授权。
