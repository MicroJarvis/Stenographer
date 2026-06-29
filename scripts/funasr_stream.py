#!/usr/bin/env python3
import argparse
import json
import os
import struct
import sys

import numpy as np
from funasr_onnx.paraformer_online_bin import Paraformer


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def normalize_result(result):
    if not result:
        return ""
    text = ""
    for item in result:
        if isinstance(item, dict):
            value = item.get("preds") or item.get("text") or ""
            if isinstance(value, str):
                text += value
            elif isinstance(value, (list, tuple)) and value:
                first = value[0]
                if isinstance(first, str):
                    text += first
    return text.strip()


def resolve_model_dir(model):
    if os.path.exists(model):
        return model

    cached_dir = os.path.expanduser(os.path.join("~", ".cache", "modelscope", "hub", "models", model))
    if os.path.exists(cached_dir):
        return cached_dir

    return model


def has_non_quantized_model(model_dir):
    return (
        os.path.exists(os.path.join(model_dir, "model.onnx"))
        and os.path.exists(os.path.join(model_dir, "decoder.onnx"))
    )


def has_quantized_model(model_dir):
    return (
        os.path.exists(os.path.join(model_dir, "model_quant.onnx"))
        and os.path.exists(os.path.join(model_dir, "decoder_quant.onnx"))
    )


def resolve_quantize(model_dir, mode):
    if mode == "quantized":
        return True
    if mode == "non-quantized":
        return False
    return not has_non_quantized_model(model_dir)


def append_result(model, cache, audio, transcript, is_final):
    if audio.size == 0 and not cache:
        return transcript

    result = model(audio, param_dict={"cache": cache, "is_final": is_final})
    chunk_text = normalize_result(result)
    if chunk_text:
        transcript += chunk_text
        emit({"type": "partial", "text": transcript})
    return transcript


def main():
    parser = argparse.ArgumentParser(description="Streaming FunASR ONNX worker for Stenographer.")
    parser.add_argument("--model", default="iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-online")
    parser.add_argument("--quantization", choices=["auto", "quantized", "non-quantized"], default=os.environ.get("FUNASR_ONNX_QUANTIZATION", "auto"))
    parser.add_argument("--chunk-samples", type=int, default=9600)
    parser.add_argument("--sample-rate", type=int, default=16000)
    args = parser.parse_args()

    model_dir = resolve_model_dir(args.model)
    quantize = resolve_quantize(model_dir, args.quantization)
    if args.quantization == "non-quantized" and not has_non_quantized_model(model_dir):
        raise FileNotFoundError(f"非量化 FunASR ONNX 模型不存在：{model_dir}")
    if args.quantization == "quantized" and not has_quantized_model(model_dir):
        raise FileNotFoundError(f"量化 FunASR ONNX 模型不存在：{model_dir}")

    model = Paraformer(model_dir=model_dir, batch_size=1, chunk_size=[0, 10, 5], device_id="-1", quantize=quantize)
    cache = {}
    transcript = ""
    pending_audio = np.empty((0,), dtype=np.float32)
    emit({"type": "ready", "quantized": quantize, "model": model_dir})

    while True:
        header = sys.stdin.buffer.read(4)
        if not header:
            break
        (byte_count,) = struct.unpack("<I", header)
        if byte_count == 0:
            transcript = append_result(model, cache, pending_audio, transcript, is_final=True)
            emit({"type": "final", "text": transcript})
            break

        payload = sys.stdin.buffer.read(byte_count)
        if len(payload) != byte_count:
            emit({"type": "error", "message": "PCM payload ended unexpectedly."})
            break

        audio = np.frombuffer(payload, dtype=np.float32)
        pending_audio = np.concatenate((pending_audio, audio))
        while pending_audio.size >= args.chunk_samples:
            chunk = pending_audio[: args.chunk_samples]
            pending_audio = pending_audio[args.chunk_samples :]
            transcript = append_result(model, cache, chunk, transcript, is_final=False)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit({"type": "error", "message": str(exc)})
        raise SystemExit(1)
