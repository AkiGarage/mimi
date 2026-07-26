import AppKit
import Foundation
import MimiForMac
import SwiftUI

struct MimiMenuBarLabel: View {
    let state: MimiUIState
    let locale: Locale

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = MimiMenuBarPresentationPolicy.presentation(
            for: state,
            locale: locale
        )
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 12.0,
                paused: !presentation.shouldPulse || reduceMotion
            )
        ) { context in
            HStack(spacing: 4) {
                Image(systemName: presentation.symbolName)
                    .opacity(MimiMenuBarPulsePolicy.opacity(
                        elapsed: context.date.timeIntervalSinceReferenceDate,
                        shouldPulse: presentation.shouldPulse,
                        reduceMotion: reduceMotion
                    ))
                Text("Mimi")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mimi for Mac")
            .accessibilityValue(presentation.title)
        }
    }
}

struct MimiMenuBarView: View {
    @ObservedObject var model: MimiForMacViewModel
    let locale: Locale

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = MimiMenuBarPresentationPolicy.presentation(
            for: model.state,
            locale: locale
        )

        Label(presentation.title, systemImage: presentation.symbolName)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MimiLocalization.string(.statusAccessibility, locale: locale))
            .accessibilityValue(presentation.title)

        Text(presentation.value)

        Divider()

        Button {
            perform(.openWindow)
        } label: {
            Label(
                MimiLocalization.string(.menuBarOpenWindow, locale: locale),
                systemImage: "macwindow"
            )
        }

        Button {
            perform(.primaryAction)
        } label: {
            Label(
                model.primaryActionTitle(locale: locale),
                systemImage: primaryActionSymbol
            )
        }
        .disabled(model.state == .detectingSource || model.state == .stopping)

        Button {
            perform(.settings)
        } label: {
            Label(
                MimiLocalization.string(.settingsTitle, locale: locale),
                systemImage: "gearshape"
            )
        }

        Divider()

        Button {
            perform(.quit)
        } label: {
            Text(MimiLocalization.string(.menuBarQuit, locale: locale))
        }
    }

    private var primaryActionSymbol: String {
        switch model.state {
        case .connecting, .listening, .reconnecting: "stop.fill"
        default: "play.fill"
        }
    }

    private func perform(_ command: MimiMenuBarCommand) {
        let router = MimiMenuBarCommandRouter(
            openWindow: { showMainWindow() },
            performPrimaryAction: { model.performPrimaryAction() },
            showSettings: {
                model.isSettingsPresented = true
                showMainWindow()
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
        router.perform(command)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
