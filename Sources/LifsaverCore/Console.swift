import Foundation

/// Injectable output sink so callers decide where diagnostic text lands: the
/// app routes it to its log, diagnostic reports capture it, and the root
/// helper sends it to stderr. `.standard` mirrors stdout/stderr for tests and
/// bare `swift run` development.
public struct Console: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static let standard = Console(
        out: { print($0) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
}
