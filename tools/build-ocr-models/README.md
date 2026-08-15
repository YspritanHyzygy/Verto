# OCR 模型包构建

把 [PP-OCRv6_small](https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec) 的官方 ONNX
转成 Verto 用的 Core ML 模型包。产物不进仓库、不进 IPA，发布到 GitHub Release，
由 app 在首次进入相机页时后台下载。

```bash
uv venv --python 3.12 .venv && source .venv/bin/activate
uv pip install -r requirements.txt
python build_models.py --out ../../build/ocr-models
```

产出 `verto-ocr-models-v<版本>.zip` 与 `manifest.json`（含 SHA-256）。
把 zip 传到 GitHub Release，并把 URL 与 SHA-256 填进 `Verto/Camera/TextRecognitionModelPack.swift`。

## 为什么是 Core ML 而不是 ONNX Runtime

用 ONNX Runtime 直接跑官方模型更省事，但要往 app 里链进一个 25MB+ 的 C++ 运行时，
IPA 直接变大。转成 Core ML 后 IPA 一个字节都不增加，还能上神经引擎，
且 fp16 让下载体积从 29.6MB 降到 14.8MB。代价是转换链路变长，所以脚本每步自带核对。

## 为什么是 small 档

PP-OCRv6 只有三档，2026-08 实测：

| 档位 | 下载体积（Core ML fp16） | 准确率 W-Avg |
|---|---|---|
| tiny | ~3 MB | 73.5 |
| **small** | **14.8 MB** | **81.3** |
| medium | ~66 MB | 83.2 |

tiny 与 Apple Vision 同档，换了等于没换；medium 体积翻 4.5 倍只换 1.9 分。

## 转换链路上的两个坑

**`SAME_UPPER` 自动填充**：onnx2torch 不支持，det/rec 各有 3 个这样的节点。
这些节点全是 `kernel=2×2 / stride=1 / dilation=1`，该配置下 padding 恒为 `[0,0,1,1]`
且与输入尺寸无关，所以能安全改写成显式值。脚本会断言 stride/dilation 全为 1，
换模型后若不满足会直接报错而不是悄悄算错。

**输入形状必须固定**：`torch.jit.trace` 会把形状烘进图里，Core ML 的 `EnumeratedShapes`
因此失效（预测时报 `Error in dynamically resizing for sequence length`）。
所以检测固定 960×960（letterbox 补边），识别固定 48×640（窄行右侧补零、超宽行压缩）。
固定形状同时也是神经引擎的前提——动态形状会退回 CPU/GPU。
