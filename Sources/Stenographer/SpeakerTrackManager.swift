import Foundation

final class SpeakerTrackManager {
    private struct Track {
        var id: UUID
        var name: String
        var voiceprint: String
        var role: String
        var confidence: String
        var centroid: [Double]
        var hitCount: Int
        var lastSeenMS: Int
        var isRemembered: Bool
    }

    private struct Match {
        var trackID: UUID
        var score: Double
        var secondScore: Double

        var margin: Double {
            score - secondScore
        }
    }

    private let confirmedThreshold = 0.80
    private let tentativeThreshold = 0.68
    private let ambiguousMargin = 0.05
    private let promotionHitCount = 2
    private var tracks: [UUID: Track] = [:]
    private var nextPlaceholderIndex = 1
    private var reservedTemporaryTrackIDsByName: [String: UUID] = [:]

    func reset(rememberedSpeakers: [Speaker], embeddingsByID: [UUID: [Double]]) {
        tracks.removeAll()
        nextPlaceholderIndex = 1
        reservedTemporaryTrackIDsByName.removeAll()
        for speaker in rememberedSpeakers {
            guard let embedding = embeddingsByID[speaker.id], !embedding.isEmpty else { continue }
            tracks[speaker.id] = Track(
                id: speaker.id,
                name: speaker.name,
                voiceprint: speaker.voiceprint,
                role: speaker.role,
                confidence: speaker.confidence,
                centroid: embedding,
                hitCount: promotionHitCount,
                lastSeenMS: 0,
                isRemembered: true
            )
        }
    }

    func reserveTemporarySpeaker(_ speaker: Speaker) {
        guard Self.isPlaceholderSpeakerName(speaker.name) else { return }
        reservedTemporaryTrackIDsByName[speaker.name] = speaker.id
    }

    func remember(speaker: Speaker, embedding: [Double]) {
        guard !embedding.isEmpty else { return }
        tracks[speaker.id] = Track(
            id: speaker.id,
            name: speaker.name,
            voiceprint: speaker.voiceprint,
            role: speaker.role,
            confidence: speaker.confidence,
            centroid: embedding,
            hitCount: promotionHitCount,
            lastSeenMS: tracks[speaker.id]?.lastSeenMS ?? 0,
            isRemembered: true
        )
    }

    func forget(_ speakerID: UUID) {
        tracks.removeValue(forKey: speakerID)
    }

    func merge(sourceID: UUID, into targetID: UUID) {
        guard var target = tracks[targetID] else {
            tracks.removeValue(forKey: sourceID)
            return
        }
        if let source = tracks[sourceID], source.centroid.count == target.centroid.count {
            target.centroid = Self.blend(old: target.centroid, new: source.centroid, newWeight: 0.35)
            target.hitCount = max(target.hitCount, source.hitCount)
            target.lastSeenMS = max(target.lastSeenMS, source.lastSeenMS)
            target.isRemembered = target.isRemembered || source.isRemembered
        }
        tracks[targetID] = target
        tracks.removeValue(forKey: sourceID)
    }

    func reconcile(
        _ result: SpeakerDiarizationResult,
        knownSpeakers: [Speaker],
        rememberedSpeakerIDs: Set<UUID>
    ) -> SpeakerDiarizationResult {
        syncKnownSpeakerNames(knownSpeakers, rememberedSpeakerIDs: rememberedSpeakerIDs)

        let segmentStats = statsBySourceSpeaker(result.segments)
        var idMap: [UUID: UUID] = [:]
        var reconciledSpeakersByID: [UUID: RecognizedSpeaker] = [:]
        var assignedThisWindow = Set<UUID>()

        for var recognized in result.speakers {
            let stats = segmentStats[recognized.sourceSpk] ?? SegmentStats()
            let assignment = assignTrack(for: recognized, stats: stats, assignedThisWindow: assignedThisWindow)
            idMap[recognized.id] = assignment.id
            assignedThisWindow.insert(assignment.id)

            recognized.id = assignment.id
            recognized.name = assignment.name
            recognized.voiceprint = assignment.voiceprint
            recognized.role = assignment.role
            recognized.confidence = assignment.confidence
            recognized.embedding = assignment.embedding
            recognized.similarity = assignment.similarity
            reconciledSpeakersByID[recognized.id] = recognized
        }

        let segments = result.segments.map { segment in
            var updated = segment
            updated.speakerID = idMap[segment.speakerID] ?? segment.speakerID
            return updated
        }

        let transcript = result.transcript.map { entry in
            var updated = entry
            updated.speakerID = idMap[entry.speakerID] ?? entry.speakerID
            return updated
        }

        return SpeakerDiarizationResult(
            speakers: Array(reconciledSpeakersByID.values),
            segments: segments,
            transcript: transcript
        )
    }

    private struct Assignment {
        var id: UUID
        var name: String
        var voiceprint: String
        var role: String
        var confidence: String
        var embedding: [Double]
        var similarity: Double?
    }

    private struct SegmentStats {
        var durationMS = 0
        var lastSeenMS = 0
    }

    private func assignTrack(
        for recognized: RecognizedSpeaker,
        stats: SegmentStats,
        assignedThisWindow: Set<UUID>
    ) -> Assignment {
        guard !recognized.embedding.isEmpty else {
            return Assignment(
                id: recognized.id,
                name: recognized.name,
                voiceprint: recognized.voiceprint,
                role: "临时声纹",
                confidence: recognized.confidence,
                embedding: recognized.embedding,
                similarity: recognized.similarity
            )
        }

        if let match = bestMatch(for: recognized.embedding),
           shouldUse(match, stats: stats, assignedThisWindow: assignedThisWindow),
           var track = tracks[match.trackID] {
            let newWeight = track.isRemembered ? 0.18 : 0.35
            track.centroid = Self.blend(old: track.centroid, new: recognized.embedding, newWeight: newWeight)
            track.hitCount += 1
            track.lastSeenMS = max(track.lastSeenMS, stats.lastSeenMS)
            if !track.isRemembered && track.hitCount >= promotionHitCount {
                track.role = "临时稳定声纹"
            }
            track.confidence = Self.percent(match.score)
            tracks[track.id] = track
            return Assignment(
                id: track.id,
                name: track.name,
                voiceprint: track.voiceprint,
                role: track.role,
                confidence: track.confidence,
                embedding: track.centroid,
                similarity: match.score
            )
        }

        let role = stats.durationMS < 1_500 ? "短片段待确认" : "临时声纹"
        let name = Self.isUnnamedVoiceName(recognized.name) ? nextPlaceholderName() : recognized.name
        let trackID = reservedTemporaryTrackIDsByName.removeValue(forKey: name)
            ?? (recognized.id == Self.zeroUUID ? UUID() : recognized.id)
        let track = Track(
            id: trackID,
            name: name,
            voiceprint: recognized.voiceprint.isEmpty ? "VP-CAM" : recognized.voiceprint,
            role: role,
            confidence: "--",
            centroid: recognized.embedding,
            hitCount: 1,
            lastSeenMS: stats.lastSeenMS,
            isRemembered: false
        )
        tracks[trackID] = track
        return Assignment(
            id: trackID,
            name: track.name,
            voiceprint: track.voiceprint,
            role: track.role,
            confidence: track.confidence,
            embedding: track.centroid,
            similarity: nil
        )
    }

    private func shouldUse(_ match: Match, stats: SegmentStats, assignedThisWindow: Set<UUID>) -> Bool {
        if match.score >= confirmedThreshold && match.margin >= ambiguousMargin {
            return true
        }
        guard match.score >= tentativeThreshold else { return false }
        guard !assignedThisWindow.contains(match.trackID) else {
            return match.score >= confirmedThreshold
        }
        if let track = tracks[match.trackID],
           !track.isRemembered,
           track.hitCount >= 1,
           (match.score >= 0.74 || match.margin >= 0.03) {
            return true
        }
        return stats.durationMS >= 2_500 && match.margin >= ambiguousMargin
    }

    private func nextPlaceholderName() -> String {
        defer { nextPlaceholderIndex += 1 }
        return "说话人\(nextPlaceholderIndex)"
    }

    private func bestMatch(for embedding: [Double]) -> Match? {
        var bestID: UUID?
        var bestScore = -1.0
        var secondScore = -1.0

        for track in tracks.values {
            guard track.centroid.count == embedding.count else { continue }
            let score = Self.cosineSimilarity(embedding, track.centroid)
            if score > bestScore {
                secondScore = bestScore
                bestScore = score
                bestID = track.id
            } else if score > secondScore {
                secondScore = score
            }
        }

        guard let bestID else { return nil }
        return Match(trackID: bestID, score: bestScore, secondScore: max(0, secondScore))
    }

    private func syncKnownSpeakerNames(_ speakers: [Speaker], rememberedSpeakerIDs: Set<UUID>) {
        for speaker in speakers {
            guard var track = tracks[speaker.id] else { continue }
            track.name = speaker.name
            track.voiceprint = speaker.voiceprint
            track.role = speaker.role
            track.confidence = speaker.confidence
            track.isRemembered = track.isRemembered || rememberedSpeakerIDs.contains(speaker.id)
            tracks[speaker.id] = track
        }
    }

    private func statsBySourceSpeaker(_ segments: [SpeakerDiarizationSegment]) -> [Int: SegmentStats] {
        var stats: [Int: SegmentStats] = [:]
        for segment in segments {
            let duration = max(0, segment.endMS - segment.startMS)
            var value = stats[segment.sourceSpk] ?? SegmentStats()
            value.durationMS += duration
            value.lastSeenMS = max(value.lastSeenMS, segment.endMS)
            stats[segment.sourceSpk] = value
        }
        return stats
    }

    private static func blend(old: [Double], new: [Double], newWeight: Double) -> [Double] {
        guard old.count == new.count else { return new }
        let oldWeight = 1.0 - newWeight
        return zip(old, new).map { oldValue, newValue in
            oldValue * oldWeight + newValue * newWeight
        }
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

    private static func percent(_ score: Double) -> String {
        "\(max(0, min(99, Int(round(score * 100)))))%"
    }

    private static func isUnnamedVoiceName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "未命名声纹"
            || normalized.hasPrefix("未命名声纹 ")
            || isPlaceholderSpeakerName(normalized)
    }

    private static func isPlaceholderSpeakerName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "说话人"
        guard normalized.hasPrefix(prefix) else { return false }
        let suffix = normalized.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
