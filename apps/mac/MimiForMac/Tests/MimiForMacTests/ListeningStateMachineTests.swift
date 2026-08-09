import XCTest
@testable import MimiForMac

final class ListeningStateMachineTests: XCTestCase {
    func testStartIsCoalescedAndStopIsIdempotent() async {
        let machine = ListeningStateMachine(isSetupComplete: true)
        await machine.selectSource()

        let first = await machine.start()
        let duplicate = await machine.start()
        XCTAssertEqual(first, duplicate)
        let connectingState = await machine.state
        XCTAssertEqual(connectingState, .connecting)

        let firstStop = await machine.stop()
        let duplicateStop = await machine.stop()
        XCTAssertTrue(firstStop)
        XCTAssertFalse(duplicateStop)
        await machine.stopped(generation: first!)
        let readyState = await machine.state
        XCTAssertEqual(readyState, .ready)
    }

    func testStaleCallbackCannotChangeNewSession() async {
        let machine = ListeningStateMachine(isSetupComplete: true)
        await machine.selectSource()
        let old = await machine.start()!
        _ = await machine.stop()
        await machine.stopped(generation: old)
        let current = await machine.start()!

        XCTAssertNotEqual(old, current)
        let acceptedStale = await machine.connected(generation: old)
        let stateAfterStale = await machine.state
        let acceptedCurrent = await machine.connected(generation: current)
        let stateAfterCurrent = await machine.state
        XCTAssertFalse(acceptedStale)
        XCTAssertEqual(stateAfterStale, .connecting)
        XCTAssertTrue(acceptedCurrent)
        XCTAssertEqual(stateAfterCurrent, .listening)
    }

    func testTerminalStateRequiresCurrentGeneration() async {
        let machine = ListeningStateMachine(isSetupComplete: true)
        await machine.selectSource()
        let generation = await machine.start()!

        await machine.terminate(generation: generation + 1, as: .paidLimitReached)
        let stateAfterStale = await machine.state
        XCTAssertEqual(stateAfterStale, .connecting)
        await machine.terminate(generation: generation, as: .paidLimitReached)
        let terminalState = await machine.state
        XCTAssertEqual(terminalState, .paidLimitReached)
    }
}
