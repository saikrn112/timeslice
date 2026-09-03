import Foundation

/// A note written while using the app, on whichever device you happened to be holding.
///
/// Exists because the friction of "remember this, write it down later on the Mac" loses most of it.
/// Notes ride the same sync as everything else, so one jotted on the phone shows up wherever you
/// read them.
///
/// Deliberately not an interval: it has no duration and is never aggregated. A separate table keeps
/// it out of every time query rather than needing to be filtered out of all of them.
/// Which app a note is about.
///
/// A note written on the phone is very often about the Mac, and the reverse, so this can't be
/// inferred from `deviceID` — it has to be said. Three values rather than a free-form tag: the
/// only question being asked is who has to act on it.
public enum FeedbackPlatform: String, CaseIterable, Hashable, Sendable, Identifiable {
    case macOS = "macos"
    case iOS = "ios"
    case both = "both"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        case .both: return "Both"
        }
    }

    public var symbol: String {
        switch self {
        case .macOS: return "laptopcomputer"
        case .iOS: return "iphone"
        case .both: return "laptopcomputer.and.iphone"
        }
    }
}

public struct Feedback: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let text: String
    public let createdAt: Date
    /// Which device it was written on — "where was I when I thought this" is usually the context.
    public let deviceID: String?
    /// Set once it's been dealt with. Kept rather than deleted, so the list of what's been done
    /// survives; `deleteFeedback` exists for genuine mistakes.
    public let resolvedAt: Date?
    /// The number this note is CALLED, the same on every device — see the `seq` column. Distinct
    /// from `id`, which is a local row number and differs per device.
    public let seq: Int64
    /// Which app it's about. Optional because notes written before the tag existed have no answer,
    /// and guessing one from the device that wrote them would be wrong about half the time.
    public let platform: FeedbackPlatform?

    public var isOpen: Bool { resolvedAt == nil }

    public init(id: Int64, text: String, createdAt: Date, deviceID: String?, resolvedAt: Date?,
                platform: FeedbackPlatform? = nil, seq: Int64 = 0) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.resolvedAt = resolvedAt
        self.platform = platform
        self.seq = seq == 0 ? id : seq
    }

    /// First line, for a one-line list row.
    public var summary: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
