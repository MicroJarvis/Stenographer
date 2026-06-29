# Stenographer

Stenographer 是一个 macOS 原生风格的语音会议记录工具原型。

当前版本是 macOS SwiftUI 本地原型，用来确认界面结构和核心交互：

- 打开后呈现实时录音状态、会议时长和本地模型状态。
- 会议列表可以切换，也可以新建一场实时录音。
- 新建实时录音会请求麦克风权限，并把音频写入本地会议目录。
- 暂停、继续、结束录音和自动整理会更新本地界面状态，并写入 JSON 快照。
- 中央区域展示真实转写结果；不会展示模拟转写。
- 录音时会启动 `scripts/funasr_stream.py`，使用 FunASR online ONNX + ONNXRuntime 做流式识别。
- 右侧检查器展示声纹记忆、会后整理预览和本地推理引擎状态。
- 未命名声纹可以在右侧保存姓名，并回写到转写时间线。
- 后续真实能力预留给 FunASR、声纹库、llama.cpp 和 Codex 整理流程。

录音文件与会议快照默认保存在：

```text
~/Library/Application Support/Stenographer/Meetings/<会议ID>/
```

运行开发版：

```bash
swift run Stenographer
```

打包并生成可双击打开的 `.app`：

```bash
scripts/package_app.sh
open Stenographer.app
```

构建验证：

```bash
swift build
```

FunASR ONNX 依赖检查：

```bash
python3 - <<'PY'
import importlib.util
for name in ["funasr_onnx", "onnxruntime", "modelscope"]:
    print(name, bool(importlib.util.find_spec(name)))
PY
```

本地推理边界：

- FunASR 负责语音识别，运行时默认使用 ONNXRuntime。
- `llama.cpp` 负责文字后的推理任务，例如纠错、翻译成中文、会议摘要和按发言人整理观点。
- App 会自动查找 `/opt/homebrew/bin/llama-cli`，GGUF 模型可通过 `LLAMA_MODEL=/path/to/model.gguf` 配置，或放到 `Models/llm/`。
