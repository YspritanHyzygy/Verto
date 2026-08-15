#!/usr/bin/env python3
#
#  Copyright 2026 Yspritan
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
"""把 PP-OCRv6 官方 ONNX 转成 app 用的 Core ML 模型包，三档各一个。

每档产出一个 Apple Archive（.aar），内含：
    VertoTextDetector.mlpackage/     DB 文字检测，输入固定 1×3×960×960
    VertoTextRecognizer.mlpackage/   CTC 文字识别，输入固定 1×3×48×640
    charset.txt                      字符表，逐行（tiny 6904 条、其余 18708 条）
另在产物根目录写一份 manifest.json，含各档体积与 SHA-256。

为什么不直接用官方 ONNX：那要往 app 里链进 ONNX Runtime（25MB+ 的 C++ 运行时），
IPA 直接变大。转成 Core ML 后 IPA 一个字节都不增加，还能上神经引擎，
且 fp16 让下载体积减半。代价是转换链路长，所以本脚本每步都自带数值核对：
auto_pad 改写必须逐位相同，fp16 转换的误差必须在阈值内，否则直接失败。

为什么打成 .aar 而不是 .zip：iOS 没有公开的解 zip API，
而 AppleArchive 是系统 Swift 模块（iOS 14+），app 侧因此不需要任何三方库。

依赖（必须 Python 3.12，coremltools/onnx2torch 没有 3.13+ 的 wheel）：
    uv venv --python 3.12 .venv && source .venv/bin/activate
    uv pip install -r requirements.txt

用法：
    python build_models.py --out ../../build/ocr-models
    python build_models.py --out ... --tier small      # 只建一档
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import yaml
from onnx import helper
from onnx2torch import convert as onnx2torch_convert

import coremltools as ct

# ── 模型选型 ────────────────────────────────────────────────────────────────
# PP-OCRv6 只有 tiny / small / medium 三档，三档全部构建，由用户在设置里选。
# 准确率取自 PaddleOCR 官方 16 类真实照片基准的加权平均（W-Avg）。
TIERS = {
    "tiny":   {"accuracy": 73.5},
    "small":  {"accuracy": 81.3},
    "medium": {"accuracy": 83.2},
}
PACK_VERSION = "1"

# 检测输入固定 960×960（letterbox）。Core ML 的动态形状会退出神经引擎，
# 固定形状换来 ANE 加速；浪费掉的那点算力在几十毫秒的量级上无所谓。
DET_SIZE = 960
# 识别输入固定 48×640，即 13.3:1。单行文字极少超过这个长宽比，
# 更宽的行按比例压缩进来，更窄的右侧补零（与官方 padding 行为一致）。
REC_HEIGHT, REC_WIDTH = 48, 640

# 检测预处理用 ImageNet 均值方差，识别用 (x-0.5)/0.5，均照搬 PaddleOCR 官方配置。
DET_MEAN, DET_STD = [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]
REC_MEAN, REC_STD = [0.5, 0.5, 0.5], [0.5, 0.5, 0.5]

# 转换后与原 ONNX 的最大绝对误差上限。fp16 有效位约 3 位十进制，
# 检测输出是 0~1 概率图（判据阈值 0.3），识别输出是 logits（只看 argmax）。
DET_TOLERANCE = 0.01
REC_TOLERANCE = 0.20


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(repo: str, dest: Path) -> Path:
    from huggingface_hub import snapshot_download
    print(f"  下载 {repo}")
    snapshot_download(repo, local_dir=str(dest))
    return dest


def rewrite_auto_pad(src: Path, dst: Path) -> int:
    """把 SAME_UPPER 自动填充改写成显式 pads。

    onnx2torch 不支持 SAME_UPPER，而 det/rec 各有 3 个这样的节点。
    它们全是 kernel=2×2 / stride=1 / dilation=1，此配置下
        pad_total = (out-1)*stride + (kernel-1)*dilation + 1 - in = kernel-1 = 1
    与输入尺寸无关，SAME_UPPER 把多的 1 放末端 → pads=[0,0,1,1]。
    所以改写后对任意输入尺寸都等价，不会把模型钉死在某个分辨率。
    stride/dilation 不全为 1 时 padding 依赖输入尺寸，此时直接报错而不是算错。
    """
    model = onnx.load(str(src))
    changed = 0
    for node in model.graph.node:
        attrs = {a.name: a for a in node.attribute}
        auto_pad = attrs.get("auto_pad")
        if auto_pad is None or auto_pad.s.decode() != "SAME_UPPER":
            continue
        kernel = list(attrs["kernel_shape"].ints)
        strides = list(attrs["strides"].ints) if "strides" in attrs else [1] * len(kernel)
        dilations = list(attrs["dilations"].ints) if "dilations" in attrs else [1] * len(kernel)
        if any(s != 1 for s in strides) or any(d != 1 for d in dilations):
            raise SystemExit(
                f"{node.op_type}: stride={strides} dilation={dilations} 不全为 1，"
                "SAME_UPPER 的 padding 此时依赖输入尺寸，不能按固定值改写"
            )
        begin = [(k - 1) // 2 for k in kernel]
        end = [(k - 1) - b for k, b in zip(kernel, begin)]
        node.attribute.remove(auto_pad)
        if "pads" in attrs:
            node.attribute.remove(attrs["pads"])
        node.attribute.append(helper.make_attribute("pads", begin + end))
        changed += 1
    onnx.checker.check_model(model)
    onnx.save(model, str(dst))
    return changed


def assert_rewrite_is_exact(original: Path, rewritten: Path, shape) -> None:
    """改写只是把隐式 padding 写成显式，必须逐位相同，不允许有任何误差。"""
    x = np.random.default_rng(0).random(shape).astype(np.float32)
    def run(p):
        return ort.InferenceSession(str(p), providers=["CPUExecutionProvider"]).run(None, {"x": x})[0]
    delta = np.abs(run(original) - run(rewritten)).max()
    if delta != 0:
        raise SystemExit(f"auto_pad 改写改变了输出（最大误差 {delta}），拒绝继续")
    print(f"     auto_pad 改写核对：逐位相同")


def to_coreml(onnx_path: Path, out: Path, shape, tolerance: float, label: str):
    torch_model = onnx2torch_convert(onnx.load(str(onnx_path)))
    torch_model.eval()
    traced = torch.jit.trace(torch_model, torch.rand(*shape), strict=False)
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="x", shape=shape, dtype=np.float32)],
        # 必须显式钉死输出为 float32。不写这一项时 coremltools 会跟随
        # compute_precision 把输出也标成 float16，而 app 侧按 float32 读那块缓冲
        # 会越界读两倍长度、直接崩进程（实测踩过）。权重仍是 fp16，
        # 体积不受影响，只有输出张量按 float32 交付。
        outputs=[ct.TensorType(dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    model.save(str(out))

    spec = model.get_spec().description
    for feature in list(spec.input) + list(spec.output):
        kind = feature.type.multiArrayType.dataType
        if kind != 65568:  # 65568 = FLOAT32，65552 = FLOAT16
            raise SystemExit(f"{label}: {feature.name} 的数据类型是 {kind}，不是 FLOAT32")

    x = np.random.default_rng(1).random(shape).astype(np.float32)
    ref = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"]).run(None, {"x": x})[0]
    got = list(ct.models.MLModel(str(out)).predict({"x": x}).values())[0]
    if ref.shape != got.shape:
        raise SystemExit(f"{label}: 形状不一致 onnx{ref.shape} vs coreml{got.shape}")
    delta = float(np.abs(ref - got).max())
    print(f"     {label} 转换核对：最大绝对误差 {delta:.5f}（上限 {tolerance}）")
    if delta > tolerance:
        raise SystemExit(f"{label}: fp16 误差 {delta} 超出上限 {tolerance}")
    return delta


def build_tier(tier: str, work: Path, out_root: Path) -> dict:
    det_repo = f"PaddlePaddle/PP-OCRv6_{tier}_det_onnx"
    rec_repo = f"PaddlePaddle/PP-OCRv6_{tier}_rec_onnx"
    out = out_root / tier
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    print(f"\n=== {tier} ===")
    print("  [1/5] 取官方 ONNX")
    det_dir = fetch(det_repo, work / tier / "det")
    rec_dir = fetch(rec_repo, work / tier / "rec")

    print("  [2/5] 改写 SAME_UPPER 自动填充")
    for tag, d, shape in [("det", det_dir, (1, 3, DET_SIZE, DET_SIZE)),
                          ("rec", rec_dir, (1, 3, REC_HEIGHT, REC_WIDTH))]:
        src, dst = d / "inference.onnx", d / "inference_fixed.onnx"
        n = rewrite_auto_pad(src, dst)
        print(f"     {tag}: 改写 {n} 个节点")
        assert_rewrite_is_exact(src, dst, shape)

    print("  [3/5] 转 Core ML (fp16)")
    det_err = to_coreml(det_dir / "inference_fixed.onnx", out / "VertoTextDetector.mlpackage",
                        (1, 3, DET_SIZE, DET_SIZE), DET_TOLERANCE, "det")
    rec_err = to_coreml(rec_dir / "inference_fixed.onnx", out / "VertoTextRecognizer.mlpackage",
                        (1, 3, REC_HEIGHT, REC_WIDTH), REC_TOLERANCE, "rec")

    print("  [4/5] 导出字符表")
    charset = yaml.safe_load((rec_dir / "inference.yml").read_text())["PostProcess"]["character_dict"]
    # 原样逐行写，一个字符都不许清洗：字表里有一条是全角空格 U+3000，
    # 任何 strip 都会把它变成空串，从而让其后所有字符的索引整体错位一位。
    if any("\n" in c for c in charset):
        raise SystemExit("字表条目含换行，逐行格式会错位")
    (out / "charset.txt").write_text("\n".join(charset) + "\n", encoding="utf-8")
    print(f"     {len(charset)} 条字符")

    print("  [5/5] 打包")
    # 打成 Apple Archive 而不是 zip：iOS 没有公开的解 zip API，
    # 而 AppleArchive 是系统 Swift 模块（iOS 14+），app 侧不需要任何三方库。
    # lzfse 体积与 zlib 基本持平但解压快得多。
    archive = out_root / f"verto-ocr-{tier}-v{PACK_VERSION}.aar"
    archive.unlink(missing_ok=True)
    subprocess.run(
        ["aa", "archive", "-d", str(out), "-o", str(archive), "-a", "lzfse", "-b", "1m"],
        check=True,
    )
    size = archive.stat().st_size
    print(f"     {archive.name}  {size / 1048576:.1f} MB")

    return {
        "tier": tier,
        "accuracy": TIERS[tier]["accuracy"],
        "source": {"detector": det_repo, "recognizer": rec_repo},
        "charactersCount": len(charset),
        "conversionMaxError": {"detector": det_err, "recognizer": rec_err},
        "archive": {"name": archive.name, "bytes": size, "sha256": sha256(archive)},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path, help="产物目录")
    ap.add_argument("--work", type=Path, default=Path("build"), help="中间文件目录")
    ap.add_argument("--tier", action="append", choices=sorted(TIERS),
                    help="只构建指定档位，可重复；默认三档全建")
    args = ap.parse_args()

    work, out_root = args.work.resolve(), args.out.resolve()
    work.mkdir(parents=True, exist_ok=True)
    out_root.mkdir(parents=True, exist_ok=True)

    packs = [build_tier(t, work, out_root) for t in (args.tier or ["tiny", "small", "medium"])]

    manifest = {
        "version": PACK_VERSION,
        # 三档共用同一套前后处理超参，app 侧只有模型文件不同。
        "detector": {"inputWidth": DET_SIZE, "inputHeight": DET_SIZE,
                     "mean": DET_MEAN, "std": DET_STD},
        "recognizer": {"inputWidth": REC_WIDTH, "inputHeight": REC_HEIGHT,
                       "mean": REC_MEAN, "std": REC_STD},
        "packs": packs,
    }
    (out_root / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("\n完成：")
    for p in packs:
        print(f"  {p['tier']:<7} {p['archive']['bytes']/1048576:6.1f} MB  "
              f"准确率 {p['accuracy']}  sha256 {p['archive']['sha256'][:16]}…")


if __name__ == "__main__":
    main()
