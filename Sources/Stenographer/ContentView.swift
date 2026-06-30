import SwiftUI

struct ContentView: View {
    @StateObject private var store = MeetingStore()
    @State private var selectedDetail: DetailTab = .speakers
    @State private var speakerPanelScope: SpeakerPanelScope = .meeting
    @State private var searchText = ""
    @State private var acceptsRecordingCommands = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                searchText: $searchText,
                openVoiceprintLibrary: {
                    selectedDetail = .speakers
                    speakerPanelScope = .library
                }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let message = store.lastErrorMessage {
                    ErrorBanner(message: message) {
                        store.lastErrorMessage = nil
                    }
                }

                HSplitView {
                    TranscriptWorkspace(store: store) {
                        selectedDetail = .speakers
                        speakerPanelScope = .meeting
                    }
                    .frame(minWidth: 620)

                    InspectorView(
                        store: store,
                        selectedDetail: $selectedDetail,
                        speakerScope: $speakerPanelScope
                    )
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 430)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.togglePauseSelectedMeeting()
                    } label: {
                        Label(store.pauseButtonTitle, systemImage: store.pauseButtonIcon)
                    }
                    .disabled(!store.canPauseSelectedMeeting)

                    Button(role: .destructive) {
                        store.endSelectedRecording()
                    } label: {
                        Label("结束录音", systemImage: "stop.fill")
                    }
                    .disabled(!store.canEndSelectedMeeting)

                    Divider()

                    Button {
                        store.summarizeSelectedMeeting()
                        selectedDetail = .summary
                    } label: {
                        Label("自动整理", systemImage: "text.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canSummarizeSelectedMeeting)
                }
            }
        }
        .onReceive(tick) { _ in
            store.refreshLiveRecordingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startNewRecording)) { _ in
            guard acceptsRecordingCommands else { return }
            store.startNewRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .summarizeCurrentMeeting)) { _ in
            store.summarizeSelectedMeeting()
            selectedDetail = .summary
        }
        .onChange(of: selectedDetail) { _, detail in
            guard detail == .summary else { return }
            store.summarizeSelectedMeetingIfNeeded()
        }
        .onChange(of: store.selectedMeetingID) { _, _ in
            guard selectedDetail == .summary else { return }
            store.summarizeSelectedMeetingIfNeeded()
        }
        .task {
            acceptsRecordingCommands = true
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case speakers = "说话人"
    case summary = "整理"
    case settings = "引擎"

    var id: String { rawValue }
}

enum SpeakerPanelScope: String, CaseIterable, Identifiable {
    case meeting = "当前会议"
    case library = "全部声纹库"

    var id: String { rawValue }
}

struct SidebarView: View {
    @ObservedObject var store: MeetingStore
    @Binding var searchText: String
    var openVoiceprintLibrary: () -> Void
    @State private var meetingPendingDeletion: Meeting?

    var body: some View {
        List(selection: $store.selectedMeetingID) {
            Section {
                Button {
                    store.startNewRecording()
                } label: {
                    Label("新建实时录音", systemImage: "mic.circle.fill")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)

                Label("所有会议", systemImage: "tray.full")
                Button {
                    openVoiceprintLibrary()
                } label: {
                    Label("声纹库", systemImage: "person.wave.2")
                }
                .buttonStyle(.borderless)
                Label("模型与本地文件", systemImage: "externaldrive")
            }

            Section("最近会议") {
                ForEach(store.filteredMeetings(matching: searchText)) { meeting in
                    MeetingRow(
                        meeting: meeting,
                        deleteAction: {
                            meetingPendingDeletion = meeting
                        }
                    )
                        .tag(meeting.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                meetingPendingDeletion = meeting
                            } label: {
                                Label("删除会议", systemImage: "trash")
                            }
                            .disabled(meeting.status == .live || meeting.status == .paused)
                        }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索会议、发言人或关键词")
        .navigationTitle("Stenographer")
        .alert("删除会议？", isPresented: deleteAlertIsPresented, presenting: meetingPendingDeletion) { meeting in
            Button("删除", role: .destructive) {
                store.deleteMeeting(meeting.id)
                meetingPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                meetingPendingDeletion = nil
            }
        } message: { meeting in
            Text("这会删除“\(meeting.title)”及其本地录音、转写和整理结果。")
        }
    }

    private var deleteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { meetingPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    meetingPendingDeletion = nil
                }
            }
        )
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    var deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    StatusDot(status: meeting.status)
                }

                Text(meeting.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(meeting.duration, systemImage: "clock")
                    Label("\(meeting.speakerCount) 人", systemImage: "person.2")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                deleteAction()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("删除会议")
            .disabled(meeting.status == .live || meeting.status == .paused)
        }
        .padding(.vertical, 6)
    }
}

struct StatusDot: View {
    let status: MeetingStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(status.tint, .secondary)
                .font(.caption)
            Text(status.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct TranscriptWorkspace: View {
    @ObservedObject var store: MeetingStore
    var openSpeakers: () -> Void
    @AppStorage("Stenographer.LiveDraftExpanded") private var isLiveDraftExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            RecordingHeader(store: store)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            LiveDraftStrip(
                draft: store.selectedMeetingLiveDraftEntry,
                speaker: store.selectedMeetingLiveDraftEntry.map { store.speaker(for: $0.speakerID) },
                isStreaming: store.streamingTranscriber.isRunning || store.qwenRefiner.isRunning || store.speakerDiarizer.isLiveRunning,
                isExpanded: $isLiveDraftExpanded
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                if store.selectedMeetingDisplayEntries.isEmpty {
                    ContentUnavailableView(
                        "还没有正文",
                        systemImage: "text.badge.checkmark",
                        description: Text(emptyTranscriptDescription)
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .padding(.horizontal, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.selectedMeetingDisplayEntries) { entry in
                            TranscriptEntryRow(
                                entry: entry,
                                speaker: store.speaker(for: entry.speakerID),
                                openSpeakers: openSpeakers,
                                beginSpeakerMerge: { speakerID in
                                    store.beginSpeakerMerge(sourceID: speakerID)
                                    openSpeakers()
                                }
                            )
                            Divider()
                                .padding(.leading, 120)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
            .background(.background)
        }
    }

    private var emptyTranscriptDescription: String {
        if store.transcriber.isRunning {
            return "FunASR ONNX 正在刷新实时转写。"
        }
        if store.selectedMeeting?.status == .live {
            return "FunASR ONNX 流式模型正在接收麦克风分片。"
        }
        return "还没有可用转写。请确认本机已安装 FunASR 和模型。"
    }
}

struct LiveDraftStrip: View {
    let draft: TranscriptEntry?
    let speaker: Speaker?
    let isStreaming: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("实时草稿", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Text(isStreaming ? "直播中" : "等待输入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? "收起实时草稿" : "展开实时草稿")
            }

            if isExpanded, let draft {
                HStack(alignment: .top, spacing: 18) {
                    Text(draft.time)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SpeakerBadge(speaker: speaker ?? Speaker(
                                id: draft.speakerID,
                                name: "直播草稿",
                                voiceprint: "LIVE",
                                role: "实时输入",
                                tint: .accentColor,
                                confidence: "--"
                            ))
                            Text("FunASR streaming")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }

                        Text(draft.original)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, 12)
            } else if isExpanded {
                ContentUnavailableView(
                    "暂无实时草稿",
                    systemImage: "text.quote",
                    description: Text("录音开始后，实时转写会固定显示在这里。")
                )
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 2)
    }
}

struct RecordingHeader: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selectedMeeting?.title ?? "未选择会议")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("本机麦克风 · 自动语言检测 · 实时翻译为中文")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Label(store.selectedMeeting?.status.rawValue ?? "空闲", systemImage: store.selectedMeeting?.status.systemImage ?? "circle")
                        .foregroundStyle(store.selectedMeeting?.status.tint ?? .secondary)
                        .font(.headline)
                    Text(store.selectedMeeting?.duration ?? "00:00:00")
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        store.translateSelectedMeeting()
                    } label: {
                        Label("翻译待处理", systemImage: "character.book.closed")
                    }
                    .controlSize(.small)
                    .disabled(!store.canTranslateSelectedMeeting)
                    .help(store.canTranslateSelectedMeeting ? "将待翻译外语片段翻译成中文" : "当前会议没有待翻译片段")
                }
            }

            HStack(spacing: 10) {
                EnginePill(title: "录音", value: store.selectedMeeting?.status == .live ? "写入中" : "已保存", systemImage: "record.circle", tint: .red)
                EnginePill(title: "实时字幕", value: store.transcriptionStatusText, systemImage: "waveform", tint: store.streamingTranscriber.isRunning ? .blue : .secondary)
                EnginePill(title: "正文增强", value: enhancementStatus, systemImage: "wand.and.sparkles", tint: store.qwenRefiner.isRunning ? .blue : (store.selectedMeetingHasEnhancedEntries ? .green : .orange))
                EnginePill(
                    title: "说话人",
                    value: (store.speakerDiarizer.isRunning || store.speakerDiarizer.isLiveRunning) ? "匹配中" : "\(store.selectedMeeting?.speakerCount ?? 0) 个轨道",
                    systemImage: "person.wave.2",
                    tint: (store.speakerDiarizer.isRunning || store.speakerDiarizer.isLiveRunning) ? .blue : .purple
                )
                EnginePill(title: "中文翻译", value: "自动", systemImage: "character.book.closed", tint: .green)
            }

            WaveformView(
                isActive: store.selectedMeeting?.status == .live,
                inputLevel: store.recorder.level
            )
                .frame(height: 42)
        }
    }

    private var enhancementStatus: String {
        if store.qwenRefiner.isRunning {
            return "后台增强中"
        }
        if store.selectedMeetingHasEnhancedEntries {
            return "已写入正文"
        }
        return "等待片段"
    }
}

struct EnginePill: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                Text(value)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

struct WaveformView: View {
    let isActive: Bool
    let inputLevel: Double
    private let levels: [Double] = [0.22, 0.48, 0.72, 0.36, 0.64, 0.88, 0.42, 0.54, 0.3, 0.76, 0.96, 0.58, 0.34, 0.62, 0.8, 0.45, 0.28, 0.52, 0.7, 0.4, 0.66, 0.84, 0.5, 0.32, 0.74, 0.92, 0.46, 0.6, 0.38, 0.68, 0.86, 0.44]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 4) {
                ForEach(levels.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(index: index))
                        .frame(width: max(3, proxy.size.width / CGFloat(levels.count) - 4), height: barHeight(proxy: proxy, index: index))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("实时录音波形")
    }

    private func barColor(index: Int) -> Color {
        guard isActive else { return .secondary.opacity(0.22) }
        return index > 25 ? .secondary.opacity(0.28) : .accentColor.opacity(0.72)
    }

    private func barHeight(proxy: GeometryProxy, index: Int) -> CGFloat {
        let base = levels[index]
        let liveBoost = isActive ? max(inputLevel, 0.08) : 0
        let modulated = min(1, base * 0.45 + liveBoost * (0.65 + Double(index % 5) * 0.06))
        return max(5, proxy.size.height * modulated)
    }
}

struct TranscriptEntryRow: View {
    let entry: TranscriptEntry
    let speaker: Speaker
    var openSpeakers: () -> Void
    var beginSpeakerMerge: (Speaker.ID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(entry.time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        speakerHeader
                        statusTags
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        speakerHeader
                        statusTags
                    }
                }

                Text(entry.original)
                    .font(.body)
                    .textSelection(.enabled)

                if entry.sourceLanguage != "中文" {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.translation)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 1)
                }

                if speaker.isUnnamed {
                    HStack {
                        Button("命名声纹") {
                            openSpeakers()
                        }
                        Button("合并到已有说话人") {
                            beginSpeakerMerge(speaker.id)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 14)
        }
    }

    private var speakerHeader: some View {
        SpeakerBadge(speaker: speaker)
    }

    private var statusTags: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusTagViews
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TranscriptStatusTag(title: entry.sourceLanguage, systemImage: "globe.asia.australia", tint: .secondary)
                    TranscriptStatusTag(
                        title: transcriptionStatus.title,
                        systemImage: transcriptionStatus.systemImage,
                        tint: transcriptionStatus.tint
                    )
                }
                HStack(spacing: 8) {
                    TranscriptStatusTag(
                        title: translationStatus.title,
                        systemImage: translationStatus.systemImage,
                        tint: translationStatus.tint
                    )
                    TranscriptStatusTag(
                        title: speakerStatus.title,
                        systemImage: speakerStatus.systemImage,
                        tint: speakerStatus.tint
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var statusTagViews: some View {
        TranscriptStatusTag(title: entry.sourceLanguage, systemImage: "globe.asia.australia", tint: .secondary)
        TranscriptStatusTag(
            title: transcriptionStatus.title,
            systemImage: transcriptionStatus.systemImage,
            tint: transcriptionStatus.tint
        )
        TranscriptStatusTag(
            title: translationStatus.title,
            systemImage: translationStatus.systemImage,
            tint: translationStatus.tint
        )
        TranscriptStatusTag(
            title: speakerStatus.title,
            systemImage: speakerStatus.systemImage,
            tint: speakerStatus.tint
        )
    }

    private var transcriptionStatus: TranscriptRowStatus {
        if entry.confidence.hasPrefix("qwen3-asr") {
            return TranscriptRowStatus(title: "Qwen 已增强", systemImage: "wand.and.sparkles", tint: .blue)
        }
        if entry.confidence.hasPrefix("whisper-large") {
            return TranscriptRowStatus(title: "Whisper 补全", systemImage: "waveform.badge.magnifyingglass", tint: .purple)
        }
        if entry.confidence == "nano-gguf" {
            return TranscriptRowStatus(title: "Nano GGUF", systemImage: "waveform.badge.magnifyingglass", tint: .purple)
        }
        if entry.confidence == "merged" {
            return TranscriptRowStatus(title: "已合并正文", systemImage: "arrow.triangle.merge", tint: .secondary)
        }
        if entry.confidence == "stream" || entry.confidence == "final" {
            return TranscriptRowStatus(title: "实时草稿", systemImage: "dot.radiowaves.left.and.right", tint: .orange)
        }
        return TranscriptRowStatus(title: "已转写", systemImage: "text.badge.checkmark", tint: .secondary)
    }

    private var translationStatus: TranscriptRowStatus {
        guard entry.sourceLanguage != "中文" else {
            return TranscriptRowStatus(title: "中文正文", systemImage: "character.cursor.ibeam", tint: .secondary)
        }

        let translation = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translation.isEmpty && translation != original {
            return TranscriptRowStatus(title: "已翻译", systemImage: "character.book.closed", tint: .green)
        }
        return TranscriptRowStatus(title: "待翻译", systemImage: "character.book.closed", tint: .orange)
    }

    private var speakerStatus: TranscriptRowStatus {
        if speaker.isUnnamed {
            return TranscriptRowStatus(title: "声纹待确认", systemImage: "person.crop.circle.badge.questionmark", tint: .orange)
        }
        return TranscriptRowStatus(title: "声纹已回填", systemImage: "person.wave.2", tint: .purple)
    }
}

struct SpeakerBadge: View {
    let speaker: Speaker

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(speaker.tint)
                .frame(width: 8, height: 8)
            Text(speaker.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

struct TranscriptRowStatus {
    var title: String
    var systemImage: String
    var tint: Color
}

struct TranscriptStatusTag: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .help(title)
    }
}

struct InspectorView: View {
    @ObservedObject var store: MeetingStore
    @Binding var selectedDetail: DetailTab
    @Binding var speakerScope: SpeakerPanelScope

    var body: some View {
        VStack(spacing: 0) {
            Picker("详情", selection: $selectedDetail) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedDetail {
                    case .speakers:
                        SpeakersPanel(store: store, scope: $speakerScope)
                    case .summary:
                        SummaryPanel(store: store)
                    case .settings:
                        EnginePanel(store: store)
                    }
                }
                .padding(16)
            }
        }
        .background(.thinMaterial)
    }
}

struct SpeakersPanel: View {
    @ObservedObject var store: MeetingStore
    @Binding var scope: SpeakerPanelScope

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: panelTitle, subtitle: panelSubtitle)

            Picker("声纹范围", selection: $scope) {
                ForEach(SpeakerPanelScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button {
                    store.analyzeSpeakersForSelectedMeeting()
                } label: {
                    Label("分析声纹", systemImage: "person.wave.2")
                }
                .disabled(!store.canAnalyzeSpeakersSelectedMeeting)

                if store.speakerDiarizer.isRunning || store.speakerDiarizer.isLiveRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.speakerDiarizer.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            SpeakerMergePanel(store: store)

            if hasVisibleSpeakers {
                ForEach($store.speakers) { $speaker in
                    if shouldShow(speaker) {
                        SpeakerMemoryRow(
                            speaker: $speaker,
                            usageStats: store.speakerUsageStats(for: speaker.id),
                            memoryLabel: store.speakerMemoryLabel(for: speaker.id),
                            canMerge: store.speakers.count > 1,
                            onCommit: { name in
                                store.updateSpeakerName(
                                    speaker.id,
                                    name: name,
                                    remember: scope == .library ? true : store.rememberNamedVoice
                                )
                            },
                            onMerge: { speakerID in
                                scope = .library
                                store.beginSpeakerMerge(sourceID: speakerID)
                            }
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    scope == .meeting ? "当前会议还没有声纹" : "声纹库为空",
                    systemImage: "person.wave.2",
                    description: Text(scope == .meeting ? "录音中或分析声纹后，这里会显示本场会议的说话人。" : "命名过的本地声纹会显示在这里。")
                )
                .frame(maxWidth: .infinity, minHeight: 130)
            }

            if scope == .meeting {
                Divider()

                Form {
                    TextField("新声纹名称", text: $store.pendingVoiceName)
                    Picker("语言偏好", selection: $store.preferredLanguage) {
                        Text("自动检测").tag("自动检测")
                        Text("中文").tag("中文")
                        Text("English").tag("English")
                        Text("日本語").tag("日本語")
                    }
                    Toggle("下次自动显示姓名", isOn: $store.rememberNamedVoice)
                }
                .formStyle(.grouped)

                Button {
                    store.savePendingVoiceName()
                } label: {
                    Label("保存声纹命名", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.unnamedSpeaker == nil)
            }
        }
    }

    private var panelTitle: String {
        scope == .library ? "声纹库" : "说话人审核"
    }

    private var panelSubtitle: String {
        switch scope {
        case .meeting:
            return "核对本场声纹、命名未知说话人并合并重复身份"
        case .library:
            return "管理本机保存的说话人名称，并将重复声纹合并到同一身份"
        }
    }

    private var hasVisibleSpeakers: Bool {
        store.speakers.contains { shouldShow($0) }
    }

    private func shouldShow(_ speaker: Speaker) -> Bool {
        switch scope {
        case .meeting:
            return store.selectedMeetingSpeakerIDs.contains(speaker.id)
        case .library:
            return true
        }
    }
}

struct SpeakerMergePanel: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        if let source = store.pendingSpeakerMergeSource {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("合并声纹", systemImage: "person.2.badge.gearshape")
                            .font(.headline)
                        Spacer()
                        Button("取消") {
                            store.cancelSpeakerMerge()
                        }
                        .controlSize(.small)
                    }

                    Text("将 \(source.displayName) 合并到已有说话人。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let candidates = store.speakerMergeTargetCandidates
                    if candidates.isEmpty {
                        Text("还没有可合并的目标说话人。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("目标说话人", selection: mergeTargetBinding(fallback: candidates[0].id)) {
                            ForEach(candidates) { speaker in
                                Text(speaker.displayName).tag(speaker.id)
                            }
                        }

                        Button {
                            store.mergePendingSpeaker()
                        } label: {
                            Label("确认合并", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.pendingSpeakerMergeTargetID == nil)
                    }
                }
            }
        }
    }

    private func mergeTargetBinding(fallback: Speaker.ID) -> Binding<Speaker.ID> {
        Binding(
            get: {
                store.pendingSpeakerMergeTargetID ?? fallback
            },
            set: { newValue in
                store.pendingSpeakerMergeTargetID = newValue
            }
        )
    }
}

struct SpeakerMemoryRow: View {
    @Binding var speaker: Speaker
    var usageStats: SpeakerUsageStats
    var memoryLabel: String
    var canMerge: Bool
    var onCommit: (String) -> Void
    var onMerge: (Speaker.ID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(speaker.tint)
                .frame(width: 12, height: 12)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                TextField("声纹名称", text: $speaker.name)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onSubmit {
                        onCommit(speaker.name)
                    }
                    .onChange(of: speaker.name) { _, newValue in
                        onCommit(newValue)
                    }

                speakerMetaTags

                Label(usageStats.summary, systemImage: usageStats.isInCurrentMeeting ? "clock.badge.checkmark" : "clock")
                    .font(.caption)
                    .foregroundStyle(usageStats.isInCurrentMeeting ? .secondary : .tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("匹配 \(speaker.confidence)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    onMerge(speaker.id)
                } label: {
                    Label("合并", systemImage: "arrow.triangle.merge")
                }
                .controlSize(.small)
                .disabled(!canMerge)
            }
        }
        .padding(.vertical, 6)
    }

    private var memoryIcon: String {
        memoryLabel == "已记忆" ? "checkmark.seal" : "person.badge.clock"
    }

    private var memoryTint: Color {
        memoryLabel == "已记忆" ? .green : .orange
    }

    private var speakerMetaTags: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                speakerStateTagViews
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SpeakerStateTag(title: memoryLabel, systemImage: memoryIcon, tint: memoryTint)
                    SpeakerStateTag(title: speaker.role, systemImage: "person.text.rectangle", tint: .secondary)
                }
                SpeakerStateTag(title: speaker.voiceprint, systemImage: "waveform.path", tint: .secondary)
            }
        }
    }

    @ViewBuilder
    private var speakerStateTagViews: some View {
        SpeakerStateTag(title: memoryLabel, systemImage: memoryIcon, tint: memoryTint)
        SpeakerStateTag(title: speaker.role, systemImage: "person.text.rectangle", tint: .secondary)
        SpeakerStateTag(title: speaker.voiceprint, systemImage: "waveform.path", tint: .secondary)
    }
}

struct SpeakerStateTag: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .help(title)
    }
}

struct SummaryPanel: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "自动整理预览", subtitle: "录音结束后使用 OpenAI 模型生成会议纪要")

            if store.selectedMeetingSummary.isEmpty {
                ContentUnavailableView(
                    "还没有会议纪要",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(store.canSummarizeSelectedMeeting ? "点击下方按钮生成整理结果。" : "先结束录音，再启动自动整理。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(store.selectedMeetingSummary) { point in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(point.speaker)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(point.title)
                            .font(.headline)
                        Text(point.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 5)
                }

                Divider()
            }

            Button {
                store.summarizeSelectedMeeting()
            } label: {
                Label("使用 OpenAI 生成纪要", systemImage: "sparkles")
            }
            .disabled(!store.canSummarizeSelectedMeeting)
        }
    }
}

struct EnginePanel: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "本地推理状态", subtitle: "FunASR 负责实时字幕，Qwen3-ASR 作为正文主增强")

            ForEach(store.engineItems()) { item in
                EngineStatusRow(name: item.name, detail: item.detail, status: item.status, tint: item.tint)
            }

            Divider()

            OpenAISettingsPanel(service: store.openAISummary)

            Divider()

            Form {
                LabeledContent("音频输入", value: "MacBook Pro 麦克风")
                LabeledContent("采样率", value: "16 kHz")
                LabeledContent("会议目录", value: store.selectedMeetingStoragePath ?? "尚未创建")
                LabeledContent("录音文件", value: store.selectedMeetingAudioPath ?? "尚未写入")
                LabeledContent("ASR 后端", value: "ONNXRuntime")
                LabeledContent("FunASR 模型", value: "speech_paraformer-large…online-onnx")
                LabeledContent("Nano GGUF", value: store.nanoGGUF.modelDetail)
                LabeledContent("二遍增强", value: store.qwenRefiner.modelName)
                LabeledContent("Qwen Python", value: store.qwenRefiner.pythonPath)
                LabeledContent("llama-cli", value: store.llama.executablePath ?? "未找到")
                LabeledContent("GGUF 模型", value: store.llama.modelPath ?? "设置 LLAMA_MODEL 或放到 Models/llm")
                LabeledContent("上下文窗口", value: "8K tokens")
            }
            .formStyle(.grouped)

            Button {
                store.runNanoGGUFOnSelectedMeeting()
            } label: {
                Label("试跑 Nano GGUF", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(!store.canRunNanoGGUFSelectedMeeting)

            Button {
                store.analyzeSpeakersForSelectedMeeting()
            } label: {
                Label("分析声纹", systemImage: "person.wave.2")
            }
            .disabled(!store.canAnalyzeSpeakersSelectedMeeting)

            Button {
                store.translateSelectedMeeting()
            } label: {
                Label("翻译当前会议", systemImage: "character.book.closed")
            }
            .disabled(!store.canTranslateSelectedMeeting)
        }
    }
}

struct OpenAISettingsPanel: View {
    @ObservedObject var service: OpenAISummaryService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("OpenAI 整理", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text(service.statusText)
                    .font(.caption)
                    .foregroundStyle(service.isConfigured ? Color.secondary : Color.orange)
            }

            Form {
                TextField("Base URL", text: $service.baseURL)
                    .textContentType(.URL)
                SecureField("API Key", text: $service.apiKeyDraft)
                    .textContentType(.password)
                TextField("模型", text: $service.modelName)
            }
            .formStyle(.grouped)

            Button {
                service.saveSettings()
            } label: {
                Label("保存 OpenAI 设置", systemImage: "key")
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct EngineStatusRow: View {
    let name: String
    let detail: String
    let status: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PanelHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
