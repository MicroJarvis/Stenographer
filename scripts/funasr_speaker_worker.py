#!/usr/bin/env python3
import argparse
import contextlib
import json
import sys
import types
import uuid
from pathlib import Path

import numpy as np

from funasr_speaker_diarize import (
    load_memory,
    make_transcript,
    normalize_sentence,
    run_diarization,
    speaker_record,
)


JSON_STDOUT = sys.stdout


def event(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), file=JSON_STDOUT, flush=True)


def patch_short_cluster(model, distance_threshold: float) -> None:
    try:
        from sklearn.cluster import AgglomerativeClustering
    except Exception:
        return

    cluster_backend = getattr(model, "cb_model", None)
    if cluster_backend is None:
        return

    original_forward = cluster_backend.forward

    def forward(self, x, **params):
        sample_count = int(x.shape[0])
        oracle_num = params.get("oracle_num")
        if 4 <= sample_count < 20:
            embeddings = x.detach().cpu().numpy() if hasattr(x, "detach") else np.asarray(x)
            if oracle_num is not None and 1 < int(oracle_num) <= sample_count:
                labels = AgglomerativeClustering(
                    n_clusters=int(oracle_num),
                    metric="cosine",
                    linkage="average",
                ).fit_predict(embeddings)
            else:
                labels = AgglomerativeClustering(
                    n_clusters=None,
                    distance_threshold=distance_threshold,
                    metric="cosine",
                    linkage="average",
                ).fit_predict(embeddings)
            labels = np.asarray(labels, dtype="int")
            if labels.max() + 1 > 1 and "merge_thr" in self.model_config:
                labels = self.merge_by_cos(labels, embeddings, self.model_config["merge_thr"])
            return labels

        return original_forward(x, **params)

    cluster_backend.forward = types.MethodType(forward, cluster_backend)


def result_from_funasr(
    result: dict,
    offset_ms: int,
    memory: list[dict],
    threshold: float,
    session_memory: list[dict],
) -> dict:
    centers = result.get("spk_embedding_center")
    if centers is None:
        centers = []
    centers = np.asarray(centers, dtype=np.float32)
    if centers.ndim == 1 and centers.size:
        centers = centers.reshape(1, -1)

    speakers_by_id = {}
    for index, center in enumerate(centers):
        active_memory = memory + session_memory
        speaker = speaker_record(
            source_spk=index,
            embedding=[float(x) for x in center.tolist()],
            memory=active_memory,
            threshold=threshold,
        )
        speakers_by_id[speaker["id"]] = speaker
        upsert_session_memory(session_memory, speaker)
    speakers = list(speakers_by_id.values())
    speaker_by_spk = {int(speaker["sourceSpk"]): speaker for speaker in speakers}

    shifted_sentence_info = []
    segments = []
    for sentence in result.get("sentence_info") or []:
        shifted = dict(sentence)
        shifted["start"] = int(sentence.get("start") or 0) + offset_ms
        shifted["end"] = int(sentence.get("end") or 0) + offset_ms
        shifted_sentence_info.append(shifted)

        spk = int(sentence.get("spk") or 0)
        speaker = speaker_by_spk.get(spk)
        segments.append(
            {
                "startMS": shifted["start"],
                "endMS": shifted["end"],
                "sourceSpk": spk,
                "speakerID": speaker["id"] if speaker else str(uuid.UUID(int=0)).upper(),
                "text": normalize_sentence(sentence.get("sentence", "")),
            }
        )

    return {
        "speakers": speakers,
        "segments": segments,
        "transcript": make_transcript(shifted_sentence_info, speaker_by_spk),
    }


def upsert_session_memory(records: list[dict], speaker: dict) -> None:
    embedding = speaker.get("embedding") or []
    if not embedding:
        return

    record = {
        "id": speaker.get("id"),
        "name": speaker.get("name") or "未命名声纹",
        "voiceprint": speaker.get("voiceprint") or "VP-CAM",
        "role": speaker.get("role") or "待确认",
        "confidence": speaker.get("confidence") or "--",
        "embedding": embedding,
    }

    for index, existing in enumerate(records):
        if existing.get("id") != record["id"]:
            continue
        old = np.asarray(existing.get("embedding") or [], dtype=np.float32)
        new = np.asarray(embedding, dtype=np.float32)
        if old.size == new.size and old.size > 0:
            blended = old * 0.7 + new * 0.3
            record["embedding"] = [float(x) for x in blended.tolist()]
        records[index] = record
        return

    records.append(record)


def main() -> int:
    parser = argparse.ArgumentParser(description="Persistent FunASR CAM++ live diarization worker.")
    parser.add_argument("--library", required=True)
    parser.add_argument("--threshold", type=float, default=0.72)
    parser.add_argument("--batch-size-s", type=int, default=60)
    parser.add_argument("--short-cluster-distance", type=float, default=0.30)
    args = parser.parse_args()

    try:
        from funasr import AutoModel
    except Exception:
        event({"type": "fatal", "message": "本机还没有安装 FunASR。"})
        return 2

    try:
        with contextlib.redirect_stdout(sys.stderr):
            model = AutoModel(
                model="paraformer-zh",
                vad_model="fsmn-vad",
                punc_model="ct-punc",
                spk_model="cam++",
                spk_mode="vad_segment",
                device="cpu",
                disable_update=True,
            )
        patch_short_cluster(model, args.short_cluster_distance)
    except Exception as exc:
        event({"type": "fatal", "message": f"FunASR CAM++ 加载失败：{exc}"})
        return 2

    event({"type": "ready"})
    session_memory = []

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            command = json.loads(line)
        except Exception:
            event({"type": "error", "message": "声纹 worker 收到无效 JSON。"})
            continue

        command_type = command.get("type")
        if command_type == "stop":
            event({"type": "stopped"})
            return 0
        if command_type != "analyze":
            continue

        command_id = command.get("id") or str(uuid.uuid4()).upper()
        audio_path = Path(command.get("audio") or "")
        offset_ms = int(command.get("offsetMS") or 0)
        if not audio_path.exists():
            event({"type": "error", "id": command_id, "message": f"窗口音频不存在：{audio_path}"})
            continue

        try:
            memory = load_memory(Path(args.library))
            with contextlib.redirect_stdout(sys.stderr):
                result = run_diarization(audio_path, args.batch_size_s, model=model)
            payload = result_from_funasr(result, offset_ms, memory, args.threshold, session_memory)
            event({"type": "result", "id": command_id, **payload})
        except Exception as exc:
            event({"type": "error", "id": command_id, "message": f"实时声纹分析失败：{exc}"})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
