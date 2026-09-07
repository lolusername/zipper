import Foundation

/// Legacy JSON discarded fractional seconds, while its text formatter could round up.
/// Permit that one lost bit of historical timing evidence only at timestamp positions;
/// every filename, hash, event message, delimiter, and other byte must still agree.
enum ReportEvidence {
    static func matchesHuman(_ data: Data, job: JobRecord) -> Bool {
        let expected = Data(JobEngine.humanReport(job).utf8)
        if data == expected { return true }
        guard isLegacy(job) else { return false }
        var slots: [(Range<Int>, Data)] = []
        for (label, date) in [("\nCreated: ", Optional(job.createdAt)), ("\nCompleted: ", job.completedAt)] {
            guard let date, let marker = expected.range(of: Data(label.utf8)) else { continue }
            let length = timestamp(date).count
            slots.append((marker.upperBound..<(marker.upperBound + length), timestamp(date.addingTimeInterval(1))))
        }
        return matches(data, expected: expected, slots: slots)
    }

    static func matchesLog(_ data: Data, job: JobRecord) -> Bool {
        let expected = Data(JobEngine.logReport(job).utf8)
        if data == expected { return true }
        guard isLegacy(job) else { return false }
        var offset = 0
        var slots: [(Range<Int>, Data)] = []
        for event in job.events {
            let length = timestamp(event.timestamp).count
            slots.append((offset..<(offset + length), timestamp(event.timestamp.addingTimeInterval(1))))
            offset += length + 2 + event.message.utf8.count + 1
        }
        return matches(data, expected: expected, slots: slots)
    }

    private static func isLegacy(_ job: JobRecord) -> Bool { ["1.0.0", "1.0.1"].contains(job.applicationVersion) }
    private static func timestamp(_ date: Date) -> Data { Data(ISO8601DateFormatter().string(from: date).utf8) }

    private static func matches(_ data: Data, expected: Data, slots: [(Range<Int>, Data)]) -> Bool {
        var expectedOffset = 0, actualOffset = 0
        func consume(_ bytes: Data.SubSequence) -> Bool {
            guard bytes.count <= data.count - actualOffset,
                  data[actualOffset..<(actualOffset + bytes.count)] == bytes else { return false }
            actualOffset += bytes.count
            return true
        }
        for (range, roundedUp) in slots {
            guard range.lowerBound >= expectedOffset, range.upperBound <= expected.count,
                  consume(expected[expectedOffset..<range.lowerBound]) else { return false }
            guard consume(expected[range]) || consume(roundedUp[...]) else { return false }
            expectedOffset = range.upperBound
        }
        return consume(expected[expectedOffset...]) && actualOffset == data.count
    }
}
