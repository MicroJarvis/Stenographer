#!/usr/bin/env python3
import argparse
import json
import os
import sys
import uuid
from pathlib import Path


def emit(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def parse_dtype(name: str):
    import torch

    normalized = (name or "").strip().lower()
    if normalized in ("bf16", "bfloat16"):
        return torch.bfloat16
    if normalized in ("fp16", "float16", "half"):
        return torch.float16
    if normalized in ("fp32", "float32"):
        return torch.float32
    raise ValueError(f"不支持的 Qwen3-ASR dtype：{name}")


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


def load_model(args):
    from qwen_asr import Qwen3ASRModel

    device = choose_device(args.device)
    dtype = parse_dtype(args.dtype)
    try:
        model = Qwen3ASRModel.from_pretrained(
            args.model,
            dtype=dtype,
            device_map=device,
            max_inference_batch_size=max(1, args.batch_size),
            max_new_tokens=args.max_new_tokens,
        )
        return model, device
    except Exception as exc:
        if device == "cpu" and args.dtype == "float32":
            raise
        print(f"Qwen3-ASR 首次加载失败，改用 CPU/float32 重试：{exc}", file=sys.stderr)
        model = Qwen3ASRModel.from_pretrained(
            args.model,
            dtype=parse_dtype("float32"),
            device_map="cpu",
            max_inference_batch_size=max(1, min(args.batch_size, 2)),
            max_new_tokens=args.max_new_tokens,
        )
        return model, "cpu"


def transcribe_segment(model, command, default_language: str, default_context: str):
    audio_path = Path(command["audio"])
    if not audio_path.exists():
        raise FileNotFoundError(f"音频分段不存在：{audio_path}")

    language = normalize_language(command.get("language") or default_language)
    context = command.get("context") or default_context
    results = model.transcribe(audio=str(audio_path), context=context, language=language)

    text = ""
    detected_language = ""
    if results:
        first = results[0]
        text = (getattr(first, "text", "") or "").strip()
        detected_language = (getattr(first, "language", "") or "").strip()

    entries = []
    if text:
        app_language = language_for_app(detected_language or language or "")
        entries.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "time": command.get("time", "00:00:00"),
                "startMS": int(command.get("startMS") or 0),
                "endMS": int(command.get("endMS") or command.get("startMS") or 0),
                "speakerID": str(uuid.UUID(int=0)).upper(),
                "sourceLanguage": app_language,
                "original": text,
                "translation": text,
                "confidence": "qwen3-asr-live",
            }
        )
    return entries


def build_parser():
    parser = argparse.ArgumentParser(description="Persistent Qwen3-ASR worker for Stenographer rolling enhancement.")
    parser.add_argument("--model", default=os.environ.get("QWEN_ASR_MODEL", "Qwen/Qwen3-ASR-1.7B"))
    parser.add_argument("--language", default=os.environ.get("QWEN_ASR_LANGUAGE", "auto"))
    parser.add_argument("--device", default=os.environ.get("QWEN_ASR_DEVICE", "auto"))
    parser.add_argument("--dtype", default=os.environ.get("QWEN_ASR_DTYPE", "float32"))
    parser.add_argument("--max-new-tokens", type=int, default=int(os.environ.get("QWEN_ASR_MAX_NEW_TOKENS", "384")))
    parser.add_argument("--batch-size", type=int, default=int(os.environ.get("QWEN_ASR_BATCH_SIZE", "1")))
    parser.add_argument("--context", default=os.environ.get("QWEN_ASR_CONTEXT", ""))
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        model, device = load_model(args)
    except Exception as exc:
        emit({"type": "fatal", "message": f"Qwen3-ASR worker 启动失败：{exc}"})
        return 1

    emit({"type": "ready", "model": args.model, "device": device})

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            command = json.loads(line)
            command_type = command.get("type")
            if command_type == "stop":
                emit({"type": "stopped"})
                return 0
            if command_type != "transcribe":
                emit({"type": "error", "id": command.get("id"), "message": f"未知命令：{command_type}"})
                continue

            entries = transcribe_segment(model, command, args.language, args.context)
            emit({"type": "result", "id": command.get("id"), "entries": entries})
        except Exception as exc:
            emit({"type": "error", "id": command.get("id") if "command" in locals() else None, "message": str(exc)})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
