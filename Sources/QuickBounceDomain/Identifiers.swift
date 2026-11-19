import Foundation

public struct SessionIdentity: Codable, Hashable, Sendable {
    public var path: String
    public var originID: String
    public var instanceID: String
    public var parentID: String?
    public var proToolsVersion: String
    public var ptslVersion: String

    public init(
        path: String,
        originID: String,
        instanceID: String,
        parentID: String? = nil,
        proToolsVersion: String,
        ptslVersion: String
    ) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.originID = originID
        self.instanceID = instanceID
        self.parentID = parentID
        self.proToolsVersion = proToolsVersion
        self.ptslVersion = ptslVersion
    }
}

public struct TrackReference: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var index: Int
    public var kind: String
    public var parentFolderID: String?

    public init(id: String, name: String, index: Int, kind: String, parentFolderID: String? = nil) {
        self.id = id
        self.name = name
        self.index = index
        self.kind = kind
        self.parentFolderID = parentFolderID
    }
}

public struct TrackState: Codable, Hashable, Sendable {
    public var track: TrackReference
    public var isSolo: Bool
    public var isMuted: Bool
    /// Optional so older saved Session Settings continue to decode.
    public var isInactive: Bool?

    public init(track: TrackReference, isSolo: Bool, isMuted: Bool, isInactive: Bool? = nil) {
        self.track = track
        self.isSolo = isSolo
        self.isMuted = isMuted
        self.isInactive = isInactive
    }
}

public struct SampleRange: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var length: Int64 { max(0, end - start) }
    public var isValid: Bool { start >= 0 && end > start }
}
