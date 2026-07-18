/// Wire format the escalated helper prints on stdout, shared with the menu
/// bar app so both ends agree on the schema by construction.
///
/// Encoded with sorted keys:
///
///     {"log":[…],"mounted":[…],"results":{"fail":0,"ok":1,"skip":0},"targets":["disk4s1"]}
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
    /// Set when the helper failed before mounting anything (e.g. its scan
    /// threw). Carried in-band because the invoking app discards the helper's
    /// stderr — this is the only channel that survives the escalation.
    public var error: String?
    /// Timestamped console lines the helper recorded while scanning and
    /// mounting, carried in-band for the same reason as `error`. The app merges
    /// them into its live log for diagnostic reports.
    public var log: [String]

    public init(
        targets: [String], results: Counts = .init(), mounted: [MountedVolume] = [],
        error: String? = nil, log: [String] = []
    ) {
        self.targets = targets
        self.results = results
        self.mounted = mounted
        self.error = error
        self.log = log
    }
}
