/// Wire format the escalated helper prints on stdout, shared with the menu
/// bar app so both ends agree on the schema by construction.
///
/// Encoded with sorted keys:
///
///     {"mounted":[…],"results":{"fail":0,"ok":1,"skip":0},"targets":["disk4s1"]}
public struct MountReport: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable {
        public var ok: Int
        public var fail: Int
        public var skip: Int

        public init(ok: Int = 0, fail: Int = 0, skip: Int = 0) {
            self.ok = ok
            self.fail = fail
            self.skip = skip
        }
    }

    public struct MountedVolume: Codable, Sendable, Equatable {
        public var device: String
        public var mountPoint: String

        public init(device: String, mountPoint: String) {
            self.device = device
            self.mountPoint = mountPoint
        }
    }

    public var targets: [String]
    public var results: Counts
    public var mounted: [MountedVolume]

    public init(targets: [String], results: Counts = .init(), mounted: [MountedVolume] = []) {
        self.targets = targets
        self.results = results
        self.mounted = mounted
    }
}
