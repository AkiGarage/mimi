import Darwin
import AppKit
import Foundation
import MimiAppCore
import SwiftUI

@main
struct MimiSetupApp: App {
    init() {
        if CommandLine.arguments.contains("--save-api-key-stdin") {
            runSaveAPIKeyFromStdin()
            exit(0)
        }
        if CommandLine.arguments.contains("--bundle-smoke-check") {
            runBundleSmokeCheck()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Mimi Setup for Chrome") {
            ContentView()
                .frame(minWidth: 860, minHeight: 620)
                .background(SetupWindowPlacementObserver())
        }
        .windowStyle(.titleBar)
    }
}

private struct SetupWindowPlacementObserver: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator(placement: SetupWindowPlacement())
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    final class Coordinator {
        private let placement: SetupWindowPlacement
        private weak var window: NSWindow?
        private var didApplyInitialPlacement = false
        private var isApplyingPlacement = false
        private var moveObserver: NSObjectProtocol?

        init(placement: SetupWindowPlacement) {
            self.placement = placement
        }

        deinit {
            if let moveObserver {
                NotificationCenter.default.removeObserver(moveObserver)
            }
        }

        func attach(to candidate: NSWindow?) {
            guard let candidate else {
                return
            }
            if window !== candidate {
                if let moveObserver {
                    NotificationCenter.default.removeObserver(moveObserver)
                }
                window = candidate
                didApplyInitialPlacement = false
                moveObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: candidate,
                    queue: .main
                ) { [weak self] _ in
                    self?.saveUserAdjustedPosition()
                }
            }
            applyInitialPlacementIfNeeded(to: candidate)
        }

        private func applyInitialPlacementIfNeeded(to window: NSWindow) {
            guard !didApplyInitialPlacement else {
                return
            }
            didApplyInitialPlacement = true
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let origin = placement.preferredOrigin(windowSize: window.frame.size, visibleFrame: visibleFrame)
            isApplyingPlacement = true
            window.setFrameOrigin(origin)
            isApplyingPlacement = false
        }

        private func saveUserAdjustedPosition() {
            guard !isApplyingPlacement, let window else {
                return
            }
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let origin = SetupWindowPlacement.clamped(
                origin: window.frame.origin,
                windowSize: window.frame.size,
                visibleFrame: visibleFrame
            )
            placement.save(origin: origin)
        }
    }
}

private func runBundleSmokeCheck() {
    guard let resourceURL = Bundle.main.resourceURL else {
        print("FAIL missing_resource_url")
        exit(1)
    }
    let fileManager = FileManager.default
    let required = [
        "node/bin/node",
        "local-server/package.json",
        "local-server/node_modules/ws/package.json",
        "native-host/package.json",
        "shared/extensionOrigin.cjs",
        "extension/manifest.json",
        "extension/icons/icon-128.png",
        "MimiSetupChromeIcon.png",
        "MimiAppIcon.icns"
    ]
    let missing = required.filter {
        !fileManager.fileExists(atPath: resourceURL.appendingPathComponent($0).path)
    }
    guard missing.isEmpty else {
        print("FAIL missing_bundle_resources \(missing.joined(separator: ","))")
        exit(1)
    }
    let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
    guard iconFile == "MimiAppIcon" else {
        print("FAIL invalid_bundle_icon_file \(iconFile ?? "missing")")
        exit(1)
    }
    print("PASS mimi_bundle_smoke_check")
}

private func runSaveAPIKeyFromStdin() {
    let arguments = CommandLine.arguments
    let flagIndex = arguments.firstIndex(of: "--save-api-key-stdin") ?? 0
    let service = arguments.dropFirst(flagIndex + 1).first ?? KeychainWriter.defaultService
    let account = arguments.dropFirst(flagIndex + 2).first ?? KeychainWriter.defaultAccount
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let password = String(data: input, encoding: .utf8) else {
        print("FAIL invalid_password_encoding")
        exit(65)
    }
    do {
        try KeychainWriter(service: service, account: account).save(password)
        print("PASS keychain_saved")
    } catch {
        print("FAIL keychain_save_failed \(error.localizedDescription)")
        exit(1)
    }
}
