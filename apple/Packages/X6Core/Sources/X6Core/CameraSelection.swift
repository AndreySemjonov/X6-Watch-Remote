import Foundation

public struct CameraCandidate: Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Input contains only devices advertising the camera service. A saved identity
/// always wins; discovery must never silently replace a missing saved camera.
public enum CameraSelection {
    public static func automaticID(saved: UUID?, candidates: [CameraCandidate]) -> UUID? {
        if let saved { return candidates.contains { $0.id == saved } ? saved : nil }
        let ids = Set(candidates.map(\.id))
        guard ids.count == 1, let candidate = candidates.first else { return nil }
        let words = candidate.name.uppercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains("X6") ? candidate.id : nil
    }
}
