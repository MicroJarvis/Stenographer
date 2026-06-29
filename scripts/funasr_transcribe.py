#!/usr/bin/env python3
import argparse
import json
import os
import sys
import uuid
from pathlib import Path


def fail(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def normalize_result(result):
    if isinstance(result, list) and result:
        first = result[0]
    elif isinstance(result, dict):
        first = result
    else:
        first = {}

    text = first.get("text") if isinstance(first, dict) else ""
    return (text or "").strip()


def normalize_onnx_result(result):
    if isinstance(result, list) and result:
        first = result[0]
    elif isinstance(result, dict):
        first = result
    else:
        first = {}

    if not isinstance(first, dict):
        return ""
    return (first.get("preds") or first.get("text") or "").strip()


def resolve_model_dir(model: str) -> str:
    if os.path.exists(model):
        return model
    cached_dir = os.path.expanduser(os.path.join("~", ".cache", "modelscope", "hub", "models", model))
    if os.path.exists(cached_dir):
        return cached_dir
    return model


def has_offline_onnx(model_dir: str, quantize: bool) -> bool:
    filename = "model_quant.onnx" if quantize else "model.onnx"
    return os.path.exists(os.path.join(model_dir, filename))


def resolve_quantize(model_dir: str, mode: str) -> bool:
    if mode == "quantized":
        return True
    if mode == "non-quantized":
        return False
    return not has_offline_onnx(model_dir, quantize=False)


def transcribe_with_onnx(audio_path: Path, model_name: str, quantize: bool = True) -> str:
    try:
        from funasr_onnx import Paraformer
    except Exception:
        fail("本机还没有安装 funasr-onnx/onnxruntime。请先安装 funasr-onnx 和 onnxruntime。")

    try:
        model = Paraformer(model_dir=model_name, device_id="-1", intra_op_num_threads=4, quantize=quantize)
        return normalize_onnx_result(model(str(audio_path)))
    except Exception as exc:
        fail(f"FunASR ONNX 转写失败：{exc}")


def transcribe_with_torch(audio_path: Path, model_name: str) -> str:
    try:
        from funasr import AutoModel
    except Exception:
        fail("本机还没有安装 FunASR。请先安装 funasr/modelscope/torchaudio，并准备本地模型后再转写。")

    try:
        model = AutoModel(model=model_name)
        result = model.generate(input=str(audio_path))
        return normalize_result(result)
    except Exception as exc:
        fail(f"FunASR Torch 转写失败：{exc}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe a Stenographer recording with local FunASR.")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--backend", choices=["onnx", "torch"], default="onnx")
    parser.add_argument("--model", default=os.environ.get("FUNASR_ONNX_MODEL", "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-onnx"))
    parser.add_argument("--quantization", choices=["auto", "quantized", "non-quantized"], default=os.environ.get("FUNASR_ONNX_QUANTIZATION", "auto"))
    parser.add_argument("--non-quantized", action="store_true", help="Use model.onnx instead of model_quant.onnx for ONNX backend.")
    args = parser.parse_args()

    audio_path = Path(args.audio)
    output_path = Path(args.output)
    if not audio_path.exists():
        fail(f"录音文件不存在：{audio_path}")

    if args.backend == "onnx":
        model_dir = resolve_model_dir(args.model)
        quantize = False if args.non_quantized else resolve_quantize(model_dir, args.quantization)
        if args.quantization == "non-quantized" and not has_offline_onnx(model_dir, quantize=False):
            fail(f"非量化 FunASR ONNX 模型不存在：{model_dir}")
        if args.quantization == "quantized" and not has_offline_onnx(model_dir, quantize=True):
            fail(f"量化 FunASR ONNX 模型不存在：{model_dir}")
        text = transcribe_with_onnx(audio_path, model_dir, quantize=quantize)
    else:
        text = transcribe_with_torch(audio_path, args.model)

    entries = []
    if text:
        entries.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "time": "00:00:00",
                "speakerID": str(uuid.UUID(int=0)).upper(),
                "sourceLanguage": "中文",
                "original": text,
                "translation": text,
                "confidence": "--",
            }
        )

    output_path.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
