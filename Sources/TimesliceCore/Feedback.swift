import Foundation

/// A note written while using the app, on whichever device you happened to be holding.
///
/// Exists because the friction of "remember this, write it down later on the Mac" loses most of it.
/// Notes ride the same sync as everything else, so one jotted on the phone shows up wherever you
/// read them.
///
/// Deliberately not an interval: it has no duration and is never aggregated. A separate table keeps
/// it out of every time query rather than needing to be filtered out of all of them.
public struct Feedback: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let text: String
    public let createdAt: Date
    /// Which device it was written on — "where was I when I thought this" is usually the context.
    public let deviceID: String?
    /// Set once it's been dealt with. Kept rather than deleted, so the list of what's been done
    /// survives; `deleteFeedback` exists for genuine mistakes.
    public let resolvedAt: Date?

    public var isOpen: Bool { resolvedAt == nil }

    public init(id: Int64, text: String, createdAt: Date, deviceID: String?, resolvedAt: Date?) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.resolvedAt = resolvedAt
    }

    /// First line, for a one-line list row.
    public var summary: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
