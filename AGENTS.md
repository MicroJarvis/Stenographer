# Stenographer Development Notes

- Keep the app in strict macOS native style: `NavigationSplitView`, toolbar actions, segmented inspectors, grouped forms, system symbols, and standard materials.
- Treat the current three-column layout as the product baseline: meeting list, live transcript workspace, and right-side inspector.
- Avoid web-dashboard styling, decorative cards, hero sections, or marketing layouts.
- Keep model integration seams visible but quiet. Use labels such as FunASR, voiceprint, translation, llama.cpp, and Codex only where they clarify product state.
- Build features as local SwiftUI state first, then replace the state layer with real audio, ASR, speaker, translation, and summarization services.
