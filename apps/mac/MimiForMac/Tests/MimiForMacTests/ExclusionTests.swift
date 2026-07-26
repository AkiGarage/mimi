import XCTest
@testable import MimiForMac

final class ExclusionTests: XCTestCase {
    func testExclusionConfigurationDeduplicatesSelfAndHelpers() {
        let configuration = ProcessExclusionConfiguration(selfProcessID: 42, helperProcessIDs: [7, 42, 7])
        XCTAssertEqual(configuration.processIDs, [7, 42])
    }

    func testExclusionConfigurationResolvesProcessObjects() throws {
        let configuration = ProcessExclusionConfiguration(selfProcessID: 42, helperProcessIDs: [7])
        let resolver = FakeProcessObjectResolver(values: [7: 700, 42: 4200])
        let resolved = try configuration.resolve(using: resolver)
        XCTAssertEqual(resolved.processIDs, [7, 42])
        XCTAssertEqual(resolved.processObjectIDs, [700, 4200])
    }

    func testMissingProcessObjectFailsClosed() {
        let configuration = ProcessExclusionConfiguration(selfProcessID: 42)
        XCTAssertThrowsError(try configuration.resolve(using: FakeProcessObjectResolver(values: [:]))) { error in
            XCTAssertEqual(error as? CaptureError, .processNotFound(42))
        }
    }
}

private struct FakeProcessObjectResolver: ProcessObjectResolving {
    let values: [Int32: UInt32]

    func processObjectID(for processID: Int32) throws -> UInt32 {
        guard let value = values[processID] else { throw CaptureError.processNotFound(processID) }
        return value
    }
}
