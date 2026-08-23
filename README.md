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

<p align="center">原生 SwiftUI 打造的 iOS 翻译 App：文字、语音对话、相机三个入口，<br />内置真实翻译与连续语音识别管线，同时作为自研翻译模型与 LLM 翻译引擎的试验田。</p>

---

## 工程

- Xcode 工程：`Verto.xcodeproj`
- App 名称：译境（非中文界面下显示为 Verto）
- 界面语言：简体中文、English、日本語、한국어、Español（可在系统设置的 App 语言里切换；简体中文为源语言，字符串目录 `Verto/Localizable.xcstrings` + `Verto/InfoPlist.xcstrings`）
- Bundle ID：`com.yspritan.verto`
- 最低系统：iOS 17
- 技术：SwiftUI、原生 TabView、Observation、AVFoundation、PhotosUI、Speech（SpeechAnalyzer/SFSpeechRecognizer）、Translation；iOS 26+ 的系统标签栏自动采用 Liquid Glass。
- 权限：语音对话需要麦克风权限；iOS 17–25 回退路径额外需要语音识别权限（两个用途描述均已写入工程 INFOPLIST_KEY_*）。

## 功能

### 文字翻译

点击原文后，真实原文卡直接以一根 `.spring(duration: 0.45, bounce: 0.12)` 弹簧从静息高度展开到整个视口，软件键盘在下一个 runloop 请求焦点、与展开并行升起；tab bar 隐藏或键盘安全区变化时弹簧带速度重定向，不等待布局稳定，也没有快照覆盖层或结束时的交叉淡化交接。文字、听写和语言调整先保存为草稿；只有点击右上角陶土色圆形对勾“完成并翻译”后才提交并发起真实翻译。结果页继续支持交换语言、朗读、复制、收藏与分享。

**翻译引擎与缓存**：翻译走自建中转（`tools/translate-relay`，部署在 Cloudflare Workers），中转后面是 Cloud Translation v3。服务账号私钥留在中转、不随 App 分发；客户端只带一个共享密钥请求头。中转地址与令牌由 gitignore 掉的 `Secrets.local.xcconfig` 在构建时注入，**没配的构建落到系统 Translation 框架**（离线、免费、需 iOS 18+，模拟器不可用）。提交后显示加载态，失败展示本地化错误文案与重试按钮；新提交会取消在途请求。相同引擎、语言对与原文的成功结果在进程内 LRU 缓存（200 条），重复翻译同步复用、不再请求网络；失败不缓存，重试永远走真实请求。源语言支持“自动检测”（契约里省略 source 即自动检测，检测结果随译文回来），语言对栏展示检测结果，检测出语言后才可交换；**Cloud Translation v3 不返回备选译法，所以“其他译法”入口现在恒为隐藏**（代码本就是无备选时隐藏）。

### 语音对话翻译

点麦克风开始聆听，边说边在活动气泡里显示 volatile 转写与低透明度的实时粗译（350ms 节流的 re-translation，masked 源文本 + generation 号丢弃过期回包防闪烁）；volatile 稳定 ≥0.9s 且 RMS 静音 ≥0.55s 自动断句（或轻点手动结束，55s 硬上限）。

**识别永不等翻译**：断句只是识别流上的切分点（`finalize(through: nil)`），句子定稿立即上屏（粗译预览 + 翻译中态），权威翻译按气泡异步填充、失败在气泡内重试，期间识别对下一句持续进行、句界零丢词（轨道状态按消费基线切分）；自动朗读排队在无人说话的间隙播放，播放时挂起识别输入防回采。

**双语自动检测（默认）**：中间麦克风为语言对内自动识别——每个语言一条识别轨并行喂同一路音频，按 NLLanguageRecognizer 语言概率 + 识别置信度 + 文本量打分选胜者（带滞回防逐字闪烁），检测语言决定气泡侧别与翻译方向，中英可无缝混说；单轨失败不打断整段（其余轨继续）。点语言圆钮手动锁定一侧语言，再点一次回到自动；状态区显示当前模式（「正在聆听 · English / 中文」或单语言）。

**识别链路**：iOS 26+ 且运行时可用（`SpeechTranscriber.isAvailable` 且 supportedLocales 非空）走 SpeechAnalyzer 挂多个 SpeechTranscriber 模块（纯本地、只需麦克风权限，多模块失败降级单轨），否则回退 SFSpeechRecognizer 多识别器并行（iOS 17–25 与模拟器；双权限）。

**实时性关键**：识别链是会话级持久的——prepare 阶段就以 `.processLifetime` 模型驻留 + `prepareToAnalyze` 预热建好 analyzer，句间用 `finalize(through: nil)` 切分而非销毁重建（重建 = 每句话付一次秒级模型加载），TTS 播放与句间间隙靠挂起音频源丢弃 buffer 维持半双工（音频会话不做逐句 setActive 循环）；`.fastResults` 加速首个 volatile；断句阈值 volatile 稳定 0.9s + 静音 0.55s；胜者判定在开口 0.7s 内免滞回自由改选。

**翻译路由**：苹果 Translation 框架优先——iOS 26+ 直接构造 `Translation.TranslationSession(installedSource:target:)`（26.4+ 为 partial 另建 `.lowLatency` 策略会话），iOS 18–25 经 AppShell 根部常驻宿主视图借 session；模拟器/iOS 17/语言包未装/框架报错时自动回退到与文字、相机页相同的翻译服务，并按语言对记忆决策（os.Logger 记录原因）。

来电中断、退后台、切 tab 都会停止收音，对话内容跨 tab 保留（controller 由 AppShell 持有）。气泡带朗读按钮；页面头部右上角有朗读模式直达菜单（与设置页同步）；语言对里的「自动检测」在语音页按对端语言消解为具体语言。final 译文进程内缓存（仅 final，partial 不进 LRU）；final 翻译失败时气泡内可重试。波形由实测麦克风电平（vDSP RMS）驱动。

### 相机翻译

对准文字按快门（或从相册选图），端侧 OCR 识别整幅画面，**译文就地叠加回原文所在的位置**——按识别出的四边形定位、跟随原文倾角旋转、底色与字色从原图采样，用采样到的底色盖掉原文再写上译文，字号按行高起算并自适应收缩塞进原框。

**两套识别引擎**。默认是系统的 Vision（`VNRecognizeTextRequest` revision 3），装了高精度模型包后改用 PP-OCRv6（转成 Core ML，两段式：DB 检测出每行的旋转框，CTC 识别逐行读字）。模型包不进 IPA，首次进相机页在后台下载，没下完的这段时间照常用系统引擎，下完自动切换。设置页可在三档间切换，也可以删掉退回系统引擎：

| 档位 | 下载体积 | 准确率 | 覆盖文字 |
|---|---|---|---|
| 轻量 | 2.8 MB | 73.5 | 中文、拉丁（无日文假名） |
| 均衡（默认） | 12.4 MB | 81.3 | 中文、日文、拉丁、希腊 |
| 最高精度 | 45.3 MB | 83.2 | 同均衡 |

准确率取自 PaddleOCR 官方 16 类真实照片基准的加权平均；同一基准上 PP-OCRv5_mobile 为 73.7、Gemini-3.1-Pro 71.4、GPT-5.5 64.2。三档的识别耗时在 Mac 上实测为 10 / 33 / 58 毫秒（18 行菜单，含检测），差异感知不到，真正的取舍是下载体积。

**PP-OCRv6 三档的字表里都没有谚文**，所以韩语始终交回系统引擎识别；轻量档另外缺日文假名，日文在该档也走系统引擎。这个分流在 `RoutingTextRecognitionService` 里，模型加载失败或识别抛错时同样回落——高精度识别是增强而不是前提，任何一环缺失都不影响相机页可用。

识别出的行按位置合并成段落再整段送翻译（逐行翻译会把一句话切碎）：同栏、行距在一行半以内、倾角相近、**字号相当**才算同段——标题与紧邻正文只差一行间距，光看间距会被并成一段，字号之比才是判据；分栏菜单的左右两列因水平投影零重叠而不会被并到一起。**判据不只看相邻两行，新行还要与整块的首行相容**——只跟上一行比，块会顺着一串各自合格的小台阶漂走，十几行后首尾已毫不相干，而并集取四角最外侧，一次误连就把中间整片圈进同一个框。两条识别引擎喂给合并的是同一口径的紧框：PP-OCRv6 的检测框会按 `unclip_ratio` 外扩，外扩量随长宽比变化，拿它当判据等于让阈值随每行形状漂移，所以外扩框只用于裁剪送识别。

**拍出来的照片就是取景器里那副样子。** App 锁定竖屏，取景与照片输出都固定跟着界面而不是跟着重力——横持或倒持时拿到的是一张躺着的照片，与按下快门那一刻看到的构图完全一致，App 不替用户“把画面转正”。歪只歪在送去识别的那份副本里：按 `AVCaptureDevice.RotationCoordinator` 读到的重力方向把副本转正（不转的话检测器会把竖行的短边当成上边，裁出来的行被重采样成糊块，一块只剩一两个字符），识别完再把四边形按同样的圈数转回原图坐标。显示与取色始终吃那张没动过的原图，所以全程仍然只有一套坐标系。

翻译按去重后的原文整页一次提交（服务按条数与码点数分批），**识别不等翻译**——块先带原文上屏，一批译文到就填一批，单块失败只在该块内重试，不拖垮整页；同一张图里重复出现的短句只发一次请求，跨轮复用进程内 LRU 缓存。失败时块内显示的是真实原因（令牌无效 / 配额用尽 / 网络不通 / 语言包未装各不相同），不是一个没有信息的红叹号。

轻点任意一块看原文/译文对照，可复制、朗读（用目标语言音色）、存入历史记录（与文字页共用同一份去重与插入逻辑）。闪光灯接 `AVCapturePhotoSettings.flashMode`、曝光按钮接 `AVCaptureDevice.exposureMode`，设备无闪光灯时按钮置灰。换语言对会按同一张图重译，不要求重拍。

相机权限在进入页面时惰性请求，被拒时页面内给出说明与「前往设置」；设备无可用相机（含模拟器）时不画假取景器，改为提示从相册选择、快门置灰。切走 tab 或退到后台会停掉采集会话。

### 语言、历史与收藏

- 语言选择：源/目标语言切换、名称/别名/代码搜索、选择状态与空结果状态。
- 历史与收藏：共享翻译记录、收藏过滤、即时星标切换、点选记录回填文字页。

### 设置与外观

文字页右上角入口打开设置页。翻译模型可切换——谷歌翻译当前可用，自研模型与 LLM 翻译（自带 API Key）以“即将推出”禁用占位展示；「语音对话」分区可选译文朗读行为（仅显示文字 / 翻译完自动朗读 / 仅戴耳机时朗读——耳机含有线、蓝牙与 USB，路由实时检测）；通用偏好含“翻译后自动朗读译文”（仅作用于文字页）。翻译引擎、朗读模式、偏好与上次使用的语言对经 UserDefaults 持久化，首次启动保留演示内容，此后按记忆的语言对空白开始。

**深色模式**：跟随系统或在设置中手动指定外观，自适应配色贯穿全部页面与组件。

### 导航与动效

- 文字、语音、相机作为原生 TabView 的三个顶层区域；常态下标签栏持续可见并保留各 tab 状态，仅文字页专注键入时由系统暂时隐藏，提交草稿后恢复。iOS 26+ 由系统呈现 Liquid Glass，iOS 17–25 使用对应系统标签栏外观；selection 实际变化时触发系统触觉反馈。
- 专注键入态不向 `.keyboard` 工具栏放置“完成”；软件键盘和硬件键盘均使用固定在页面右上角的提交按钮，避免底部操作与系统标签栏重叠。
- 键入转场只有一个状态源：草稿是否存在。原文编辑器全程保持同一身份，展开与收回都是对真实卡片的布局动画（渲染树逐帧插值各视图 frame，卡面 Shape 每帧重算路径保持 22pt 连续圆角不变形），没有几何测量、跨事务验证或阶段编排；转场全程可交互、可打断，展开途中点对勾会带着当前速度平滑反向。结果区通过约 0.16 秒透明度 transition 在纸面下淡出/淡入，位置跟随布局弹簧；对勾延迟约 40ms 后从 0.84 倍轻弹至原尺寸。
- 开启“减弱动态效果”时，布局直接切换到终态（无尺寸、位移、缩放动画），结果区与头部按钮仅保留约 0.12 秒透明度淡化；键盘与 tab bar 继续使用系统行为。

## 现状与路线

文字翻译已接入自建中转 + Cloud Translation v3（部署说明见 `tools/translate-relay/README.md`；没配中转的构建落到系统离线翻译）；语音对话为真实语音识别与翻译管线（见上）；相机翻译为真实的端侧 OCR + 翻译管线（系统 Vision 或下载后的 PP-OCRv6，见上）。自研模型与基于 LLM 的翻译引擎为后续计划，暂以占位形式出现在设置页——未来流式语音翻译引擎的接缝已留在 `Verto/Voice/AppleTranslationService.swift` 底部（`StreamingSpeechTranslating` 协议桩，挂在语音会话层而非 text→text 层）。

## 在 Xcode 中运行

1. 用 Xcode 打开 `Verto.xcodeproj`。
2. 选择 `Verto` Scheme。
3. 选择任意 iOS 17 或更高版本的 iPhone 模拟器。
4. 点击 Run。

**直接运行即可编译**，不需要先配置任何东西——只是那份构建没有中转，翻译会落到系统 Translation 框架（真机 + iOS 18 以上；模拟器上苹果不支持，会显示“系统翻译不可用”）。

想用在线翻译，先按 [`tools/translate-relay/README.md`](tools/translate-relay/README.md) 部署自己的中转，然后：

```bash
cp Secrets.local.xcconfig.example Secrets.local.xcconfig
```

把主机名和共享密钥填进去。`Secrets.local.xcconfig` 已在 `.gitignore` 里，**任何真值都不要写进 `Secrets.xcconfig`**——那个文件是要提交的。填好后中转在模拟器上也能用（就是普通 HTTPS）。

如果终端的 `xcode-select` 指向 Command Line Tools 或旧版 Xcode，可用 `DEVELOPER_DIR` 指定 Xcode 后从命令行构建：

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

## 模拟器限制

**苹果官方约束，已实测核实**：SpeechTranscriber 与 Translation 框架在 iOS 模拟器上都不可用（模拟器无 ANE、无翻译模型）。模拟器上语音页自动落到 SFSpeechRecognizer + 谷歌翻译回退链路，且实测（iOS 27 模拟器）：**en-US 因系统强制本地识别器而无法初始化（kLSRErrorDomain 300，端上/服务器模式都挂），zh-CN 走服务器识别完全可用**——所以模拟器上说中文可以真实走通「识别→翻译→朗读」，说英文会由多轨自动检测静默跳过失败轨（仅英文单轨时给出「模拟器暂不支持这种语言的识别」文案）。

模拟器同样**没有摄像头**：相机页的取景与拍照只能在真机验证，模拟器上相机页显示“此设备没有可用的相机”并把相册入口提到主位。**两套文字识别在模拟器上都可用**：系统 Vision（已实测 revision 3、33 种语言，`Language.all` 七种全部支持）与 Core ML 版 PP-OCRv6 都能真跑，相册选图 → OCR → 翻译 → 叠加这条链路在模拟器上完整可用。两条诊断探针可随时重跑：`VertoTests/VisionAvailabilityProbeTests`（报告落盘 /private/tmp/vision-availability-probe.txt）与 `VertoTests/PaddleOCRProbeTests`（需先用 `tools/build-ocr-models` 产出模型，再以 `TEST_RUNNER_VERTO_OCR_MODEL_DIR=<某一档目录>` 指路；报告落盘 /private/tmp/paddle-ocr-probe.txt，未指路时跳过而不是假装通过）。

诊断可随时重跑 `VertoTests/SpeechAvailabilityProbeTests`（报告落盘 /private/tmp/speech-availability-probe.txt）。SpeechAnalyzer 路径、系统离线翻译、语言模型下载、`.lowLatency` 策略、双轨真机表现与耳机检测只能在真机验证。UI 测试通过 `--uitest-canned-speech` 与 `--uitest-canned-camera` 注入脚本化识别、静音 TTS 与合成拍照，全程不碰真实音频与相机。

## 自动化测试

工程包含 `VertoUITests` UI 测试 Target，验收目标覆盖文字翻译与收藏、语言搜索与选择、语音「待机 → 聆听 → 定稿气泡 → 暂停」全流程、语音朗读模式设置选择、相机「快门 → 就地叠加译文 → 轻点看对照 → 存入历史」全流程、原生 TabView 的跨 tab 切换/选中态同步/状态保留、“键入草稿 → 完成并翻译 → 恢复结果页”，以及 DEBUG “减弱动态效果”终态回归等主流程。

UI 测试统一携带 `--uitest-canned-translation`、`--uitest-canned-speech`、`--uitest-canned-camera` 与 `--uitest-reset-settings` 启动参数：前三者注入固定演示译文、脚本化语音识别与合成拍照+识别（不访问真实网络、不碰麦克风、TTS 与相机），后者复位持久化偏好，保证断言稳定。合成告示牌的画面与“识别”出的文字块共用同一份行数据，叠加层因此落在真正画着字的位置上。

界面已多语言化，测试统一钉在简体中文运行：共享 Scheme 的 Test action 指定 `zh-Hans`（管住宿主 app 里的单元测试），UI 测试另在启动参数里显式传 `-AppleLanguages`，中文文案断言因此不受模拟器语言影响；`LocalizationTests` 与英文界面冒烟测试覆盖各语言资源的完整性与真实加载。

单元测试覆盖对话控制器状态机（节流、generation 过期丢弃、端点计时、TTS 门控矩阵、失败重试、缓存命中等）、翻译路由回退链、朗读模式持久化与 locale 映射。文字键入动画的自动测试只验证进入编辑态、退出编辑态与稳定终态；动画是否可见、是否跳动或出现鬼影，以 iPhone 模拟器的真实屏幕录屏验收。

可用任意已安装的 iPhone 模拟器运行；例如：

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

模拟器可以验证 selection 确实发生变化，但无法验证实体震感；触觉强度与手感需要在真实 iPhone 上最终确认。

## 许可证

本项目以 [Apache License 2.0](LICENSE) 授权。
