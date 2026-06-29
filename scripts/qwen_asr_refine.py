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


def parse_dtype(name: str):
    import torch

    normalized = (name or "").strip().lower()
    if normalized in ("bf16", "bfloat16"):
        return torch.bfloat16
    if normalized in ("fp16", "float16", "half"):
        return torch.float16
    if normalized in ("fp32", "float32"):
        return torch.float32
    fail(f"不支持的 Qwen3-ASR dtype：{name}")


def choose_device(preferred: str) -> str:
    import torch

    normalized = (preferred or "auto").strip().lower()
    if normalized in ("cpu", "mps"):
        return normalized
    if normalized.startswith("cuda"):
        return normalized
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda:0"
    return "cpu"


def load_model(model_name: str, device: str, dtype_name: str, max_new_tokens: int, batch_size: int):
    from qwen_asr import Qwen3ASRModel

    dtype = parse_dtype(dtype_name)
    kwargs = {
        "dtype": dtype,
        "device_map": device,
        "max_inference_batch_size": batch_size,
        "max_new_tokens": max_new_tokens,
    }

    try:
        return Qwen3ASRModel.from_pretrained(model_name, **kwargs)
    except Exception as exc:
        if device == "cpu" and dtype_name == "float32":
            raise
        print(
            f"Qwen3-ASR 首次加载失败，改用 CPU/float32 重试：{exc}",
            file=sys.stderr,
        )
        return Qwen3ASRModel.from_pretrained(
            model_name,
            dtype=parse_dtype("float32"),
            device_map="cpu",
            max_inference_batch_size=max(1, min(batch_size, 2)),
            max_new_tokens=max_new_tokens,
        )


def normalize_language(language: str | None) -> str | None:
    value = (language or "").strip()
    if not value or value.lower() in ("auto", "自动", "自动检测"):
        return None
    aliases = {
        "中文": "Chinese",
        "汉语": "Chinese",
        "普通话": "Chinese",
        "英文": "English",
        "英语": "English",
        "日文": "Japanese",
        "日语": "Japanese",
        "韩文": "Korean",
        "韩语": "Korean",
        "粤语": "Cantonese",
    }
    return aliases.get(value, value[:1].upper() + value[1:].lower())


def language_for_app(language: str) -> str:
    mapping = {
        "Chinese": "中文",
        "English": "English",
        "Japanese": "日本語",
        "Korean": "한국어",
        "Cantonese": "粤语",
    }
    return mapping.get(language or "", language or "自动检测")


def main() -> int:
    parser = argparse.ArgumentParser(description="Enhance a Stenographer recording with local Qwen3-ASR.")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default=os.environ.get("QWEN_ASR_MODEL", "Qwen/Qwen3-ASR-1.7B"))
    parser.add_argument("--language", default=os.environ.get("QWEN_ASR_LANGUAGE", "auto"))
    parser.add_argument("--device", default=os.environ.get("QWEN_ASR_DEVICE", "auto"))
    parser.add_argument("--dtype", default=os.environ.get("QWEN_ASR_DTYPE", "float32"))
    parser.add_argument("--max-new-tokens", type=int, default=int(os.environ.get("QWEN_ASR_MAX_NEW_TOKENS", "1024")))
    parser.add_argument("--batch-size", type=int, default=int(os.environ.get("QWEN_ASR_BATCH_SIZE", "1")))
    parser.add_argument("--context", default=os.environ.get("QWEN_ASR_CONTEXT", ""))
    args = parser.parse_args()

    audio_path = Path(args.audio)
    output_path = Path(args.output)
    if not audio_path.exists():
        fail(f"录音文件不存在：{audio_path}")

    try:
        device = choose_device(args.device)
        model = load_model(
            model_name=args.model,
            device=device,
            dtype_name=args.dtype,
            max_new_tokens=args.max_new_tokens,
            batch_size=max(1, args.batch_size),
        )
        results = model.transcribe(
            audio=str(audio_path),
            context=args.context,
            language=normalize_language(args.language),
        )
    except Exception as exc:
        fail(f"Qwen3-ASR 二遍增强失败：{exc}", code=1)

    text = ""
    detected_language = ""
    if results:
        first = results[0]
        text = (getattr(first, "text", "") or "").strip()
        detected_language = (getattr(first, "language", "") or "").strip()

    entries = []
    if text:
        app_language = language_for_app(detected_language)
        entries.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "time": "00:00:00",
                "speakerID": str(uuid.UUID(int=0)).upper(),
                "sourceLanguage": app_language,
                "original": text,
                "translation": text,
                "confidence": "qwen3-asr",
            }
        )

    output_path.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
