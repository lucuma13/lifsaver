import Foundation
import Testing

@testable import LifsaverKit

// ===========================================================================
// Version
// ===========================================================================

@Suite struct VersionTests {
    @Test func versionIsANonEmptySemanticVersion() {
        #expect(!lifsaverVersion.isEmpty)
        #expect(SemanticVersion(lifsaverVersion) != nil)
    }
}
