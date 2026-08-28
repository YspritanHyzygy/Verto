# 拍照翻译的界面结构与实现方式

这份文档解释 Verto 拍照翻译当前由哪些部分组成、一次拍照怎样变成译图，以及为什么界面可能显示翻译完成，照片却看不到译文。

文中的类名和函数名用于定位源码。每个技术词第一次出现时都会补一段人话解释。

## 先给结论

拍照翻译可以看成一条加工流水线，前面负责拍照和认字，中间负责翻译，后面负责把译文画回照片，最外层负责显示和交互。

当前实现已经能完成以下工作：

- 拍照或从相册读取图片。
- 识别图片里的文字和文字位置。
- 翻译识别出的文字。
- 尝试擦除原文并把译文画回原位置。
- 在结果画布中缩放、拖动、切换原文与译文。
- 点击文字查看详情、朗读、复制或存入历史记录。

目前最关键的问题出在最后两步之间。程序把文字翻译完成和译文成功画进照片当成了相近的完成状态。视觉重建失败时，程序可以交回一张看起来仍是原图的结果，同时把状态设为 `done`。这与用户报告的现象高度吻合，真实照片路径仍需要定向复现来确认。

## 一、用户看到的界面分成哪些部分

拍照翻译是 `AppShell` 里相机标签对应的页面。页面本体由 `CameraTranslateView` 负责。

### 1. 拍摄前

拍摄前的界面大致分成四层：

| 位置 | 用户看到的内容 | 负责的代码 |
| --- | --- | --- |
| 背景 | 实时相机画面 | `CameraPreviewView` |
| 顶部 | 源语言、交换按钮、目标语言 | `CameraTranslateView.languageControls` |
| 中间 | 权限错误、无相机提示或失败提示 | `CameraTranslateView.viewfinderStatus` |
| 底部 | 相册、快门、闪光灯 | `CameraTranslateView.captureControls` |

底部仍然保留全局标签栏，用户可以切换文字、语音和相机页面。

### 2. 处理中

按下快门后，顶部会依次显示当前阶段：

```text
正在拍照
    ↓
正在识别文字
    ↓
正在翻译
    ↓
正在生成译图
```

这些状态来自 `PhotoTranslationController.Phase`。页面只负责显示，真正的工作由控制器和各个服务完成。

### 3. 结果页

结果页会替换掉实时取景和底部拍摄按钮，主要包含：

- 一张可以双指缩放、单指拖动的照片画布。
- 顶部语言控件。
- 原文与译文切换控件。
- 右上角重拍按钮，图标是 `xmark`。
- 翻译完成状态。
- 底部全局标签栏。

照片画布由 `TranslatedPhotoCanvas` 接入 SwiftUI，再由 UIKit 的 `TranslatedPhotoCanvasView` 真正实现。

### 4. 文字详情

结果页中点击文字后会出现底部详情卡。详情卡包含：

- 原文。
- 译文或翻译错误。
- 复制。
- 朗读。
- 存入历史记录。
- 重试。
- 关闭。

详情卡由 `PhotoSelectionCardView` 负责。

## 二、代码结构

下面这棵树表示各部分的从属关系：

```text
AppShell
└── CameraTranslateView                 页面和控件
    ├── CameraPreviewView               实时相机预览
    ├── PhotoTranslationController      整条流程的调度中心
    │   ├── PhotoCaptureSource          拍照
    │   ├── TextRecognitionService      OCR 文字识别
    │   ├── TranslationService          文字翻译
    │   └── PhotoReconstructing         把译文画回照片
    └── TranslatedPhotoCanvas           结果画布的 SwiftUI 入口
        └── TranslatedPhotoCanvasView   缩放、拖动、点选和无障碍
            ├── SelectionHandleView     文字选择手柄
            └── PhotoSelectionCardView  文字详情卡
```

### `AppShell`

`AppShell` 是应用最外层的组装位置。它创建并保存以下长期对象：

- `TranslationSession`，保存当前语言和文字翻译状态。
- `PhotoTranslationController`，保存拍照翻译状态。
- `OCRModelCatalog`，管理 OCR 模型和实际识别路线。
- `AppSettings`，保存翻译引擎和外观等设置。

这些对象放在外层后，用户切换标签页时不会丢失刚拍的照片和翻译状态。

### `CameraTranslateView`

`CameraTranslateView` 负责界面编排。它决定当前显示实时预览还是结果画布，也决定顶部和底部有哪些按钮。

它本身不做 OCR 和图片重建。它把用户操作交给 `PhotoTranslationController`，再根据控制器的状态刷新界面。

### `PhotoTranslationController`

`PhotoTranslationController` 是调度中心，也可以理解为这条流水线的项目经理。它不亲自完成每项加工，但知道当前应该叫谁工作、工作结果放在哪里、旧任务什么时候失效。

它保存的主要数据包括：

| 数据 | 含义 |
| --- | --- |
| `image` | 原始照片 |
| `translatedImage` | 尝试重建后的译图 |
| `blocks` | 已识别的文字块、译文和位置 |
| `unresolvedBlockIDs` | 已翻译但没有成功画回照片的文字块 |
| `phase` | 当前处理阶段 |

### `PhotoCaptureSource`

`PhotoCaptureSource` 是拍照能力的统一接口（协议）。正式应用使用 `CameraCaptureSource`，UI 测试使用 `CannedPhotoCaptureSource`。

正式相机实现负责：

- 选择后置摄像头。
- 启动和停止相机会话。
- 自动对焦和自动曝光。
- 点按对焦测光。
- 捏合变焦。
- 闪光灯。
- 拍照方向。
- 在快门按下时冻结预览。

测试实现会直接返回一张固定告示牌图片，因此模拟器不需要真实摄像头。

### `TextRecognitionService`

`TextRecognitionService` 是 OCR 的统一接口。OCR 的全称是 Optical Character Recognition，意思是从图片里认出文字。

识别结果不只是字符串。每一块结果还会保留：

- 整块文字。
- 每一行文字。
- 每一个词或字符片段。
- 每一行和每一个片段在照片中的四边形位置（`TextQuad`）。

四边形位置很重要。后面的译图、点击文字和选择文字都依赖同一套坐标。

生产环境会通过 `OCRModelCatalog` 和 `OCRRoutingPolicy` 选择实际识别器。候选包括系统 Vision 和已经安装的 PP-OCR 模型。设备能力、语言范围和模型状态都会影响选择结果。

### `PhotoReconstructing`

`PhotoReconstructing` 是视觉重建接口。当前实现是 `AdaptiveBackgroundReconstructor`。

它负责两件事：

1. 在原文字区域估算背景并擦掉原字。
2. 把译文按照原文字框的位置和角度画回去。

这一步决定用户最后能不能在照片上直接看到译文。

### `TranslatedPhotoCanvasView`

结果画布使用 UIKit 的 `UIScrollView`。UIKit 是 iOS 较早建立的一套界面框架，适合处理复杂的缩放、拖动和手势优先级。SwiftUI 通过 `UIViewRepresentable` 把它接进页面。

画布同时负责：

- 显示原图或译图。
- 缩放和双轴拖动。
- 保存当前缩放位置。
- 判断用户点中了哪一块文字。
- 原文模式下选择单词或连续文字。
- 显示选择手柄和详情卡。
- 生成 VoiceOver 可以读取和点击的虚拟元素。

这些功能共用一套照片坐标，因此缩放后文字位置和点击区域仍能跟着照片移动。

## 三、一次拍照翻译具体怎样运行

控制器使用下面这组状态：

```text
idle
  ↓
ready
  ↓
capturing
  ↓
recognizing
  ↓
translating
  ↓
reconstructing
  ↓
done

任一步出错时可以进入 failed
```

### 第一步：准备相机

页面出现后会调用 `PhotoTranslationController.start()`。

控制器让 `PhotoCaptureSource` 启动相机会话。相机可用时进入 `ready`。权限被拒绝或没有相机时，页面显示对应提示，并保留相册入口。

### 第二步：拍照

用户点击快门后会调用 `PhotoTranslationController.capture()`。

控制器先检查当前是否已经在处理另一张照片。条件允许时，它会：

1. 把状态改成 `capturing`。
2. 冻结当前预览画面。
3. 从相机取得 `CapturedPhoto`。
4. 保存照片和拍摄方向。
5. 启动 OCR。

相册图片会通过 `PhotoTranslationController.use()` 进入同一条后续流程。

### 第三步：把图片送去 OCR

照片可能带有方向信息。控制器会先把一份识别用副本转正，然后把它送给当前识别器。

识别器返回文字块后，控制器再把文字框旋转回原照片坐标。原照片本身保持用户拍到的方向。

每个文字块会变成 `TranslatedBlock`。它包含原文、译文、等待状态、错误和行级位置。

### 第四步：批量翻译

控制器先对重复原文去重，再检查 `TranslationMemoryCache`。缓存命中时直接复用已有译文。

其余文字交给 `TranslationService.translateBatch()` 批量翻译。每一批结果返回后，控制器把译文填回所有匹配的文字块。

某一块失败时，失败信息保存在该块里，用户可以稍后点开详情重试。

### 第五步：生成译图

所有文字块都结束等待后，控制器进入 `reconstructing`，并调用 `AdaptiveBackgroundReconstructor`。

重建器会逐行处理：

1. 用透视校正把倾斜文字框临时拉成矩形（`CIPerspectiveCorrection`）。
2. 检查文字框边缘的颜色变化，判断背景是否足够平整。
3. 根据背景色和字色差异建立字形遮罩（`glyph mask`）。
4. 用估算背景覆盖原字。
5. 测量译文能否以可读字号放进原框。
6. 用系统字体绘制译文。
7. 把矩形补丁变回原来的透视形状（`CIPerspectiveTransform`）。
8. 将补丁合成回原照片。

区域外像素保持原图字节，Core Image 合成范围限制在已经接受的文字框内。

### 第六步：发布结果

重建结束后会得到 `PhotoReconstructionResult`：

- `image` 是最终结果图。
- `inlinedBlockIDs` 表示已经画进照片的文字块。
- `unresolvedBlockIDs` 表示译文已经得到，但视觉重建没有接受的文字块。

控制器把结果一次性写入 `translatedImage`，再把状态改成 `done`。一次性写入也叫原子提交，意思是界面只会看到旧图或完整新图，不会看到半张新图。

### 第七步：显示和交互

结果画布根据顶部模式选择图片：

- 原文模式使用 `image`。
- 译文模式优先使用 `translatedImage`。
- `translatedImage` 尚未到达时暂时使用原图。

译文模式中，轻点文字块会打开该块的详情卡。

原文模式中，轻点一个词会翻译该词。长按并拖动可以选择连续文字，两个蓝色手柄可以继续调整范围。

## 四、缩放和裁切怎样工作

结果画布先按 `aspectFill` 计算照片尺寸。`aspectFill` 的意思是让照片铺满整个可视区域，照片边缘可以超出屏幕。

画布也允许用户缩小到完整照片可见的 `aspectFit` 状态。`aspectFit` 的意思是完整照片都放进屏幕，边缘可能出现空白。

当前初始规则会比较照片方向和屏幕方向。两者同为横向或同为纵向时，初始倍率通常保持铺满。照片因此可能在进入结果页时直接裁掉左右或上下边缘。用户可以双指缩小查看完整照片，界面没有明确提示这个操作。

拖动边界使用半屏宽度的内边距。这样照片边缘最多可以移动到屏幕中央，画布不会被无限拖进黑色区域。

## 五、它怎样处理同时发生的任务

拍照、OCR、翻译和重建都包含异步任务。异步的意思是这些工作会在不同时间完成，完成顺序可能变化。

`PhotoTranslationController` 使用一个递增的 `generation` 号码管理这些任务。可以把它理解为每轮处理的批次号。

每次重拍、换语言或重试时，控制器会增加批次号并取消上一轮任务。旧任务即使晚一点返回，也必须先核对批次号。号码已经过期时，旧结果没有资格写回界面。

控制器分别管理：

- 整体拍照和识别任务。
- 批量翻译任务。
- 单块重试任务。
- 图片重建任务。
- 后台重建工作线程。

这部分结构较复杂，但它对应真实的任务竞争。当前代码没有通过固定等待时间来猜测任务是否结束。

## 六、为什么会出现翻译完成但照片没变化

这是目前最需要理解的地方。

### 程序对完成的定义

`done` 表示下面这些步骤已经收尾：

- OCR 已经返回。
- 每个文字块已经拿到译文或错误。
- 图片重建器已经返回一个结果。

这个状态没有要求每一块译文都成功画进照片。

### 重建器会主动放弃某些区域

`AdaptiveBackgroundReconstructor` 使用保守规则。以下情况都可能让某一行进入 `unresolvedBlockIDs`：

- 背景纹理、阴影或渐变超过允许范围。
- 字形遮罩覆盖比例异常。
- OCR 文字框太小。
- 译文比原文长，字号缩小后仍放不进原框。
- 多行译文无法稳定分配回原来的行数。
- 透视变换或图片缓冲区创建失败。

重建失败的区域会保留原图。所有区域都失败时，`translatedImage` 仍然可以是一张视觉上几乎等同原图的图片。

### 界面仍然可以点出译文

译文保存在 `blocks` 中，文字点击区域也来自 OCR 坐标。图片是否成功重建不会清空这些数据。

因此会出现下面这条完整路径：

```text
OCR 成功
  ↓
文字翻译成功
  ↓
视觉重建拒绝这些文字框
  ↓
结果图保留原文
  ↓
状态进入 done
  ↓
用户仍可点击文字查看译文
```

这条源码路径与用户报告高度吻合。实际设备上的具体失败条件仍需用对应照片复现，当前结论属于源码解释，尚未成为真实照片复现结论。

## 七、为什么模拟器测试容易通过

相机 UI 测试使用 `CannedSignFixture`。它是一张专门生成的固定告示牌：

- 背景颜色完全平整。
- 文字位置由代码精确给出。
- OCR 直接返回同一份固定文字和坐标。
- 测试译文长度适合原文字框。
- 没有真实相机噪点、阴影、反光、运动模糊和复杂透视。

这张图片覆盖了成功路径，可以证明界面有能力显示一张译图。它无法代表真实照片中最容易触发重建放弃的情况。

当前测试还需要补充失败路径夹具，例如纹理背景、长译文、小字、倾斜文字和部分区域重建失败。

## 八、当前结构中做得比较稳的部分

### 一套画布坐标

原图、译图、缩放、文字位置、点击区域和选择手柄都在同一个 `UIScrollView` 坐标系统里。照片移动时，文字交互也会跟着移动。

### 一套流程状态

拍照、识别、翻译和重建状态集中在 `PhotoTranslationController`。页面没有再维护一份平行状态机。

### 旧任务失效机制

`generation` 能阻止旧照片或旧语言任务覆盖新结果。相机和网络任务中确实存在这种竞争。

### 保守的图片处理

重建器在判断不稳时保留原图。它降低了误删招牌纹理、阴影或物体边缘的风险。

### 无障碍基础

结果画布会为每个文字块或词生成 VoiceOver 元素。选择手柄支持可调动作，图标按钮也有无障碍名称。

## 九、当前结构中最需要处理的问题

### 1. 完成状态表达不准确

用户看到翻译完成，会自然理解为照片已经显示译文。当前状态只表示流水线结束。

### 2. 视觉重建失败时缺少可见回退

重建失败的文字块只保留点击能力。用户需要先发现原图中的文字可以点击，才能看到译文。

### 3. 结果页同时承担太多操作

结果页同时提供图片缩放、原文与译文切换、块级详情、词级翻译、连续选词、朗读、复制、保存、重试和重拍。两种显示模式里的点击含义也不同，界面没有解释这些差异。

### 4. 顶部控件空间紧张

语言控件、显示模式和重拍按钮放在同一行。窄屏或较长语言名称会压缩原文与译文按钮。

### 5. 结果初始画面可能裁切

画布默认优先铺满屏幕。完整照片需要用户主动缩小，边缘文字可能在第一眼不可见。

### 6. 详情卡的信息密度不均匀

详情卡使用固定高度，短文本会留下较大空白。多个操作只显示图标，视觉上需要用户猜测含义。

### 7. 一个文件承担多种职责

`TranslationOverlay.swift` 同时包含图片重建、字形遮罩、译文排版、结果画布、手势、文字选择、无障碍元素和详情卡。它们共享同一坐标系统，但修改其中一层时需要理解很多无关细节。

## 十、推荐的整理顺序

当前结构适合局部收敛。相机采集、OCR 路由、翻译调度、坐标数据和异步任务管理可以继续沿用。

### 第一阶段：修复 `BUG-003`

先建立一条明确规则：每个成功翻译的文字块都必须在结果画面中可见。

推荐的显示顺序：

1. 视觉重建成功时，显示已经融入照片的译文。
2. 视觉重建失败时，在同一个结果画布上显示清晰的译文覆盖块。
3. 翻译失败时，明确显示失败区域和重试入口。

`PhotoReconstructionResult` 已经提供 `inlinedBlockIDs` 和 `unresolvedBlockIDs`，可以直接告诉画布哪些块需要可见回退。回退层继续使用同一套 `TextQuad` 坐标，保持一套数据和一套画布。

这一阶段需要加入更接近真实照片的测试夹具，并用真实照片验证结果画面。

### 第二阶段：细化 `TRY-003`

译文可见性稳定后，再整理结果页的信息层级：

- 缩减顶部常驻控件。
- 让完成状态在完成后退出主要视觉层级。
- 明确原文与译文切换。
- 缩小详情卡，给常用操作增加可读标签。
- 重新评估词级选择是否属于拍照翻译的第一版核心流程。

### 第三阶段：处理 `TRY-001`

将结果态的退出或重拍操作放回底部主要操作区，统一拍摄前后的操作位置和用户预期。

### 整体重写会重复承担的成本

完整重写需要重新处理相机会话、方向转换、OCR 路由、坐标映射、批量翻译、任务取消、结果缩放、手势冲突和无障碍。视觉输出规则没有先明确时，新实现仍可能得到同样的空结果。

推荐路线保留已经验证过的底层能力，集中修改视觉输出契约和结果页结构。

## 十一、常见术语

| 术语 | 大白话解释 |
| --- | --- |
| OCR | 从图片里认出文字 |
| ASR | 从声音里认出文字，与本页拍照流程无关 |
| 状态机 | 明确规定当前处于哪一步，以及下一步能去哪里 |
| `TextQuad` | 文字在照片里的四角坐标 |
| 归一化坐标 | 用 0 到 1 表示位置，图片分辨率变化后仍能换算 |
| `aspectFill` | 铺满屏幕，允许裁掉边缘 |
| `aspectFit` | 显示完整图片，允许出现空白边 |
| 透视校正 | 把倾斜的文字区域临时拉正 |
| 字形遮罩 | 标出图片中哪些像素属于原文字 |
| 视觉重建 | 擦掉原字、补背景、画译文 |
| 回退 | 高级处理失败后使用可靠的基础显示方式 |
| 原子提交 | 完整结果一次出现，界面不显示半成品 |
| `generation` | 每轮任务的批次号，用来拒绝过期结果 |
| VoiceOver | iOS 的屏幕朗读和辅助操作功能 |

## 十二、主要源码入口

| 文件 | 重点符号 | 作用 |
| --- | --- | --- |
| `Verto/AppShell.swift` | `AppShell` | 组装页面、控制器和服务 |
| `Verto/Screens/CameraTranslateView.swift` | `CameraTranslateView` | 拍摄页和结果页界面 |
| `Verto/Camera/PhotoTranslationController.swift` | `PhotoTranslationController` | 流程状态和任务调度 |
| `Verto/Camera/PhotoCaptureSource.swift` | `CameraCaptureSource` | 真实相机和预览 |
| `Verto/Camera/TextRecognition.swift` | `TextQuad`、`RecognizedTextBlock` | OCR 结果和坐标结构 |
| `Verto/Camera/VisionTextRecognitionService.swift` | `VisionTextRecognitionService` | 系统 Vision OCR |
| `Verto/Camera/OCRRoutingPolicy.swift` | `OCRRoutingPolicy` | OCR 路由规则 |
| `Verto/Camera/TranslationOverlay.swift` | `AdaptiveBackgroundReconstructor`、`TranslatedPhotoCanvasView` | 译图生成和结果交互 |
| `Verto/Camera/CannedPhotoCapture.swift` | `CannedSignFixture` | 模拟器相机测试夹具 |

阅读源码时可以先看 `CameraTranslateView` 的界面结构，再看 `PhotoTranslationController` 的状态流，最后进入 `TranslationOverlay.swift` 查看视觉重建和结果画布。这个顺序与用户实际经历的流程一致。
