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
        var seenInCurrentMeeting: Bool
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
    private let ambiguousMargin = 0.05
    private let meetingTrackThreshold = 0.74
    private let meetingTrackStrongThreshold = 0.78
    private let meetingTrackSameWindowThreshold = 0.82
    private let meetingTrackShortSegmentThreshold = 0.80
    private let meetingTrackAmbiguousMargin = 0.02
    private let rememberedStrongThreshold = 0.84
    private let softMeetingSpeakerLimit = 6
    private let softMeetingMergeThreshold = 0.68
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
                isRemembered: true,
                seenInCurrentMeeting: false
            )
        }
    }

    func reserveTemporarySpeaker(_ speaker: Speaker) {
        guard Self.isPlaceholderSpeakerName(speaker.name) else { return }
        reservedTemporaryTrackIDsByName[speaker.name] = speaker.id
    }

    func remember(speaker: Speaker, embedding: [Double]) {
        guard !embedding.isEmpty else { return }
        let existing = tracks[speaker.id]
        tracks[speaker.id] = Track(
            id: speaker.id,
            name: speaker.name,
            voiceprint: speaker.voiceprint,
            role: speaker.role,
            confidence: speaker.confidence,
            centroid: embedding,
            hitCount: max(existing?.hitCount ?? 0, promotionHitCount),
            lastSeenMS: existing?.lastSeenMS ?? 0,
            isRemembered: true,
            seenInCurrentMeeting: existing?.seenInCurrentMeeting ?? false
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
            target.seenInCurrentMeeting = target.seenInCurrentMeeting || source.seenInCurrentMeeting
        }
        tracks[targetID] = target
        tracks.removeValue(forKey: sourceID)
    }

    func reconcile(
        _ result: SpeakerDiarizationResult,
        knownSpeakers: [Speaker],
        rememberedSpeakerIDs: Set<UUID>,
        meetingSpeakerIDs: Set<UUID>
    ) -> SpeakerDiarizationResult {
        syncKnownSpeakerNames(knownSpeakers, rememberedSpeakerIDs: rememberedSpeakerIDs)
        markSeenInCurrentMeeting(meetingSpeakerIDs)

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

        if let meetingMatch = bestMatch(for: recognized.embedding, include: { isMeetingTrack($0) }),
           shouldUseMeetingTrack(meetingMatch, stats: stats, assignedThisWindow: assignedThisWindow),
           let assignment = updateTrack(meetingMatch.trackID, with: recognized, stats: stats, similarity: meetingMatch.score) {
            return assignment
        }

        if let rememberedMatch = bestMatch(for: recognized.embedding, include: { !$0.seenInCurrentMeeting && $0.isRemembered }),
           shouldUseRememberedTrack(rememberedMatch, stats: stats, assignedThisWindow: assignedThisWindow),
           let assignment = updateTrack(rememberedMatch.trackID, with: recognized, stats: stats, similarity: rememberedMatch.score) {
            return assignment
        }

        if let meetingMatch = bestMatch(for: recognized.embedding, include: { isMeetingTrack($0) }),
           shouldMergeBecauseMeetingIsCrowded(meetingMatch, stats: stats, assignedThisWindow: assignedThisWindow),
           let assignment = updateTrack(meetingMatch.trackID, with: recognized, stats: stats, similarity: meetingMatch.score) {
            return assignment
        }

        let role = stats.durationMS < 1_500 ? "短片段待确认" : "临时声纹"
        let name = shouldUseNameForNewTrack(recognized) ? recognized.name : nextPlaceholderName()
        let trackID = reservedTemporaryTrackIDsByName.removeValue(forKey: name)
            ?? reusableID(from: recognized)
        let track = Track(
            id: trackID,
            name: name,
            voiceprint: recognized.voiceprint.isEmpty ? "VP-CAM" : recognized.voiceprint,
            role: role,
            confidence: "--",
            centroid: recognized.embedding,
            hitCount: 1,
            lastSeenMS: stats.lastSeenMS,
            isRemembered: false,
            seenInCurrentMeeting: true
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

    private func updateTrack(
        _ trackID: UUID,
        with recognized: RecognizedSpeaker,
        stats: SegmentStats,
        similarity: Double
    ) -> Assignment? {
        guard var track = tracks[trackID] else { return nil }
        let newWeight = track.isRemembered ? 0.18 : 0.35
        track.centroid = Self.blend(old: track.centroid, new: recognized.embedding, newWeight: newWeight)
        track.hitCount += 1
        track.lastSeenMS = max(track.lastSeenMS, stats.lastSeenMS)
        track.seenInCurrentMeeting = true
        if !track.isRemembered && track.hitCount >= promotionHitCount {
            track.role = "临时稳定声纹"
        }
        track.confidence = Self.percent(similarity)
        tracks[track.id] = track
        return Assignment(
            id: track.id,
            name: track.name,
            voiceprint: track.voiceprint,
            role: track.role,
            confidence: track.confidence,
            embedding: track.centroid,
            similarity: similarity
        )
    }

    private func shouldUseMeetingTrack(_ match: Match, stats: SegmentStats, assignedThisWindow: Set<UUID>) -> Bool {
        guard let track = tracks[match.trackID], isMeetingTrack(track) else { return false }
        if assignedThisWindow.contains(match.trackID) {
            return match.score >= meetingTrackSameWindowThreshold
        }
        if stats.durationMS > 0 && stats.durationMS < 1_500 {
            return match.score >= meetingTrackShortSegmentThreshold
        }
        if match.score >= meetingTrackStrongThreshold {
            return true
        }
        guard match.score >= meetingTrackThreshold else { return false }
        if match.margin >= meetingTrackAmbiguousMargin {
            return true
        }
        if !track.isRemembered && track.hitCount >= promotionHitCount && stats.durationMS >= 2_000 {
            return true
        }
        return false
    }

    private func shouldUseRememberedTrack(_ match: Match, stats: SegmentStats, assignedThisWindow: Set<UUID>) -> Bool {
        guard tracks[match.trackID]?.isRemembered == true else { return false }
        if assignedThisWindow.contains(match.trackID) {
            return match.score >= rememberedStrongThreshold
        }
        if match.score >= rememberedStrongThreshold {
            return true
        }
        let hasCompetingTrack = match.secondScore > 0
        return hasCompetingTrack
            && stats.durationMS >= 2_500
            && match.score >= confirmedThreshold
            && match.margin >= ambiguousMargin
    }

    private func shouldMergeBecauseMeetingIsCrowded(
        _ match: Match,
        stats: SegmentStats,
        assignedThisWindow: Set<UUID>
    ) -> Bool {
        guard meetingTrackCount >= softMeetingSpeakerLimit else { return false }
        guard stats.durationMS >= 1_000 else { return false }
        if assignedThisWindow.contains(match.trackID) {
            return match.score >= confirmedThreshold
        }
        return match.score >= softMeetingMergeThreshold
    }

    private func nextPlaceholderName() -> String {
        defer { nextPlaceholderIndex += 1 }
        return "说话人\(nextPlaceholderIndex)"
    }

    private func reusableID(from recognized: RecognizedSpeaker) -> UUID {
        if recognized.id == Self.zeroUUID {
            return UUID()
        }
        if tracks[recognized.id] != nil {
            return UUID()
        }
        return recognized.id
    }

    private func shouldUseNameForNewTrack(_ recognized: RecognizedSpeaker) -> Bool {
        guard !Self.isUnnamedVoiceName(recognized.name) else { return false }
        return tracks[recognized.id] == nil
    }

    private var meetingTrackCount: Int {
        tracks.values.filter { isMeetingTrack($0) }.count
    }

    private func isMeetingTrack(_ track: Track) -> Bool {
        track.seenInCurrentMeeting || !track.isRemembered
    }

    private func bestMatch(for embedding: [Double], include: (Track) -> Bool) -> Match? {
        var bestID: UUID?
        var bestScore = -1.0
        var secondScore = -1.0

        for track in tracks.values {
            guard include(track) else { continue }
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

    private func markSeenInCurrentMeeting(_ speakerIDs: Set<UUID>) {
        guard !speakerIDs.isEmpty else { return }
        for speakerID in speakerIDs {
            guard var track = tracks[speakerID] else { continue }
            track.seenInCurrentMeeting = true
            tracks[speakerID] = track
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
