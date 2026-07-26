import XCTest
@testable import MimiForMac

final class AudioSourceCatalogTests: XCTestCase {
    func testCatalogReturnsVisibleWindowsForApplicationAsContextOnly() {
        let application = AudioSource(
            id: "pid:42",
            displayName: "QuickTime Player",
            kind: .application,
            processID: 42,
            bundleIdentifier: "com.apple.QuickTimePlayerX"
        )
        let lecture = AudioSource(
            id: "window:101",
            displayName: "Lecture.mov",
            kind: .window,
            processID: 42,
            windowID: 101,
            bundleIdentifier: "com.apple.QuickTimePlayerX"
        )
        let concert = AudioSource(
            id: "window:102",
            displayName: "Concert.mov",
            kind: .window,
            processID: 42,
            windowID: 102,
            bundleIdentifier: "com.apple.QuickTimePlayerX"
        )

        let catalog = AudioSourceCatalog(sources: [application, concert, lecture])

        XCTAssertEqual(catalog.windows(for: application), [concert, lecture])
        XCTAssertTrue(application.isBrowserApplication == false)
    }

    func testGroupsWindowsUnderTheirApplicationAndRanksListeningAppsFirst() throws {
        let notes = AudioSource(
            id: "pid:30",
            displayName: "Notes",
            kind: .application,
            processID: 30,
            bundleIdentifier: "com.apple.Notes"
        )
        let chrome = AudioSource(
            id: "pid:20",
            displayName: "Google Chrome",
            kind: .application,
            processID: 20,
            bundleIdentifier: "com.google.Chrome"
        )
        let safari = AudioSource(
            id: "pid:10",
            displayName: "Safari",
            kind: .application,
            processID: 10,
            bundleIdentifier: "com.apple.Safari"
        )
        let secondWindow = AudioSource(
            id: "window:102",
            displayName: "Podcast episode",
            kind: .window,
            processID: 10,
            windowID: 102,
            bundleIdentifier: "com.apple.Safari"
        )
        let firstWindow = AudioSource(
            id: "window:101",
            displayName: "Documentary",
            kind: .window,
            processID: 10,
            windowID: 101,
            bundleIdentifier: "com.apple.Safari"
        )

        let catalog = AudioSourceCatalog(sources: [notes, secondWindow, chrome, safari, firstWindow, .system])

        XCTAssertEqual(catalog.recommendedGroups.map(\.application.id), ["pid:10", "pid:20"])
        XCTAssertEqual(catalog.otherGroups.map(\.application.id), ["pid:30"])
        XCTAssertEqual(catalog.recommendedGroups[0].windows.map(\.id), ["window:101", "window:102"])
        XCTAssertEqual(catalog.systemSource, .system)
    }

    func testWindowChoiceExplainsBrowserTabBoundaryAndOriginalVolumeCapability() {
        let browserWindow = AudioSource(
            id: "window:101",
            displayName: "A video",
            kind: .window,
            processID: 10,
            windowID: 101,
            bundleIdentifier: "com.apple.Safari"
        )
        let browserApp = AudioSource(
            id: "pid:10",
            displayName: "Safari",
            kind: .application,
            processID: 10,
            bundleIdentifier: "com.apple.Safari"
        )

        XCTAssertTrue(browserWindow.isBrowserWindow)
        XCTAssertTrue(browserApp.isBrowserApplication)
        XCTAssertFalse(browserWindow.supportsOriginalVolumeControl)
        XCTAssertTrue(browserApp.supportsOriginalVolumeControl)
    }

    func testCatalogResolvesWindowToItsControllableApplicationSource() {
        let safari = AudioSource(
            id: "pid:10",
            displayName: "Safari",
            kind: .application,
            processID: 10,
            bundleIdentifier: "com.apple.Safari"
        )
        let safariWindow = AudioSource(
            id: "window:101",
            displayName: "A video",
            kind: .window,
            processID: 10,
            windowID: 101,
            bundleIdentifier: "com.apple.Safari"
        )
        let catalog = AudioSourceCatalog(sources: [safari, safariWindow, .system])

        XCTAssertEqual(catalog.originalVolumeControllableSource(for: safariWindow), safari)
        XCTAssertEqual(catalog.originalVolumeControllableSource(for: safari), safari)
        XCTAssertEqual(catalog.originalVolumeControllableSource(for: .system), .system)
    }
}
