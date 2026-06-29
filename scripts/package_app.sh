#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/Stenographer.app"

cd "$ROOT_DIR"
swift build

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/debug/Stenographer" "$APP_DIR/Contents/MacOS/Stenographer"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
mkdir -p "$APP_DIR/Contents/Resources/Scripts"
cp "$ROOT_DIR/scripts/funasr_transcribe.py" "$APP_DIR/Contents/Resources/Scripts/funasr_transcribe.py"
cp "$ROOT_DIR/scripts/funasr_stream.py" "$APP_DIR/Contents/Resources/Scripts/funasr_stream.py"
cp "$ROOT_DIR/scripts/funasr_nano_gguf_transcribe.py" "$APP_DIR/Contents/Resources/Scripts/funasr_nano_gguf_transcribe.py"
cp "$ROOT_DIR/scripts/funasr_speaker_diarize.py" "$APP_DIR/Contents/Resources/Scripts/funasr_speaker_diarize.py"
cp "$ROOT_DIR/scripts/funasr_speaker_worker.py" "$APP_DIR/Contents/Resources/Scripts/funasr_speaker_worker.py"
cp "$ROOT_DIR/scripts/qwen_asr_refine.py" "$APP_DIR/Contents/Resources/Scripts/qwen_asr_refine.py"
cp "$ROOT_DIR/scripts/qwen_asr_worker.py" "$APP_DIR/Contents/Resources/Scripts/qwen_asr_worker.py"
chmod +x "$APP_DIR/Contents/MacOS/Stenographer"
chmod +x "$APP_DIR/Contents/Resources/Scripts/funasr_transcribe.py"
chmod +x "$APP_DIR/Contents/Resources/Scripts/funasr_stream.py"
chmod +x "$APP_DIR/Contents/Resources/Scripts/funasr_nano_gguf_transcribe.py"
chmod +x "$APP_DIR/Contents/Resources/Scripts/funasr_speaker_diarize.py"
chmod +x "$APP_DIR/Contents/Resources/Scripts/funasr_speaker_worker.py"
chmod +x "$APP_DIR/Contents/Resources/Scripts/qwen_asr_refine.py"
chmod +x "$APP_DIR/Contents/Resources/Scripts/qwen_asr_worker.py"
rm -rf "$APP_DIR/Contents/_CodeSignature"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
