import Foundation
import MimiForMac
import SwiftUI

struct MimiForMacDebugApp: App {
    @StateObject private var model = MimiForMacViewModel()
    @AppStorage(MimiDisplayLanguage.storageKey) private var displayLanguageRawValue =
        MimiDisplayLanguage.defaultValue.rawValue

    private var interfaceLocale: Locale {
        let macLanguage = Bundle.main.preferredLocalizations.first
            ?? Locale.autoupdatingCurrent.identifier
        return MimiDisplayLanguage
            .normalized(displayLanguageRawValue)
            .locale(systemIdentifier: macLanguage)
    }

    var body: some Scene {
        WindowGroup("Mimi for Mac", id: "main") {
            MimiMainView(model: model)
                .environment(\.locale, interfaceLocale)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MimiMenuBarView(model: model, locale: interfaceLocale)
                .environment(\.locale, interfaceLocale)
        } label: {
            MimiMenuBarLabel(state: model.state, locale: interfaceLocale)
                .environment(\.locale, interfaceLocale)
        }
        .menuBarExtraStyle(.menu)
    }
}

MimiForMacDebugApp.main()
