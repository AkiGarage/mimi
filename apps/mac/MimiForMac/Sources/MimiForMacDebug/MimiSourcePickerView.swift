import AppKit
import MimiForMac
import SwiftUI

struct MimiSourcePickerView: View {
    @ObservedObject var model: MimiForMacViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var searchText = ""

    private var catalog: AudioSourceCatalog { AudioSourceCatalog(sources: model.sources) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 620)
        .frame(minHeight: 540, idealHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localized(.sourcePickerTitle))
                    .font(.title2.weight(.semibold))
                Text(localized(.sourcePickerSubtitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(localized(.commonClose)) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingSources {
            ProgressView(localized(.sourcePickerSearching))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if catalog.recommendedGroups.isEmpty && catalog.otherGroups.isEmpty {
            ContentUnavailableView(
                localized(.sourcePickerEmptyTitle),
                systemImage: "play.rectangle.on.rectangle",
                description: Text(localized(.sourcePickerEmptyMessage))
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    guidanceCard
                    sourceSections
                }
                .padding(24)
            }
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: localized(.sourcePickerSearchPrompt)
            )
        }
    }

    private var guidanceCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized(.sourcePickerGuidanceTitle))
                    .font(.subheadline.weight(.semibold))
                Text(localized(.sourcePickerGuidanceMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var sourceSections: some View {
        let matchingRecommended = matching(catalog.recommendedGroups)
        let matchingOthers = matching(catalog.otherGroups)

        if !matchingRecommended.isEmpty {
            sourceSection(localized(.sourcePickerRecommended), groups: matchingRecommended)
        }
        if !matchingOthers.isEmpty {
            sourceSection(
                searchText.isEmpty
                    ? localized(.sourcePickerOthers)
                    : localized(.sourcePickerResults),
                groups: matchingOthers
            )
        }
        if matchingRecommended.isEmpty && matchingOthers.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func sourceSection(_ title: String, groups: [AudioSourceGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(groups) { group in
                SourceApplicationCard(
                    group: group,
                    selectedID: model.selectedSource?.id,
                    onSelect: select
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(localized(.sourcePickerOpenSettings)) { model.openSystemAudioSettings() }
                .buttonStyle(.borderless)
        }
    }

    private func matching(_ groups: [AudioSourceGroup]) -> [AudioSourceGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.application.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private func select(_ source: AudioSource) {
        model.selectSource(source)
        dismiss()
    }

    private func localized(_ key: MimiLocalizationKey) -> String {
        MimiLocalization.string(key, locale: locale)
    }
}

private struct SourceApplicationCard: View {
    let group: AudioSourceGroup
    let selectedID: String?
    let onSelect: (AudioSource) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            Button { onSelect(group.application) } label: {
                HStack(spacing: 12) {
                    applicationIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.application.displayName)
                            .font(.body.weight(.medium))
                        Text(localized(.sourcePickerApplicationSubtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    selectionMark(group.application)
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)

        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let processID = group.application.processID,
           let image = NSRunningApplication(processIdentifier: processID)?.icon {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: "app.fill")
                .font(.title2)
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func selectionMark(_ source: AudioSource) -> some View {
        if selectedID == source.id {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel(localized(.sourcePickerSelected))
        } else {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func localized(_ key: MimiLocalizationKey) -> String {
        MimiLocalization.string(key, locale: locale)
    }
}
