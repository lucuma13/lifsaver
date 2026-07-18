import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// KernelMountTable (real getmntinfo — read-only, safe in CI)
// ===========================================================================

@Suite struct KernelMountTableTests {
    @Test func liveTableContainsRootFilesystem() throws {
        let entries = try KernelMountTable().entries()
        #expect(entries.contains { $0.mountPoint == "/" })
        #expect(entries.contains { $0.device.hasPrefix("/dev/disk") })
    }
}
