/// Wire format of the CLI's `--json` output, shared with the menu bar app so
/// both ends agree on the schema by construction.
///
/// Encoded with sorted keys and nil fields omitted:
///
///     {"action":"scan","targets":["disk4s1"]}
///     {"action":"mount","mounted":[…],"results":{"fail":0,"ok":1,"skip":0},"targets":["disk4s1"]}
public struct CLIReport: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case scan
        case mount
    }

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

    public var action: Action
    public var targets: [String]
    /// Present for `action == .mount` only.
    public var results: Counts?
    /// Present for `action == .mount` only.
    public var mounted: [MountedVolume]?

    public init(action: Action, targets: [String], results: Counts? = nil, mounted: [MountedVolume]? = nil) {
        self.action = action
        self.targets = targets
        self.results = results
        self.mounted = mounted
    }
}
