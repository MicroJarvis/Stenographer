#!/usr/bin/env python3
import argparse
import json
import math
import os
import sqlite3
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import numpy as np


PROJECT_ROOT = Path(
    os.environ.get(
        "STENOGRAPHER_PROJECT_ROOT",
        os.environ.get("VOICETRANSFORM_PROJECT_ROOT", Path(__file__).resolve().parents[1]),
    )
)


def fail(message: str, code: int = 2) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


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


def load_memory(path: Path) -> list[dict]:
    sqlite_path = path
    if path.suffix.lower() != ".sqlite":
        candidate = path.with_name("speaker_voiceprints.sqlite")
        if candidate.exists():
            sqlite_path = candidate
    if sqlite_path.suffix.lower() == ".sqlite" and sqlite_path.exists():
        records = load_memory_from_sqlite(sqlite_path)
        if records:
            return records

    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, dict) and isinstance(item.get("embedding"), list)]


def load_memory_from_sqlite(path: Path) -> list[dict]:
    try:
        with sqlite3.connect(path) as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS voiceprints (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    voiceprint TEXT NOT NULL,
                    role TEXT NOT NULL,
                    confidence TEXT NOT NULL,
                    embedding_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            rows = conn.execute(
                """
                SELECT id, name, voiceprint, role, confidence, embedding_json, updated_at
                FROM voiceprints
                ORDER BY updated_at DESC
                """
            ).fetchall()
    except Exception:
        return []

    records = []
    for row in rows:
        try:
            embedding = json.loads(row[5])
        except Exception:
            continue
        if not isinstance(embedding, list):
            continue
        records.append(
            {
                "id": row[0],
                "name": row[1],
                "voiceprint": row[2],
                "role": row[3],
                "confidence": row[4],
                "embedding": embedding,
                "updatedAt": row[6],
            }
        )
    return records


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom <= 0:
        return 0.0
    return float(np.dot(a, b) / denom)


def best_match(center: np.ndarray, memory: list[dict]) -> tuple[dict | None, float]:
    best_record = None
    best_score = -1.0
    for record in memory:
        emb = np.asarray(record.get("embedding") or [], dtype=np.float32)
        if emb.size != center.size:
            continue
        score = cosine(center, emb)
        if score > best_score:
            best_record = record
            best_score = score
    return best_record, best_score


def speaker_record(source_spk: int, embedding: list[float], memory: list[dict], threshold: float) -> dict:
    center = np.asarray(embedding, dtype=np.float32)
    matched, score = best_match(center, memory)
    if matched is not None and score >= threshold:
        return {
            "id": matched.get("id") or str(uuid.uuid4()).upper(),
            "name": matched.get("name") or "未命名声纹",
            "voiceprint": matched.get("voiceprint") or f"VP-CAM-{source_spk + 1:02d}",
            "role": matched.get("role") or "已记忆声纹",
            "confidence": f"{max(0, min(99, round(score * 100)))}%",
            "embedding": embedding,
            "sourceSpk": source_spk,
            "similarity": score,
        }

    return {
        "id": str(uuid.uuid4()).upper(),
        "name": "未命名声纹",
        "voiceprint": f"VP-CAM-{source_spk + 1:02d}",
        "role": "待确认",
        "confidence": "--",
        "embedding": embedding,
        "sourceSpk": source_spk,
        "similarity": None,
    }


def time_string(milliseconds: int) -> str:
    seconds = max(0, int(round(milliseconds / 1000)))
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    seconds = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def normalize_sentence(text: str) -> str:
    text = (text or "").strip()
    if " " in text:
        text = text.replace(" ", "")
    return text


def make_transcript(sentence_info: list[dict], speaker_by_spk: dict[int, dict]) -> list[dict]:
    entries = []
    for sentence in sentence_info:
        text = normalize_sentence(sentence.get("sentence", ""))
        if not text:
            continue
        start = int(sentence.get("start") or 0)
        spk = int(sentence.get("spk") or 0)
        speaker = speaker_by_spk.get(spk)
        entries.append(
            {
                "id": str(uuid.uuid4()).upper(),
                "time": time_string(start),
                "startMS": start,
                "endMS": int(sentence.get("end") or start),
                "speakerID": speaker["id"] if speaker else str(uuid.UUID(int=0)).upper(),
                "sourceLanguage": "中文",
                "original": text,
                "translation": text,
                "confidence": "cam++",
            }
        )
    return entries


def run_diarization(wav_path: Path, batch_size_s: int, model=None) -> dict:
    if model is None:
        try:
            from funasr import AutoModel
        except Exception:
            fail("本机还没有安装 FunASR。请先安装 funasr/modelscope/torch。")

        model = AutoModel(
            model="paraformer-zh",
            vad_model="fsmn-vad",
            punc_model="ct-punc",
            spk_model="cam++",
            spk_mode="vad_segment",
            device="cpu",
            disable_update=True,
        )
    result = model.generate(
        input=str(wav_path),
        batch_size_s=batch_size_s,
        return_spk_res=True,
        return_spk_center=True,
    )
    if not result:
        return {}
    return result[0]


def main() -> int:
    parser = argparse.ArgumentParser(description="Run FunASR CAM++ speaker diarization for Stenographer.")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--library", required=True)
    parser.add_argument("--threshold", type=float, default=0.72)
    parser.add_argument("--batch-size-s", type=int, default=60)
    args = parser.parse_args()

    audio_path = Path(args.audio)
    output_path = Path(args.output)
    library_path = Path(args.library)
    if not audio_path.exists():
        fail(f"录音文件不存在：{audio_path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    memory = load_memory(library_path)

    with tempfile.TemporaryDirectory(prefix="voicetransform-spk-") as tmpdir:
        wav_path = Path(tmpdir) / "audio.wav"
        convert_to_wav(audio_path, wav_path)
        result = run_diarization(wav_path, args.batch_size_s)

    centers = result.get("spk_embedding_center")
    if centers is None:
        centers = []
    centers = np.asarray(centers, dtype=np.float32)
    if centers.ndim == 1 and centers.size:
        centers = centers.reshape(1, -1)

    speakers = []
    for index, center in enumerate(centers):
        speakers.append(
            speaker_record(
                source_spk=index,
                embedding=[float(x) for x in center.tolist()],
                memory=memory,
                threshold=args.threshold,
            )
        )
    speaker_by_spk = {int(speaker["sourceSpk"]): speaker for speaker in speakers}

    segments = []
    for sentence in result.get("sentence_info") or []:
        spk = int(sentence.get("spk") or 0)
        speaker = speaker_by_spk.get(spk)
        segments.append(
            {
                "startMS": int(sentence.get("start") or 0),
                "endMS": int(sentence.get("end") or 0),
                "sourceSpk": spk,
                "speakerID": speaker["id"] if speaker else str(uuid.UUID(int=0)).upper(),
                "text": normalize_sentence(sentence.get("sentence", "")),
            }
        )

    output = {
        "speakers": speakers,
        "segments": segments,
        "transcript": make_transcript(result.get("sentence_info") or [], speaker_by_spk),
    }
    output_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
