#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


PROJECT_ROOT = Path(
    os.environ.get(
        "STENOGRAPHER_PROJECT_ROOT",
        os.environ.get("VOICETRANSFORM_PROJECT_ROOT", Path(__file__).resolve().parents[1]),
    )
)
ZERO_SPEAKER_ID = "00000000-0000-0000-0000-000000000000"


def fail(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def default_binary() -> Path:
    return PROJECT_ROOT / "Tools" / "funasr-llamacpp" / "llama-funasr-cli"


def default_encoder() -> Path:
    return PROJECT_ROOT / "Models" / "Fun-ASR-Nano-2512-GGUF" / "funasr-encoder-f16.gguf"


def default_decoder() -> Path:
    model_dir = PROJECT_ROOT / "Models" / "Fun-ASR-Nano-2512-GGUF"
    for name in ("qwen3-0.6b-q8_0.gguf", "qwen3-0.6b-q5km.gguf", "qwen3-0.6b-q4km.gguf"):
        candidate = model_dir / name
        if candidate.exists() and candidate.stat().st_size > 0:
            return candidate
    return model_dir / "qwen3-0.6b-q8_0.gguf"


def default_vad() -> Path:
    return PROJECT_ROOT / "Models" / "fsmn-vad-GGUF" / "fsmn-vad.gguf"


def ensure_file(path: Path, label: str) -> None:
    if not path.exists() or path.stat().st_size == 0:
        fail(f"{label} 不存在或未下载完整：{path}")


def convert_to_wav(audio_path: Path, wav_path: Path) -> None:
    command = [
        "/usr/bin/afconvert",
        "-f",
        "WAVE",
        "-d",
        "LEI16@16000",
        "-c",
        "1",
        str(audio_path),
        str(wav_path),
    ]
    run = subprocess.run(command, text=True, capture_output=True)
    if run.returncode != 0:
        message = (run.stderr or run.stdout or "afconvert 转换 WAV 失败。").strip()
        fail(message)


def extract_transcript(raw_output: str) -> str:
    lines = []
    skip_prefixes = (
        "ggml_",
        "llama_",
        "build:",
        "main:",
        "system_info:",
        "sampler",
        "generate:",
        "[done]",
    )
    for line in raw_output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        lowered = stripped.lower()
        if lowered.startswith(skip_prefixes):
            continue
        if re.match(r"^\[[^\]]+\]\s*$", stripped):
            continue
        if "load time =" in lowered or "eval time =" in lowered or "total time =" in lowered:
            continue
        lines.append(stripped)

    text = "".join(lines).strip()
    text = re.sub(r"\s+", " ", text)
    return text


def run_nano(args: argparse.Namespace, wav_path: Path) -> tuple[str, str]:
    binary = Path(args.binary)
    encoder = Path(args.encoder)
    decoder = Path(args.decoder)
    vad = Path(args.vad) if args.vad else None

    ensure_file(binary, "FunASR llama.cpp 可执行文件")
    ensure_file(encoder, "Fun-ASR-Nano encoder GGUF")
    ensure_file(decoder, "Fun-ASR-Nano decoder GGUF")
    if vad:
        ensure_file(vad, "FSMN VAD GGUF")

    command = [
        str(binary),
        "--enc",
        str(encoder),
        "-m",
        str(decoder),
        "-a",
        str(wav_path),
        "-n",
        str(args.max_tokens),
    ]
    if vad:
        command += ["--vad", str(vad), "--vad-maxseg", str(args.vad_maxseg_ms)]
    else:
        command += ["--chunk", str(args.chunk_seconds)]

    run = subprocess.run(command, text=True, capture_output=True)
    combined = "\n".join(part for part in [run.stdout, run.stderr] if part)
    if run.returncode != 0:
        fail(combined.strip() or "Fun-ASR-Nano GGUF 转写失败。")
    text = extract_transcript(run.stdout)
    if not text:
        text = extract_transcript(combined)
    return text, combined


def write_entries(text: str, output_path: Path) -> None:
    entries = []
    if text:
        entries.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "time": "00:00:00",
                "speakerID": ZERO_SPEAKER_ID,
                "sourceLanguage": "中文",
                "original": text,
                "translation": text,
                "confidence": "nano-gguf",
            }
        )
    output_path.write_text(json.dumps(entries, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe with Fun-ASR-Nano GGUF through FunASR llama.cpp runtime.")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--binary", default=str(default_binary()))
    parser.add_argument("--encoder", default=str(default_encoder()))
    parser.add_argument("--decoder", default=str(default_decoder()))
    parser.add_argument("--vad", default=str(default_vad()))
    parser.add_argument("--chunk-seconds", type=int, default=15)
    parser.add_argument("--vad-maxseg-ms", type=int, default=15000)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--keep-wav", action="store_true")
    args = parser.parse_args()

    audio_path = Path(args.audio)
    output_path = Path(args.output)
    if not audio_path.exists():
        fail(f"录音文件不存在：{audio_path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="voicetransform-nano-") as tmpdir:
        wav_path = output_path.with_suffix(".nano-16k.wav") if args.keep_wav else Path(tmpdir) / "audio.wav"
        convert_to_wav(audio_path, wav_path)
        text, raw_output = run_nano(args, wav_path)
        write_entries(text, output_path)
        if args.keep_wav:
            output_path.with_suffix(".nano-raw.log").write_text(raw_output, encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
