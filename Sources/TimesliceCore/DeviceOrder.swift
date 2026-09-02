import Foundation

/// The single answer to "in what order do devices appear?".
///
/// Exists because the day timeline's lanes and the sync panel's device list were each sorting for
/// themselves, and two independently-correct sorts still don't agree. Both now ask this, so a
/// device sits in the same position in both places.
///
/// Ordered by the LABEL you gave the device, not its id. Sorting by id was stable, which fixed
/// lanes shuffling between syncs, but the key is a uuid: the resulting order is unrelated to
/// anything on screen, so it reads as arbitrary. The id stays as the tie-break, so two devices
/// sharing a name — or having none — still can't swap places.
public enum DeviceOrder {

    /// Sort key: label if there is one, else the id, and the id to break ties.
    public static func key(id: String, label: String?) -> (String, String) {
        let name = (label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        }
        return ((name ?? id).lowercased(), id)
    }

    /// Device ids in display order.
    public static func sorted(_ devices: [(id: String, label: String?)]) -> [String] {
        devices.sorted { key(id: $0.id, label: $0.label) < key(id: $1.id, label: $1.label) }
            .map(\.id)
    }
}
