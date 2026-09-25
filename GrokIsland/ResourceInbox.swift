import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// Session inbox of dropped resource *references* (paths / URLs / bookmarks).
///
/// Public API: `ingest` / `remove(id:)` / `clear` / `snapshot`.
@MainActor
final class ResourceInbox: ObservableObject {
    @Published private(set) var items: [ResourceItem] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    func ingest(_ incoming: [ResourceItem]) {
        guard !incoming.isEmpty else { return }
        var seen = Set(items.map(\.location))
        for item in incoming {
            let key = item.location
            if seen.contains(key) { continue }
            seen.insert(key)
            items.append(item)
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
    }

    func snapshot() -> [ResourceItem] {
        items
    }
}
