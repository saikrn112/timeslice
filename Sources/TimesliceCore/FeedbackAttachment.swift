import Foundation

/// An image pasted onto a piece of feedback.
///
/// A screenshot says in one glance what a sentence spends three lines failing to describe, so the
/// point of this is speed of *entry* — paste and move on.
///
/// The bytes are NOT in the database. Screenshots are hundreds of kilobytes and the sync payload is
/// rewritten in full on every publish; a few of them embedded there would mean re-uploading
/// megabytes every thirty seconds. Each image is its own file locally and its own blob on the
/// transport, fetched once and cached. This row is the part that's small enough to travel in the
/// payload: it tells a peer that an image exists and what to go and get.
public struct FeedbackAttachment: Identifiable, Hashable, Sendable {
    public let id: Int64
    /// The note this belongs to, by uid — a row id means a different note on another device.
    public let feedbackUID: String
    /// Stable name for the blob and the local file.
    public let uid: String
    public let filename: String
    public let byteSize: Int
    public let createdAt: Date
    /// False until the bytes have arrived from a peer. The row syncs before the image does, so a
    /// note can legitimately know about a picture this device hasn't downloaded yet.
    public let hasLocalFile: Bool

    public init(id: Int64, feedbackUID: String, uid: String, filename: String, byteSize: Int,
                createdAt: Date, hasLocalFile: Bool) {
        self.id = id
        self.feedbackUID = feedbackUID
        self.uid = uid
        self.filename = filename
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.hasLocalFile = hasLocalFile
    }

    /// What the blob is called on the transport. Derived from the uid rather than the user-facing
    /// filename, which isn't unique and can contain anything.
    public var blobName: String { "attachment-\(uid).png" }
}
