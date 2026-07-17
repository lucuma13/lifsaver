import Foundation

/// Injectable output sink so callers (CLI, app, tests) decide where user-facing
/// text lands. Mirrors stdout/stderr by default.
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
