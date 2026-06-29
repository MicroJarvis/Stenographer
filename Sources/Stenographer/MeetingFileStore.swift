import Foundation

struct MeetingMetadata: Codable {
    var id: UUID
    var title: String
    var subtitle: String
    var createdAt: Date
    var durationSeconds: Int
    var status: String
    var speakerCount: Int
    var audioFilename: String?
}

struct SpeakerRecord: Codable {
    var id: UUID
    var name: String
    var voiceprint: String
    var role: String
    var confidence: String
}

struct StoredMeetingSnapshot {
    var meeting: Meeting
    var transcript: [TranscriptEntry]
    var summary: [SummaryPoint]
    var speakers: [SpeakerRecord]
}

struct VoiceprintRecord: Codable {
    var id: UUID
    var name: String
    var voiceprint: String
    var role: String
    var confidence: String
    var embedding: [Double]
    var updatedAt: Date
}

@MainActor
final class MeetingFileStore {
    static let shared = MeetingFileStore()

    let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let appSupportURL = applicationSupport
            .appendingPathComponent("Stenographer", isDirectory: true)
        rootURL = appSupportURL
            .appendingPathComponent("Meetings", isDirectory: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        migrateLegacyStoreIfNeeded(applicationSupport: applicationSupport, appSupportURL: appSupportURL)
    }

    func createRecordingSession(meetingID: UUID, title: String) throws -> RecordingSession {
        let directoryURL = rootURL.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let audioURL = directoryURL.appendingPathComponent("recording.caf")
        try writeEmptyJSONFiles(in: directoryURL)

        return RecordingSession(
            meetingID: meetingID,
            directoryURL: directoryURL,
            audioURL: audioURL
        )
    }

    func writeSnapshot(meeting: Meeting, transcript: [TranscriptEntry], summary: [SummaryPoint], speakers: [Speaker]) throws {
        guard let directoryPath = meeting.storageDirectoryPath else { return }
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let metadata = MeetingMetadata(
            id: meeting.id,
            title: meeting.title,
            subtitle: meeting.subtitle,
            createdAt: meeting.createdAt,
            durationSeconds: meeting.durationSeconds,
            status: meeting.status.rawValue,
            speakerCount: meeting.speakerCount,
            audioFilename: meeting.audioFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        )

        let speakerRecords = speakers.map {
            SpeakerRecord(
                id: $0.id,
                name: $0.name,
                voiceprint: $0.voiceprint,
                role: $0.role,
                confidence: $0.confidence
            )
        }

        try write(metadata, to: directoryURL.appendingPathComponent("metadata.json"))
        try write(transcript, to: directoryURL.appendingPathComponent("transcript.json"))
        try write(summary, to: directoryURL.appendingPathComponent("summary.json"))
        try write(speakerRecords, to: directoryURL.appendingPathComponent("speakers.json"))
    }

    var voiceprintLibraryURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent("speaker_library.json")
    }

    var voiceprintDatabaseURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent("speaker_voiceprints.sqlite")
    }

    func loadVoiceprintLibrary() -> [VoiceprintRecord] {
        let jsonRecords = decode([VoiceprintRecord].self, from: voiceprintLibraryURL) ?? []
        let database = VoiceprintDatabase(url: voiceprintDatabaseURL)
        database.migrateFromJSONIfNeeded(records: jsonRecords)
        return database.loadRecords()
    }

    func writeVoiceprintLibrary(_ records: [VoiceprintRecord]) throws {
        let database = VoiceprintDatabase(url: voiceprintDatabaseURL)
        try database.replaceAll(records)
        try fileManager.createDirectory(
            at: voiceprintLibraryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(records, to: voiceprintLibraryURL)
    }

    func upsertVoiceprint(_ record: VoiceprintRecord) throws {
        let database = VoiceprintDatabase(url: voiceprintDatabaseURL)
        try database.upsert(record)

        var jsonRecords = decode([VoiceprintRecord].self, from: voiceprintLibraryURL) ?? []
        if let index = jsonRecords.firstIndex(where: { $0.id == record.id }) {
            jsonRecords[index] = record
        } else {
            jsonRecords.append(record)
        }
        try fileManager.createDirectory(
            at: voiceprintLibraryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(jsonRecords, to: voiceprintLibraryURL)
    }

    func loadSnapshots() -> [StoredMeetingSnapshot] {
        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return directoryURLs.compactMap { directoryURL in
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return loadSnapshot(from: directoryURL)
        }
        .sorted { $0.meeting.createdAt > $1.meeting.createdAt }
    }

    private func writeEmptyJSONFiles(in directoryURL: URL) throws {
        try write([TranscriptEntry](), to: directoryURL.appendingPathComponent("transcript.json"))
        try write([SummaryPoint](), to: directoryURL.appendingPathComponent("summary.json"))
        try write([SpeakerRecord](), to: directoryURL.appendingPathComponent("speakers.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func loadSnapshot(from directoryURL: URL) -> StoredMeetingSnapshot? {
        let metadataURL = directoryURL.appendingPathComponent("metadata.json")
        guard let metadata = decode(MeetingMetadata.self, from: metadataURL) else { return nil }

        let transcript = decode([TranscriptEntry].self, from: directoryURL.appendingPathComponent("transcript.json")) ?? []
        let summary = decode([SummaryPoint].self, from: directoryURL.appendingPathComponent("summary.json")) ?? []
        let speakers = decode([SpeakerRecord].self, from: directoryURL.appendingPathComponent("speakers.json")) ?? []
        let status = MeetingStatus(rawValue: metadata.status) ?? .draft
        let audioPath = metadata.audioFilename.map {
            directoryURL.appendingPathComponent($0).path
        }

        let meeting = Meeting(
            id: metadata.id,
            title: metadata.title,
            subtitle: metadata.subtitle,
            createdAt: metadata.createdAt,
            durationSeconds: metadata.durationSeconds,
            status: status,
            speakerCount: metadata.speakerCount,
            storageDirectoryPath: directoryURL.path,
            audioFilePath: audioPath
        )

        return StoredMeetingSnapshot(
            meeting: meeting,
            transcript: transcript,
            summary: summary,
            speakers: speakers
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func migrateLegacyStoreIfNeeded(applicationSupport: URL, appSupportURL: URL) {
        let legacyAppSupportURL = applicationSupport.appendingPathComponent("VoiceTransform", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyAppSupportURL.path),
              !fileManager.fileExists(atPath: appSupportURL.path) else { return }
        do {
            try fileManager.copyItem(at: legacyAppSupportURL, to: appSupportURL)
        } catch {
            // Migration is best-effort; the app can continue with an empty Stenographer store.
        }
    }
}
