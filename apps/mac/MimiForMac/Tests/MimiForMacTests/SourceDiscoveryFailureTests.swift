import XCTest
@testable import MimiForMac

final class SourceDiscoveryFailureTests: XCTestCase {
    func testOnlyPermissionDeniedRequiresSystemSettings() {
        XCTAssertTrue(CaptureError.permissionDenied.requiresSystemSettings)
        XCTAssertFalse(CaptureError.backendUnavailable("temporary").requiresSystemSettings)
        XCTAssertFalse(CaptureError.system(-1).requiresSystemSettings)
        XCTAssertFalse(CaptureError.unknown("temporary").requiresSystemSettings)
    }
}
