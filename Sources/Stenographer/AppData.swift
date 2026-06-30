import Foundation
import SwiftUI

struct Meeting: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var subtitle: String
    var createdAt: Date
    var durationSeconds: Int
    var status: MeetingStatus
    var speakerCount: Int
    var storageDirectoryPath: String?
    var audioFilePath: String?

    var duration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        let seconds = durationSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

enum MeetingStatus: String, CaseIterable, Codable {
    case live = "录音中"
    case paused = "已暂停"
    case ready = "已整理"
    case draft = "待整理"

    var tint: Color {
        switch self {
        case .live:
            .red
        case .paused:
            .yellow
        case .ready:
            .green
        case .draft:
            .orange
        }
    }

    var systemImage: String {
        switch self {
        case .live:
            "record.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .ready:
            "checkmark.circle.fill"
        case .draft:
            "clock.badge.questionmark"
        }
    }
}

struct TranscriptEntry: Identifiable, Codable, Sendable {
    let id: UUID
    var time: String
    var startMS: Int?
    var endMS: Int?
    var speakerID: UUID
    var sourceLanguage: String
    var original: String
    var translation: String
    var confidence: String
}

struct Speaker: Identifiable, Hashable {
    let id: UUID
    var name: String
    var voiceprint: String
    var role: String
    var tint: Color
    var confidence: String

    var isUnnamed: Bool {
        name.isUnnamedVoiceName
    }

    var displayName: String {
        if name.placeholderSpeakerNumber != nil {
            return name
        }
        return isUnnamed ? "\(name) \(voiceprint)" : name
    }
}

struct SummaryPoint: Identifiable, Codable {
    let id: UUID
    var speaker: String
    var title: String
    var detail: String
}

struct EngineItem: Identifiable {
    let id = UUID()
    var name: String
    var detail: String
    var status: String
    var tint: Color
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published var meetings: [Meeting]
    @Published var selectedMeetingID: Meeting.ID?
    @Published var speakers: [Speaker]
    @Published var transcriptByMeeting: [Meeting.ID: [TranscriptEntry]]
    @Published var summaryByMeeting: [Meeting.ID: [SummaryPoint]]
    @Published var pendingVoiceName = "山田健"
    @Published var pendingSpeakerMergeSourceID: Speaker.ID?
    @Published var pendingSpeakerMergeTargetID: Speaker.ID?
    @Published var preferredLanguage = "自动检测"
    @Published var rememberNamedVoice = true
    @Published var recorder = AudioRecorderService()
    @Published var transcriber = TranscriptionService()
    @Published var streamingTranscriber = StreamingTranscriptionService()
    @Published var qwenRefiner = QwenASRRefinementService()
    @Published var whisperLarge = WhisperCppService()
    @Published var nanoGGUF = FunASRNanoGGUFService()
    @Published var openAISummary = OpenAISummaryService()
    @Published var speakerDiarizer = SpeakerDiarizationService()
    @Published var llama = LlamaCppService()
    @Published var lastErrorMessage: String?

    private var liveSampleCursor = 0
    private var lastLiveTranscriptionSecond = 0
    private let liveTranscriptionIntervalSeconds = 5
    @Published private(set) var liveStreamingEntryByMeeting: [Meeting.ID: TranscriptEntry] = [:]
    private var qwenLiveEntriesByMeeting: [Meeting.ID: [UUID: [TranscriptEntry]]] = [:]
    private var whisperLiveEntriesByMeeting: [Meeting.ID: [UUID: [TranscriptEntry]]] = [:]
    private var liveSpeakerEntriesByMeeting: [Meeting.ID: [UUID: [TranscriptEntry]]] = [:]
    private var speakerEmbeddingByID: [Speaker.ID: [Double]] = [:]
    private var rememberedVoiceprintIDs = Set<Speaker.ID>()
    private var placeholderSpeakerIDsByMeeting: [Meeting.ID: Speaker.ID] = [:]
    private let speakerTrackManager = SpeakerTrackManager()

    init(seed: SampleSeed = .default) {
        let storedSnapshots = MeetingFileStore.shared.loadSnapshots()
        if storedSnapshots.isEmpty {
            meetings = seed.meetings
            speakers = seed.speakers
            transcriptByMeeting = seed.transcriptByMeeting
            summaryByMeeting = seed.summaryByMeeting
            selectedMeetingID = seed.meetings.first?.id
        } else {
            meetings = storedSnapshots.map(\.meeting) + seed.meetings
            speakers = Self.mergeSpeakers(seed.speakers, with: storedSnapshots.flatMap(\.speakers))
            transcriptByMeeting = seed.transcriptByMeeting
            summaryByMeeting = seed.summaryByMeeting
            for snapshot in storedSnapshots {
                transcriptByMeeting[snapshot.meeting.id] = snapshot.transcript
                summaryByMeeting[snapshot.meeting.id] = snapshot.summary
            }
            selectedMeetingID = storedSnapshots.first?.meeting.id
        }
        loadVoiceprintLibrary()
    }

    var selectedMeeting: Meeting? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    var selectedMeetingEntries: [TranscriptEntry] {
        guard let selectedMeetingID else { return [] }
        return transcriptByMeeting[selectedMeetingID, default: []]
    }

    var selectedMeetingLiveDraftEntry: TranscriptEntry? {
        guard let selectedMeetingID else { return nil }
        return liveStreamingEntryByMeeting[selectedMeetingID]
    }

    var selectedMeetingDisplayEntries: [TranscriptEntry] {
        selectedMeetingEntries.groupedForDisplay()
    }

    var selectedMeetingSummary: [SummaryPoint] {
        guard let selectedMeetingID else { return [] }
        return summaryByMeeting[selectedMeetingID, default: []]
    }

    var selectedMeetingSpeakerIDs: Set<Speaker.ID> {
        guard let selectedMeetingID else { return [] }
        return meetingSpeakerIDs(for: selectedMeetingID)
    }

    var pauseButtonTitle: String {
        selectedMeeting?.status == .paused ? "继续" : "暂停"
    }

    var pauseButtonIcon: String {
        selectedMeeting?.status == .paused ? "play.fill" : "pause.fill"
    }

    var canPauseSelectedMeeting: Bool {
        guard let status = selectedMeeting?.status else { return false }
        return status == .live || status == .paused
    }

    var canEndSelectedMeeting: Bool {
        guard let status = selectedMeeting?.status else { return false }
        return status == .live || status == .paused
    }

    var canSummarizeSelectedMeeting: Bool {
        guard let selectedMeeting else { return false }
        return (selectedMeeting.status == .draft || selectedMeeting.status == .ready)
            && !selectedMeetingEntries.isEmpty
            && !openAISummary.isRunning
    }

    var canRunNanoGGUFSelectedMeeting: Bool {
        guard let selectedMeeting, selectedMeeting.audioFilePath != nil else { return false }
        return selectedMeeting.status != .live && !nanoGGUF.isRunning
    }

    var canAnalyzeSpeakersSelectedMeeting: Bool {
        guard let selectedMeeting, selectedMeeting.audioFilePath != nil else { return false }
        return selectedMeeting.status != .live && !speakerDiarizer.isRunning
    }

    var transcriptionStatusText: String {
        if streamingTranscriber.isRunning {
            return "流式识别中"
        }
        if transcriber.isRunning {
            return "转写中"
        }
        if selectedMeetingEntries.isEmpty {
            return "等待 FunASR"
        }
        return "已转写"
    }

    var unnamedSpeaker: Speaker? {
        let currentSpeakerIDs = selectedMeetingSpeakerIDs
        guard !currentSpeakerIDs.isEmpty else { return nil }
        return speakers.first { speaker in
            speaker.isUnnamed && currentSpeakerIDs.contains(speaker.id)
        }
    }

    var pendingSpeakerMergeSource: Speaker? {
        guard let pendingSpeakerMergeSourceID else { return nil }
        return speakers.first { $0.id == pendingSpeakerMergeSourceID }
    }

    var speakerMergeTargetCandidates: [Speaker] {
        guard let pendingSpeakerMergeSourceID else { return [] }
        let currentSpeakerIDs = selectedMeetingSpeakerIDs
        return speakers
            .filter { $0.id != pendingSpeakerMergeSourceID }
            .sorted { lhs, rhs in
                let lhsInMeeting = currentSpeakerIDs.contains(lhs.id)
                let rhsInMeeting = currentSpeakerIDs.contains(rhs.id)
                if lhsInMeeting != rhsInMeeting {
                    return lhsInMeeting && !rhsInMeeting
                }
                if lhs.isUnnamed != rhs.isUnnamed {
                    return !lhs.isUnnamed && rhs.isUnnamed
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func filteredMeetings(matching searchText: String) -> [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }

        return meetings.filter { meeting in
            let entries = transcriptByMeeting[meeting.id, default: []]
            let speakerNames = entries.map { speaker(for: $0.speakerID).displayName }
            let haystack = ([meeting.title, meeting.subtitle] + speakerNames + entries.map(\.original) + entries.map(\.translation))
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedMeetingStoragePath: String? {
        selectedMeeting?.storageDirectoryPath
    }

    var selectedMeetingAudioPath: String? {
        selectedMeeting?.audioFilePath
    }

    func selectedMeetingLiveSpeakerIDs() -> Set<Speaker.ID> {
        guard let selectedMeetingID else { return [] }
        return meetingSpeakerIDs(for: selectedMeetingID)
    }

    func startNewRecording() {
        let newMeeting = Meeting(
            id: UUID(),
            title: "新的实时录音",
            subtitle: "刚刚 · 本机麦克风",
            createdAt: Date(),
            durationSeconds: 0,
            status: .live,
            speakerCount: 1,
            storageDirectoryPath: nil,
            audioFilePath: nil
        )

        meetings.insert(newMeeting, at: 0)
        selectedMeetingID = newMeeting.id
        transcriptByMeeting[newMeeting.id] = []
        summaryByMeeting[newMeeting.id] = []
        liveStreamingEntryByMeeting[newMeeting.id] = nil
        qwenLiveEntriesByMeeting[newMeeting.id] = [:]
        whisperLiveEntriesByMeeting[newMeeting.id] = [:]
        liveSpeakerEntriesByMeeting[newMeeting.id] = [:]
        placeholderSpeakerIDsByMeeting[newMeeting.id] = nil
        let defaultSpeaker = ensurePlaceholderSpeaker(for: newMeeting.id, index: 1)
        placeholderSpeakerIDsByMeeting[newMeeting.id] = defaultSpeaker.id
        speakerTrackManager.reset(
            rememberedSpeakers: speakers.filter { rememberedVoiceprintIDs.contains($0.id) },
            embeddingsByID: speakerEmbeddingByID
        )
        speakerTrackManager.reserveTemporarySpeaker(defaultSpeaker)
        lastErrorMessage = nil
        lastLiveTranscriptionSecond = 0
        qwenRefiner.reset()
        whisperLarge.reset()

        Task { [weak self] in
            await self?.startRecorder(for: newMeeting.id, title: newMeeting.title)
        }
    }

    func togglePauseSelectedMeeting() {
        guard let status = selectedMeeting?.status else { return }

        updateSelectedMeeting { meeting in
            switch meeting.status {
            case .live:
                meeting.status = .paused
                meeting.subtitle = "已暂停 · 音频写入已停止"
            case .paused:
                meeting.status = .live
                meeting.subtitle = "正在录音 · 本机麦克风"
            case .ready, .draft:
                break
            }
        }

        do {
            if status == .live {
                recorder.pauseRecording()
            } else if status == .paused {
                try recorder.resumeRecording()
            }
            persistSelectedMeetingSnapshot()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

    }

    func endSelectedRecording() {
        guard selectedMeetingID != nil else { return }
        updateSelectedMeeting { meeting in
            if meeting.status == .live || meeting.status == .paused {
                meeting.status = .draft
                meeting.subtitle = "刚刚结束 · Qwen3-ASR 收尾增强，Whisper large 补漏"
            }
        }
        recorder.stopRecording()
        streamingTranscriber.finish()
        qwenRefiner.finishLiveEnhancement()
        whisperLarge.finishLiveTranscription()
        speakerDiarizer.finishLiveDiarization()
        persistSelectedMeetingSnapshot()
        if let selectedMeetingID {
            analyzeSpeakers(for: selectedMeetingID)
        }
    }

    func summarizeSelectedMeeting() {
        guard let selectedMeetingID, let meeting = selectedMeeting else { return }
        guard !selectedMeetingEntries.isEmpty else {
            lastErrorMessage = "还没有真实转写内容，无法生成会议纪要。请先完成 FunASR 转写。"
            return
        }
        let entries = preferredEntriesForSummary()
        let speakerNames = speakerNamesByID(for: entries)
        updateSelectedMeeting { meeting in
            meeting.subtitle = "正在使用 OpenAI 整理会议"
        }
        persistSelectedMeetingSnapshot()

        Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await openAISummary.summarize(
                    meeting: meeting,
                    entries: entries,
                    speakerNames: speakerNames
                )
                summaryByMeeting[selectedMeetingID] = summary
                updateSelectedMeeting { meeting in
                    meeting.status = .ready
                    meeting.subtitle = "刚刚 · OpenAI 已生成会议纪要"
                }
                persistSelectedMeetingSnapshot()
            } catch {
                updateSelectedMeeting { meeting in
                    if meeting.status == .ready {
                        meeting.status = .draft
                    }
                    meeting.subtitle = "整理失败 · 请检查 OpenAI 设置"
                }
                persistSelectedMeetingSnapshot()
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func summarizeSelectedMeetingIfNeeded() {
        guard selectedMeetingSummary.isEmpty else { return }
        if canSummarizeSelectedMeeting {
            summarizeSelectedMeeting()
            return
        }
        if selectedMeeting?.status == .live || selectedMeeting?.status == .paused {
            lastErrorMessage = "请先结束录音，再整理会议。"
        } else if selectedMeetingEntries.isEmpty {
            lastErrorMessage = "还没有真实转写内容，无法生成会议纪要。"
        }
    }

    func runNanoGGUFOnSelectedMeeting() {
        guard let selectedMeetingID,
              let audioPath = selectedMeeting?.audioFilePath,
              let directoryPath = selectedMeeting?.storageDirectoryPath else { return }
        let outputPath = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("nano_gguf_transcript.json")
            .path

        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await nanoGGUF.transcribe(audioPath: audioPath, outputPath: outputPath)
                transcriptByMeeting[selectedMeetingID] = normalizeTranscript(entries, meetingID: selectedMeetingID)
                updateSelectedMeeting { meeting in
                    meeting.speakerCount = max(1, Set(transcriptByMeeting[selectedMeetingID, default: []].map(\.speakerID)).count)
                    if meeting.status == .draft {
                        meeting.subtitle = "刚刚 · Nano GGUF 已试跑"
                    }
                }
                persistSelectedMeetingSnapshot()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func analyzeSpeakersForSelectedMeeting() {
        guard let selectedMeetingID else { return }
        analyzeSpeakers(for: selectedMeetingID)
    }

    func beginSpeakerMerge(sourceID: Speaker.ID) {
        guard speakers.contains(where: { $0.id == sourceID }) else { return }
        pendingSpeakerMergeSourceID = sourceID
        let candidates = speakerMergeTargetCandidates
        if pendingSpeakerMergeTargetID == nil || !candidates.contains(where: { $0.id == pendingSpeakerMergeTargetID }) {
            pendingSpeakerMergeTargetID = candidates.first?.id
        }
    }

    func cancelSpeakerMerge() {
        pendingSpeakerMergeSourceID = nil
        pendingSpeakerMergeTargetID = nil
    }

    func mergePendingSpeaker() {
        guard let sourceID = pendingSpeakerMergeSourceID,
              let targetID = pendingSpeakerMergeTargetID else { return }
        mergeSpeaker(sourceID: sourceID, into: targetID)
    }

    func savePendingVoiceName() {
        let currentSpeakerIDs = selectedMeetingSpeakerIDs
        guard let index = speakers.firstIndex(where: { speaker in
            speaker.isUnnamed && (currentSpeakerIDs.isEmpty || currentSpeakerIDs.contains(speaker.id))
        }) else { return }
        let trimmedName = pendingVoiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        speakers[index].name = trimmedName
        speakers[index].role = rememberNamedVoice ? "已记忆声纹" : "仅本次会议"
        speakers[index].confidence = "95%"
        if rememberNamedVoice {
            saveVoiceprint(for: speakers[index])
        }
        persistSelectedMeetingSnapshot()
    }

    func updateSpeakerName(_ speakerID: Speaker.ID, name: String) {
        updateSpeakerName(speakerID, name: name, remember: rememberNamedVoice)
    }

    func updateSpeakerName(_ speakerID: Speaker.ID, name: String, remember: Bool) {
        guard let index = speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        speakers[index].name = trimmedName
        speakers[index].role = remember ? "已记忆声纹" : "仅本次会议"
        if remember {
            saveVoiceprint(for: speakers[index])
        }
        persistAllMeetingSnapshots()
    }

    func mergeSpeaker(sourceID: Speaker.ID, into targetID: Speaker.ID) {
        guard sourceID != targetID,
              let source = speakers.first(where: { $0.id == sourceID }),
              let target = speakers.first(where: { $0.id == targetID }) else { return }

        replaceSpeakerIDEverywhere(from: sourceID, to: targetID)
        mergeEmbedding(from: sourceID, into: targetID)
        speakerEmbeddingByID[sourceID] = nil
        speakers.removeAll { $0.id == sourceID }

        if let targetIndex = speakers.firstIndex(where: { $0.id == targetID }) {
            if target.isUnnamed || target.role == "待确认" {
                speakers[targetIndex].role = "已合并声纹"
            }
            speakers[targetIndex].confidence = maxConfidence(target.confidence, source.confidence)
            if let embedding = speakerEmbeddingByID[targetID] {
                speakerTrackManager.remember(speaker: speakers[targetIndex], embedding: embedding)
            }
            saveVoiceprint(for: speakers[targetIndex])
        }
        speakerTrackManager.merge(sourceID: sourceID, into: targetID)
        deleteVoiceprint(sourceID)

        for index in meetings.indices {
            let meetingID = meetings[index].id
            meetings[index].speakerCount = max(1, meetingSpeakerIDs(for: meetingID).count)
        }

        pendingSpeakerMergeSourceID = nil
        pendingSpeakerMergeTargetID = nil
        persistAllMeetingSnapshots()
    }

    func refreshLiveRecordingState() {
        guard selectedMeeting?.status == .live else { return }

        recorder.refreshMeters()

        updateSelectedMeeting { meeting in
            meeting.durationSeconds += 1
            meeting.subtitle = "正在录音 · 本机麦克风"
        }
        persistSelectedMeetingSnapshot()
    }

    func speaker(for speakerID: Speaker.ID) -> Speaker {
        speakers.first { $0.id == speakerID } ?? Speaker(
            id: speakerID,
            name: "未知说话人",
            voiceprint: "VP-UNKNOWN",
            role: "待确认",
            tint: .secondary,
            confidence: "--"
        )
    }

    @discardableResult
    private func ensurePlaceholderSpeaker(for meetingID: Meeting.ID, index: Int = 1) -> Speaker {
        if let speakerID = placeholderSpeakerIDsByMeeting[meetingID],
           let speaker = speakers.first(where: { $0.id == speakerID }) {
            return speaker
        }

        let name = "说话人\(index)"
        let currentSpeakerIDs = meetingSpeakerIDs(for: meetingID)
        if let speaker = speakers.first(where: { currentSpeakerIDs.contains($0.id) && $0.name == name }) {
            placeholderSpeakerIDsByMeeting[meetingID] = speaker.id
            return speaker
        }

        let speakerID = UUID()
        let speaker = Speaker(
            id: speakerID,
            name: name,
            voiceprint: "TEMP-\(index)",
            role: "实时临时声纹",
            tint: speakerTint(for: speakerID),
            confidence: "--"
        )
        speakers.append(speaker)
        placeholderSpeakerIDsByMeeting[meetingID] = speakerID
        return speaker
    }

    private func fallbackSpeakerID(for meetingID: Meeting.ID?) -> Speaker.ID {
        if let meetingID {
            return ensurePlaceholderSpeaker(for: meetingID).id
        }
        if let speaker = speakers.first(where: { $0.name.placeholderSpeakerNumber == 1 }) {
            return speaker.id
        }
        let speakerID = UUID()
        let speaker = Speaker(
            id: speakerID,
            name: "说话人1",
            voiceprint: "TEMP-1",
            role: "实时临时声纹",
            tint: speakerTint(for: speakerID),
            confidence: "--"
        )
        speakers.append(speaker)
        return speakerID
    }

    func engineItems() -> [EngineItem] {
        return [
            EngineItem(name: "录音", detail: selectedMeetingAudioPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "等待创建音频文件", status: recorder.currentMeetingID == selectedMeetingID ? "写入中" : "就绪", tint: recorder.currentMeetingID == selectedMeetingID ? .red : .green),
            EngineItem(name: "FunASR ONNX", detail: "online paraformer 非量化优先", status: transcriptionStatusText, tint: streamingTranscriber.isRunning || transcriber.isRunning ? .blue : (selectedMeetingEntries.isEmpty ? .orange : .green)),
            EngineItem(name: "Fun-ASR-Nano GGUF", detail: nanoGGUF.modelDetail, status: nanoGGUF.statusText, tint: nanoGGUF.isRunning ? .blue : (nanoGGUF.isReady ? .green : .orange)),
            EngineItem(name: "Qwen3-ASR", detail: "正文主增强 · \(qwenRefiner.modelName)", status: qwenRefiner.statusText, tint: qwenRefiner.isRunning ? .blue : (selectedMeetingEntries.contains { $0.confidence.hasPrefix("qwen3-asr") } ? .green : .orange)),
            EngineItem(name: "Whisper large", detail: "仅补漏 · \(whisperLarge.modelDetail)", status: whisperLarge.statusText, tint: whisperLarge.isRunning ? .blue : (whisperLarge.isReady ? .green : .orange)),
            EngineItem(name: "OpenAI 整理", detail: openAISummary.modelName, status: openAISummary.statusText, tint: openAISummary.isRunning ? .blue : (openAISummary.isConfigured ? .green : .orange)),
            EngineItem(name: "说话人分离", detail: speakerDiarizer.modelName, status: speakerDiarizer.statusText, tint: (speakerDiarizer.isRunning || speakerDiarizer.isLiveRunning) ? .blue : (unnamedSpeaker == nil ? .green : .orange)),
            EngineItem(name: "翻译", detail: "多语言到中文", status: selectedMeetingEntries.contains { $0.sourceLanguage != "中文" } ? "已启用" : "待触发", tint: .green),
            EngineItem(name: "llama.cpp", detail: llama.modelPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "GGUF 模型未配置", status: llama.statusText, tint: llama.modelPath == nil ? .orange : .green)
        ]
    }

    private func updateSelectedMeeting(_ update: (inout Meeting) -> Void) {
        guard let selectedMeetingID, let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }
        update(&meetings[index])
    }

    private func startRecorder(for meetingID: Meeting.ID, title: String) async {
        do {
            try streamingTranscriber.start { [weak self] update in
                self?.applyStreamingTranscript(update)
            } onError: { [weak self] message in
                Task { @MainActor in
                    self?.lastErrorMessage = message
                }
            }

            let pcmFanout = PCMChunkFanout()
            pcmFanout.add(streamingTranscriber.pcmChunkHandler())
            let directoryURL = MeetingFileStore.shared.rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
            let liveSpeakerPCMHandler = try speakerDiarizer.startLiveDiarization(
                meetingDirectoryPath: directoryURL.path,
                libraryPath: MeetingFileStore.shared.voiceprintDatabaseURL.path,
                onUpdate: { [weak self] update in
                    self?.applyLiveSpeakerDiarization(update, meetingID: meetingID)
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.lastErrorMessage = message
                    }
                }
            )
            pcmFanout.add(liveSpeakerPCMHandler)
            let qwenPCMHandler = try qwenRefiner.startLiveEnhancement(
                meetingDirectoryPath: directoryURL.path,
                language: preferredLanguage,
                onUpdate: { [weak self] update in
                    self?.applyQwenLiveRefinement(update, meetingID: meetingID)
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.lastErrorMessage = message
                    }
                }
            )
            pcmFanout.add(qwenPCMHandler)
            do {
                let whisperPCMHandler = try whisperLarge.startLiveTranscription(
                    meetingDirectoryPath: directoryURL.path,
                    language: preferredLanguage,
                    defaultSpeakerID: fallbackSpeakerID(for: meetingID),
                    onUpdate: { [weak self] update in
                        self?.applyWhisperLiveTranscription(update, meetingID: meetingID)
                    },
                    onError: { [weak self] message in
                        Task { @MainActor in
                            self?.lastErrorMessage = message
                        }
                    }
                )
                pcmFanout.add(whisperPCMHandler)
            } catch {
                lastErrorMessage = "Whisper large 未启动：\(error.localizedDescription)"
            }
            let session = try await recorder.startRecording(
                meetingID: meetingID,
                title: title,
                onPCMChunk: { data in
                    pcmFanout.send(data)
                }
            )

            guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[index].storageDirectoryPath = session.directoryURL.path
            meetings[index].audioFilePath = session.audioURL.path
            meetings[index].subtitle = "正在录音 · Qwen3-ASR 主增强，Whisper large 补漏"
            persistMeetingSnapshot(meetings[index])
        } catch {
            guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[index].status = .draft
            meetings[index].subtitle = "录音未启动 · \(error.localizedDescription)"
            lastErrorMessage = error.localizedDescription
            streamingTranscriber.stop()
            qwenRefiner.stopLiveEnhancement()
            whisperLarge.stopLiveTranscription()
            speakerDiarizer.stopLiveDiarization()
        }
    }

    private func applyStreamingTranscript(_ update: StreamingTranscriptUpdate) {
        guard let selectedMeetingID else { return }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let entry = TranscriptEntry(
            id: UUID(),
            time: selectedMeeting?.duration ?? "00:00:00",
            startMS: selectedMeeting.map { $0.durationSeconds * 1000 },
            endMS: selectedMeeting.map { $0.durationSeconds * 1000 },
            speakerID: fallbackSpeakerID(for: selectedMeetingID),
            sourceLanguage: "中文",
            original: text,
            translation: text,
            confidence: update.isFinal ? "final" : "stream"
        )
        liveStreamingEntryByMeeting[selectedMeetingID] = entry
    }

    private func applyQwenLiveRefinement(_ update: QwenLiveRefinementUpdate, meetingID: Meeting.ID) {
        let normalizedEntries = normalizeTranscript(update.entries, meetingID: meetingID)
        guard !normalizedEntries.isEmpty else { return }

        qwenLiveEntriesByMeeting[meetingID, default: [:]][update.commandID] = normalizedEntries
        rebuildLiveTranscript(for: meetingID)

        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].speakerCount = max(1, Set(transcriptByMeeting[meetingID, default: []].map(\.speakerID)).count)
            if meetings[index].status == .live {
                meetings[index].subtitle = "正在录音 · Qwen3-ASR 已回填片段"
            }
            persistMeetingSnapshot(meetings[index])
        }
    }

    private func applyWhisperLiveTranscription(_ update: WhisperLiveTranscriptionUpdate, meetingID: Meeting.ID) {
        let normalizedEntries = normalizeTranscript(update.entries, meetingID: meetingID)
        guard !normalizedEntries.isEmpty else { return }

        whisperLiveEntriesByMeeting[meetingID, default: [:]][update.commandID] = normalizedEntries
        rebuildLiveTranscript(for: meetingID)

        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].speakerCount = max(1, Set(transcriptByMeeting[meetingID, default: []].map(\.speakerID)).count)
            if meetings[index].status == .live {
                meetings[index].subtitle = "正在录音 · Whisper large 已补充空白片段"
            }
            persistMeetingSnapshot(meetings[index])
        }
    }

    private func applyLiveSpeakerDiarization(_ update: LiveSpeakerDiarizationUpdate, meetingID: Meeting.ID) {
        let reconciled = reconcileLiveSpeakerResult(update.result, meetingID: meetingID)

        for recognized in reconciled.speakers {
            speakerEmbeddingByID[recognized.id] = recognized.embedding
            upsertSpeaker(from: recognized)
        }

        let entries = normalizeTranscript(reconciled.transcript, meetingID: meetingID)
        guard !entries.isEmpty else { return }

        updateLiveDraftSpeaker(for: meetingID, using: entries)
        liveSpeakerEntriesByMeeting[meetingID, default: [:]][update.commandID] = entries
        rebuildLiveTranscript(for: meetingID)

        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            let speakerCount = [
                meetings[index].speakerCount,
                reconciled.speakers.count,
                Set(reconciled.segments.map(\.speakerID)).count,
                Set(transcriptByMeeting[meetingID, default: []].map(\.speakerID)).count
            ].max() ?? 1
            meetings[index].speakerCount = max(1, speakerCount)
            if meetings[index].status == .live {
                meetings[index].subtitle = "正在录音 · CAM++ 已实时回填声纹片段"
            }
            persistMeetingSnapshot(meetings[index])
        }
    }

    private func reconcileLiveSpeakerResult(_ result: SpeakerDiarizationResult, meetingID: Meeting.ID) -> SpeakerDiarizationResult {
        reconcileSpeakerResult(result)
    }

    private func updateLiveDraftSpeaker(for meetingID: Meeting.ID, using entries: [TranscriptEntry]) {
        guard var draft = liveStreamingEntryByMeeting[meetingID],
              let latest = entries.max(by: {
                  ($0.endMS ?? $0.startMS ?? Self.milliseconds(from: $0.time))
                    < ($1.endMS ?? $1.startMS ?? Self.milliseconds(from: $1.time))
              }) else { return }
        draft.speakerID = latest.speakerID
        liveStreamingEntryByMeeting[meetingID] = draft
        placeholderSpeakerIDsByMeeting[meetingID] = latest.speakerID
    }

    private func mergeEmbedding(_ embedding: [Double], into speakerID: Speaker.ID) {
        guard !embedding.isEmpty else { return }
        guard let existing = speakerEmbeddingByID[speakerID], existing.count == embedding.count else {
            speakerEmbeddingByID[speakerID] = embedding
            return
        }
        speakerEmbeddingByID[speakerID] = zip(existing, embedding).map { old, new in
            old * 0.7 + new * 0.3
        }
    }

    private func rebuildLiveTranscript(for meetingID: Meeting.ID) {
        let qwenEntries = qwenLiveEntriesByMeeting[meetingID, default: [:]]
            .values
            .flatMap { $0 }
        let whisperEntries = whisperLiveEntriesByMeeting[meetingID, default: [:]]
            .values
            .flatMap { $0 }
        let speakerEntries = liveSpeakerEntriesByMeeting[meetingID, default: [:]]
            .values
            .flatMap { $0 }

        var enhancedEntries: [TranscriptEntry] = []
        if !qwenEntries.isEmpty {
            let qwenNormalized = normalizeTranscript(qwenEntries, meetingID: meetingID)
            enhancedEntries = mergeWhisperGapEntries(
                normalizeTranscript(whisperEntries, meetingID: meetingID),
                into: qwenNormalized
            )
        } else if !whisperEntries.isEmpty {
            enhancedEntries = normalizeTranscript(whisperEntries, meetingID: meetingID)
        }

        let entries: [TranscriptEntry]
        if !enhancedEntries.isEmpty {
            entries = speakerEntries.isEmpty ? enhancedEntries : assignSpeakers(
                entries: enhancedEntries,
                using: speakerSegments(from: speakerEntries)
            )
        } else if !speakerEntries.isEmpty {
            entries = normalizeTranscript(speakerEntries, meetingID: meetingID)
        } else {
            entries = []
        }
        transcriptByMeeting[meetingID] = normalizeTranscript(entries, meetingID: meetingID)
    }

    private func speakerSegments(from entries: [TranscriptEntry]) -> [SpeakerDiarizationSegment] {
        entries.compactMap { entry -> SpeakerDiarizationSegment? in
            let startMS = entry.startMS ?? Self.milliseconds(from: entry.time)
            let endMS = entry.endMS ?? startMS
            guard endMS >= startMS else { return nil }
            return SpeakerDiarizationSegment(
                startMS: startMS,
                endMS: endMS,
                sourceSpk: 0,
                speakerID: entry.speakerID,
                text: entry.original
            )
        }
    }

    private func mergeWhisperGapEntries(_ whisperEntries: [TranscriptEntry], into baseEntries: [TranscriptEntry]) -> [TranscriptEntry] {
        guard !whisperEntries.isEmpty else { return baseEntries }
        var merged = baseEntries

        for whisperEntry in whisperEntries {
            guard !whisperEntry.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if !merged.contains(where: { Self.entriesOverlap($0, whisperEntry) }) {
                merged.append(whisperEntry)
            }
        }

        return merged
    }

    private func persistSelectedMeetingSnapshot() {
        guard let selectedMeeting else { return }
        persistMeetingSnapshot(selectedMeeting)
    }

    private func persistAllMeetingSnapshots() {
        for meeting in meetings {
            persistMeetingSnapshot(meeting)
        }
    }

    private func persistMeetingSnapshot(_ meeting: Meeting) {
        do {
            try MeetingFileStore.shared.writeSnapshot(
                meeting: meeting,
                transcript: transcriptByMeeting[meeting.id, default: []],
                summary: summaryByMeeting[meeting.id, default: []],
                speakers: speakers
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func maybeStartLiveTranscription(force: Bool = false) {
        guard let meeting = selectedMeeting, meeting.audioFilePath != nil, !transcriber.isRunning else { return }
        guard force || meeting.durationSeconds >= 4 else { return }
        guard force || meeting.durationSeconds - lastLiveTranscriptionSecond >= liveTranscriptionIntervalSeconds else { return }

        lastLiveTranscriptionSecond = meeting.durationSeconds
        Task { [weak self] in
            await self?.transcribeSelectedMeeting(isLive: meeting.status == .live || meeting.status == .paused)
        }
    }

    private func transcribeSelectedMeeting(isLive: Bool = false) async {
        guard let selectedMeetingID, let audioPath = selectedMeeting?.audioFilePath, let directoryPath = selectedMeeting?.storageDirectoryPath else { return }
        let transcriptPath = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("transcript.json")
            .path

        do {
            let entries = try await transcriber.transcribe(audioPath: audioPath, outputPath: transcriptPath)
            transcriptByMeeting[selectedMeetingID] = normalizeTranscript(entries, meetingID: selectedMeetingID)
            updateSelectedMeeting { meeting in
                meeting.speakerCount = max(1, Set(transcriptByMeeting[selectedMeetingID, default: []].map(\.speakerID)).count)
                if isLive && meeting.status == .live {
                    meeting.subtitle = "正在录音 · 实时转写已刷新"
                }
            }
            persistSelectedMeetingSnapshot()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func normalizeTranscript(_ entries: [TranscriptEntry], meetingID: Meeting.ID? = nil) -> [TranscriptEntry] {
        entries.map { entry in
            var normalized = entry
            if !speakers.contains(where: { $0.id == normalized.speakerID }) {
                normalized.speakerID = fallbackSpeakerID(for: meetingID)
            }
            return normalized
        }
    }

    private func analyzeSpeakers(for meetingID: Meeting.ID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }),
              let audioPath = meeting.audioFilePath,
              let directoryPath = meeting.storageDirectoryPath else { return }

        let outputPath = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("speaker_diarization.json")
            .path
        let libraryPath = MeetingFileStore.shared.voiceprintDatabaseURL.path

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await speakerDiarizer.diarize(
                    audioPath: audioPath,
                    outputPath: outputPath,
                    libraryPath: libraryPath
                )
                applySpeakerDiarization(result, meetingID: meetingID)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func applySpeakerDiarization(_ result: SpeakerDiarizationResult, meetingID: Meeting.ID) {
        let reconciled = reconcileSpeakerResult(result)

        for recognized in reconciled.speakers {
            speakerEmbeddingByID[recognized.id] = recognized.embedding
            upsertSpeaker(from: recognized)
        }

        let existingEntries = transcriptByMeeting[meetingID, default: []]
        let diarizedEntries = normalizeTranscript(reconciled.transcript, meetingID: meetingID)
        let detectedSpeakerCount = [
            reconciled.speakers.count,
            Set(reconciled.segments.map(\.speakerID)).count,
            Set(diarizedEntries.map(\.speakerID)).count
        ].max() ?? 0

        let entries: [TranscriptEntry]
        if !existingEntries.isEmpty {
            entries = assignSpeakers(entries: existingEntries, using: reconciled.segments)
        } else if !diarizedEntries.isEmpty {
            entries = diarizedEntries
        } else {
            entries = []
        }
        transcriptByMeeting[meetingID] = entries

        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].speakerCount = [
                1,
                detectedSpeakerCount,
                Set(entries.map(\.speakerID)).count
            ].max() ?? 1
            if meetings[index].status == .draft {
                meetings[index].subtitle = "刚刚结束 · CAM++ 已完成声纹分析"
            }
            persistMeetingSnapshot(meetings[index])
        }
    }

    private func reconcileSpeakerResult(_ result: SpeakerDiarizationResult) -> SpeakerDiarizationResult {
        speakerTrackManager.reconcile(
            result,
            knownSpeakers: speakers,
            rememberedSpeakerIDs: rememberedVoiceprintIDs
        )
    }

    private func meetingSpeakerIDs(for meetingID: Meeting.ID) -> Set<Speaker.ID> {
        var ids = Set(transcriptByMeeting[meetingID, default: []].map(\.speakerID))
        if let liveDraft = liveStreamingEntryByMeeting[meetingID] {
            ids.insert(liveDraft.speakerID)
        }
        ids.formUnion(
            liveSpeakerEntriesByMeeting[meetingID, default: [:]]
                .values
                .flatMap { $0 }
                .map(\.speakerID)
        )
        ids.formUnion(
            qwenLiveEntriesByMeeting[meetingID, default: [:]]
                .values
                .flatMap { $0 }
                .map(\.speakerID)
        )
        ids.formUnion(
            whisperLiveEntriesByMeeting[meetingID, default: [:]]
                .values
                .flatMap { $0 }
                .map(\.speakerID)
        )
        return ids
    }

    private func upsertSpeaker(from recognized: RecognizedSpeaker) {
        let tint = speakerTint(for: recognized.id)
        if let index = speakers.firstIndex(where: { $0.id == recognized.id }) {
            if speakers[index].isUnnamed || !recognized.name.isUnnamedVoiceName {
                speakers[index].name = recognized.name
            }
            if speakers[index].voiceprint == "VP-UNKNOWN" || !recognized.voiceprint.isEmpty {
                speakers[index].voiceprint = recognized.voiceprint
            }
            if speakers[index].role == "待确认" || speakers[index].role.hasPrefix("临时") || recognized.role == "已记忆声纹" {
                speakers[index].role = recognized.role
            }
            speakers[index].confidence = maxConfidence(speakers[index].confidence, recognized.confidence)
            return
        }

        speakers.append(
            Speaker(
                id: recognized.id,
                name: recognized.name,
                voiceprint: recognized.voiceprint,
                role: recognized.role,
                tint: tint,
                confidence: recognized.confidence
            )
        )
    }

    private func assignSpeakers(entries: [TranscriptEntry], using segments: [SpeakerDiarizationSegment]) -> [TranscriptEntry] {
        guard !segments.isEmpty else { return entries }
        return entries.map { entry in
            var updated = entry
            let timeMS = Self.milliseconds(from: entry.time)
            if let segment = segments.first(where: { $0.startMS <= timeMS && timeMS <= $0.endMS })
                ?? segments.min(by: { abs($0.startMS - timeMS) < abs($1.startMS - timeMS) }) {
                updated.speakerID = segment.speakerID
            }
            return updated
        }
    }

    private func replaceSpeakerIDEverywhere(from sourceID: Speaker.ID, to targetID: Speaker.ID) {
        for meetingID in Array(transcriptByMeeting.keys) {
            var entries = transcriptByMeeting[meetingID, default: []]
            replaceSpeakerID(in: &entries, from: sourceID, to: targetID)
            transcriptByMeeting[meetingID] = entries
        }

        for meetingID in Array(liveStreamingEntryByMeeting.keys) {
            guard liveStreamingEntryByMeeting[meetingID]?.speakerID == sourceID else { continue }
            liveStreamingEntryByMeeting[meetingID]?.speakerID = targetID
        }

        replaceSpeakerID(in: &liveSpeakerEntriesByMeeting, from: sourceID, to: targetID)
        replaceSpeakerID(in: &qwenLiveEntriesByMeeting, from: sourceID, to: targetID)
        replaceSpeakerID(in: &whisperLiveEntriesByMeeting, from: sourceID, to: targetID)
    }

    private func replaceSpeakerID(
        in groupedEntries: inout [Meeting.ID: [UUID: [TranscriptEntry]]],
        from sourceID: Speaker.ID,
        to targetID: Speaker.ID
    ) {
        for meetingID in Array(groupedEntries.keys) {
            var commandEntries = groupedEntries[meetingID, default: [:]]
            for commandID in Array(commandEntries.keys) {
                var entries = commandEntries[commandID, default: []]
                replaceSpeakerID(in: &entries, from: sourceID, to: targetID)
                commandEntries[commandID] = entries
            }
            groupedEntries[meetingID] = commandEntries
        }
    }

    private func replaceSpeakerID(in entries: inout [TranscriptEntry], from sourceID: Speaker.ID, to targetID: Speaker.ID) {
        for index in entries.indices where entries[index].speakerID == sourceID {
            entries[index].speakerID = targetID
        }
    }

    private func loadVoiceprintLibrary() {
        for record in MeetingFileStore.shared.loadVoiceprintLibrary() {
            speakerEmbeddingByID[record.id] = record.embedding
            rememberedVoiceprintIDs.insert(record.id)
            if let index = speakers.firstIndex(where: { $0.id == record.id }) {
                speakers[index].name = record.name
                speakers[index].voiceprint = record.voiceprint
                speakers[index].role = record.role
                speakers[index].confidence = record.confidence
                speakerTrackManager.remember(speaker: speakers[index], embedding: record.embedding)
            } else {
                let speaker = Speaker(
                    id: record.id,
                    name: record.name,
                    voiceprint: record.voiceprint,
                    role: record.role,
                    tint: speakerTint(for: record.id),
                    confidence: record.confidence
                )
                speakers.append(speaker)
                speakerTrackManager.remember(speaker: speaker, embedding: record.embedding)
            }
        }
    }

    private func saveVoiceprint(for speaker: Speaker) {
        guard let embedding = speakerEmbeddingByID[speaker.id], !embedding.isEmpty else { return }
        let record = VoiceprintRecord(
            id: speaker.id,
            name: speaker.name,
            voiceprint: speaker.voiceprint,
            role: speaker.role,
            confidence: speaker.confidence,
            embedding: embedding,
            updatedAt: Date()
        )
        do {
            try MeetingFileStore.shared.upsertVoiceprint(record)
            rememberedVoiceprintIDs.insert(speaker.id)
            speakerTrackManager.remember(speaker: speaker, embedding: embedding)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func deleteVoiceprint(_ speakerID: Speaker.ID) {
        var records = MeetingFileStore.shared.loadVoiceprintLibrary()
        records.removeAll { $0.id == speakerID }
        do {
            try MeetingFileStore.shared.writeVoiceprintLibrary(records)
            rememberedVoiceprintIDs.remove(speakerID)
            speakerTrackManager.forget(speakerID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func mergeEmbedding(from sourceID: Speaker.ID, into targetID: Speaker.ID) {
        guard let sourceEmbedding = speakerEmbeddingByID[sourceID], !sourceEmbedding.isEmpty else { return }
        mergeEmbedding(sourceEmbedding, into: targetID)
    }

    private func maxConfidence(_ lhs: String, _ rhs: String) -> String {
        let left = Int(lhs.filter(\.isNumber)) ?? 0
        let right = Int(rhs.filter(\.isNumber)) ?? 0
        let value = max(left, right)
        return value > 0 ? "\(value)%" : lhs
    }

    private func speakerTint(for id: Speaker.ID) -> Color {
        let colors: [Color] = [.blue, .purple, .teal, .orange, .green, .indigo, .pink, .cyan]
        let index = abs(id.uuidString.hashValue) % colors.count
        return colors[index]
    }

    private static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0 else { return 0 }
        return dot / denominator
    }

    private static func milliseconds(from time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return ((parts[0] * 3600) + (parts[1] * 60) + parts[2]) * 1000
    }

    private static func entriesOverlap(_ lhs: TranscriptEntry, _ rhs: TranscriptEntry) -> Bool {
        let lhsStart = lhs.startMS ?? milliseconds(from: lhs.time)
        let rhsStart = rhs.startMS ?? milliseconds(from: rhs.time)
        let lhsEnd = lhs.endMS ?? lhsStart
        let rhsEnd = rhs.endMS ?? rhsStart
        let overlap = min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart)
        let shorterDuration = max(1, min(lhsEnd - lhsStart, rhsEnd - rhsStart))
        return abs(lhsStart - rhsStart) <= 2_000 || (overlap > 0 && Double(overlap) / Double(shorterDuration) >= 0.5)
    }

    private static func textLooksEnglish(_ text: String) -> Bool {
        var latinCount = 0
        var cjkCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latinCount += 1
            case 0x4E00...0x9FFF:
                cjkCount += 1
            default:
                break
            }
        }
        return latinCount > max(8, cjkCount * 2)
    }

    private func preferredEntriesForSummary() -> [TranscriptEntry] {
        let enhancedEntries = selectedMeetingEntries.filter { entry in
            entry.confidence.hasPrefix("qwen3-asr")
                || entry.confidence.hasPrefix("whisper-large")
                || entry.confidence == "nano-gguf"
        }
        return enhancedEntries.isEmpty ? selectedMeetingEntries : enhancedEntries
    }

    private func speakerNamesByID(for entries: [TranscriptEntry]) -> [Speaker.ID: String] {
        var names: [Speaker.ID: String] = [:]
        for entry in entries where names[entry.speakerID] == nil {
            names[entry.speakerID] = speaker(for: entry.speakerID).displayName
        }
        return names
    }

    private static func mergeSpeakers(_ seedSpeakers: [Speaker], with records: [SpeakerRecord]) -> [Speaker] {
        var merged = seedSpeakers
        let tints: [Color] = [.blue, .purple, .teal, .orange, .green, .indigo, .pink, .cyan]
        for record in records {
            guard !merged.contains(where: { $0.id == record.id }) else { continue }
            let tint = tints[merged.count % tints.count]
            merged.append(
                Speaker(
                    id: record.id,
                    name: record.name,
                    voiceprint: record.voiceprint,
                    role: record.role,
                    tint: tint,
                    confidence: record.confidence
                )
            )
        }
        return merged
    }
}

private final class PCMChunkFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(Data) -> Void] = []

    func add(_ handler: @escaping (Data) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        let currentHandlers = handlers
        lock.unlock()
        currentHandlers.forEach { $0(data) }
    }
}

private extension String {
    var isUnnamedVoiceName: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "未命名声纹"
            || normalized.hasPrefix("未命名声纹 ")
            || placeholderSpeakerNumber != nil
    }

    var placeholderSpeakerNumber: Int? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "说话人"
        guard normalized.hasPrefix(prefix) else { return nil }
        let suffix = normalized.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(suffix)
    }
}

private extension Array where Element == TranscriptEntry {
    func groupedForDisplay() -> [TranscriptEntry] {
        mergeAdjacentTranscript(deduplicatedForDisplay(sortedForDisplay()))
    }

    private func sortedForDisplay() -> [TranscriptEntry] {
        sorted { lhs, rhs in
            let lhsStart = lhs.startMS ?? milliseconds(from: lhs.time)
            let rhsStart = rhs.startMS ?? milliseconds(from: rhs.time)
            if lhsStart == rhsStart {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhsStart < rhsStart
        }
    }

    private func deduplicatedForDisplay(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        var accepted: [TranscriptEntry] = []
        for entry in entries {
            guard let duplicateIndex = accepted.firstIndex(where: { isDisplayDuplicate($0, entry) }) else {
                accepted.append(entry)
                continue
            }

            if entry.original.count > accepted[duplicateIndex].original.count {
                accepted[duplicateIndex] = entry
            }
        }
        return accepted
    }

    private func isDisplayDuplicate(_ lhs: TranscriptEntry, _ rhs: TranscriptEntry) -> Bool {
        guard lhs.speakerID == rhs.speakerID else { return false }
        guard lhs.sourceLanguage == rhs.sourceLanguage else { return false }

        let lhsStart = lhs.startMS ?? milliseconds(from: lhs.time)
        let rhsStart = rhs.startMS ?? milliseconds(from: rhs.time)
        let lhsEnd = lhs.endMS ?? lhsStart
        let rhsEnd = rhs.endMS ?? rhsStart
        let overlap = Swift.min(lhsEnd, rhsEnd) - Swift.max(lhsStart, rhsStart)
        let shorterDuration = Swift.max(1, Swift.min(lhsEnd - lhsStart, rhsEnd - rhsStart))
        let sameInstant = abs(lhsStart - rhsStart) <= 1_000
        let overlapsSameAudio = overlap > 0 && Double(overlap) / Double(shorterDuration) >= 0.70
        guard sameInstant || overlapsSameAudio else { return false }

        return textLooksDuplicate(lhs.original, rhs.original)
    }

    private func textLooksDuplicate(_ lhs: String, _ rhs: String) -> Bool {
        let left = comparableText(lhs)
        let right = comparableText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }

        let shorter = Swift.min(left.count, right.count)
        let longer = Swift.max(left.count, right.count)
        if shorter >= 8 && Double(shorter) / Double(longer) >= 0.65 && (left.contains(right) || right.contains(left)) {
            return true
        }

        return diceCoefficient(left, right) >= 0.82
    }

    private func comparableText(_ text: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return text.unicodeScalars
            .filter { !punctuation.contains($0) }
            .map(String.init)
            .joined()
    }

    private func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
        let left = Swift.Array(lhs)
        let right = Swift.Array(rhs)
        guard left.count >= 2, right.count >= 2 else { return lhs == rhs ? 1 : 0 }

        var counts: [String: Int] = [:]
        for index in 0..<(left.count - 1) {
            counts[String(left[index]) + String(left[index + 1]), default: 0] += 1
        }

        var matches = 0
        for index in 0..<(right.count - 1) {
            let key = String(right[index]) + String(right[index + 1])
            guard let count = counts[key], count > 0 else { continue }
            counts[key] = count - 1
            matches += 1
        }

        return Double(2 * matches) / Double(left.count + right.count - 2)
    }

    private func mergeAdjacentTranscript(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        var merged: [TranscriptEntry] = []
        for entry in entries {
            let currentText = entry.original.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !currentText.isEmpty else { continue }

            guard var previous = merged.last else {
                merged.append(entry)
                continue
            }

            let canMerge = previous.speakerID == entry.speakerID
                && previous.sourceLanguage == entry.sourceLanguage

            guard canMerge else {
                merged.append(entry)
                continue
            }

            let previousEnd = previous.endMS ?? previous.startMS ?? milliseconds(from: previous.time)
            let currentStart = entry.startMS ?? milliseconds(from: entry.time)
            previous.original = joinText(previous.original, entry.original)
            previous.translation = joinText(previous.translation, entry.translation)
            previous.endMS = Swift.max(previousEnd, entry.endMS ?? currentStart)
            previous.confidence = previous.confidence == entry.confidence ? previous.confidence : "merged"
            merged[merged.count - 1] = previous
        }
        return merged
    }

    private func joinText(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let noSpaceBefore: Set<Character> = ["，", "。", "、", "！", "？", "；", "：", ",", ".", "!", "?", ";", ":"]
        if let first = right.first, noSpaceBefore.contains(first) {
            return left + right
        }
        return left + right
    }

    private func milliseconds(from time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return ((parts[0] * 3600) + (parts[1] * 60) + parts[2]) * 1000
    }
}

struct SampleSeed {
    var meetings: [Meeting]
    var speakers: [Speaker]
    var transcriptByMeeting: [Meeting.ID: [TranscriptEntry]]
    var summaryByMeeting: [Meeting.ID: [SummaryPoint]]

    static let `default`: SampleSeed = {
        let meetings = [
            Meeting(id: UUID(), title: "跨国项目周会", subtitle: "今天 19:04 · Teams 音频", createdAt: Date(), durationSeconds: 1122, status: .draft, speakerCount: 4, storageDirectoryPath: nil, audioFilePath: nil),
            Meeting(id: UUID(), title: "FunASR 本地部署评审", subtitle: "昨天 · 研发会议室 A", createdAt: Date(), durationSeconds: 3851, status: .ready, speakerCount: 6, storageDirectoryPath: nil, audioFilePath: nil),
            Meeting(id: UUID(), title: "客户访谈：华东试点", subtitle: "6月25日 · 远程录音", createdAt: Date(), durationSeconds: 2538, status: .draft, speakerCount: 3, storageDirectoryPath: nil, audioFilePath: nil),
            Meeting(id: UUID(), title: "声纹命名校准", subtitle: "6月23日 · 本机麦克风", createdAt: Date(), durationSeconds: 728, status: .ready, speakerCount: 2, storageDirectoryPath: nil, audioFilePath: nil)
        ]

        let speakers = [
            Speaker(id: UUID(), name: "刘晨", voiceprint: "VP-0182", role: "产品负责人", tint: .blue, confidence: "98%"),
            Speaker(id: UUID(), name: "Maya Chen", voiceprint: "VP-0247", role: "海外运营", tint: .purple, confidence: "96%"),
            Speaker(id: UUID(), name: "陈默", voiceprint: "VP-0031", role: "算法工程师", tint: .teal, confidence: "94%"),
            Speaker(id: UUID(), name: "未命名声纹", voiceprint: "VP-NEW", role: "待确认", tint: .orange, confidence: "82%")
        ]

        let liveTranscript = [
            TranscriptEntry(
                id: UUID(),
                time: "19:04:12",
                startMS: nil,
                endMS: nil,
                speakerID: speakers[0].id,
                sourceLanguage: "中文",
                original: "我们今天主要确认本地转写、声纹记忆和会后整理三个模块的边界。",
                translation: "我们今天主要确认本地转写、声纹记忆和会后整理三个模块的边界。",
                confidence: "0.97"
            ),
            TranscriptEntry(
                id: UUID(),
                time: "19:05:31",
                startMS: nil,
                endMS: nil,
                speakerID: speakers[1].id,
                sourceLanguage: "English",
                original: "For multilingual meetings, the live Chinese translation needs to stay close to the speaker timeline.",
                translation: "对于多语言会议，实时中文翻译需要紧贴发言人的时间线。",
                confidence: "0.94"
            ),
            TranscriptEntry(
                id: UUID(),
                time: "19:07:46",
                startMS: nil,
                endMS: nil,
                speakerID: speakers[2].id,
                sourceLanguage: "中文",
                original: "FunASR 可以先负责流式识别，声纹聚类结果暂时用独立队列回填到同一条转写记录。",
                translation: "FunASR 可以先负责流式识别，声纹聚类结果暂时用独立队列回填到同一条转写记录。",
                confidence: "0.92"
            ),
            TranscriptEntry(
                id: UUID(),
                time: "19:10:03",
                startMS: nil,
                endMS: nil,
                speakerID: speakers[3].id,
                sourceLanguage: "日本語",
                original: "会議の最後に、発言者ごとの結論を自動でまとめたいです。",
                translation: "会议结束时，希望能自动按发言人整理结论。",
                confidence: "0.88"
            )
        ]

        let readySummary = [
            SummaryPoint(id: UUID(), speaker: "刘晨", title: "产品边界", detail: "先做会议记录闭环：录音、转写、翻译、声纹命名、会后纪要。高级编辑功能延后。"),
            SummaryPoint(id: UUID(), speaker: "Maya Chen", title: "实时翻译体验", detail: "不同语言都要落到中文主时间线，保留原文用于核对，翻译延迟需要可见。"),
            SummaryPoint(id: UUID(), speaker: "陈默", title: "本地推理链路", detail: "FunASR 负责流式 ASR，llama.cpp 承担轻量摘要与结构化整理，Codex 用于最终会议总结。")
        ]

        return SampleSeed(
            meetings: meetings,
            speakers: speakers,
            transcriptByMeeting: [
                meetings[0].id: liveTranscript,
                meetings[1].id: liveTranscript.dropLast().map { $0 },
                meetings[2].id: Array(liveTranscript.prefix(2)),
                meetings[3].id: [liveTranscript[0], liveTranscript[3]]
            ],
            summaryByMeeting: [
                meetings[0].id: [],
                meetings[1].id: readySummary,
                meetings[2].id: [],
                meetings[3].id: Array(readySummary.prefix(2))
            ]
        )
    }()
}
