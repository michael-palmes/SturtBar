// SettingsView.swift — single-pane settings form (Phase 4b).
//
// Row/section styling salvaged from legacy PreferencesComponents.swift (PreferenceToggleRow /
// SettingsSection) and the General/Display pane structures, collapsed into ONE pane — the
// rebuild has no tabs, no SwiftUI Settings scene and no localization layer (literals). The
// quota-warning block trims legacy QuotaWarningSettingsViews.swift to the global (per-window)
// shape of the rebuild's SettingsStore: per-provider overrides died with the providers.
//
// Every control binds straight to SettingsStore (@Observable; didSet persists to UserDefaults),
// except Launch at Login, where SMAppService is the source of truth (see LaunchAtLoginManager).

import AppKit
import SturtBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var launchAtLogin = LaunchAtLoginManager.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.generalSection
            Divider()
            self.menuBarSection
            Divider()
            self.displaySection
            Divider()
            self.costSection
            Divider()
            self.notificationsSection
        }
        .frame(width: 460, alignment: .leading)
        .padding(20)
        .onAppear { self.launchAtLogin = LaunchAtLoginManager.isEnabled }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection(title: "General") {
            PreferenceToggleRow(
                title: "Launch at login",
                subtitle: "Start SturtBar automatically when you log in.",
                isOn: Binding(
                    get: { self.launchAtLogin },
                    set: { enabled in
                        LaunchAtLoginManager.setEnabled(enabled)
                        // SMAppService can refuse (e.g. `swift run` outside an app bundle);
                        // reflect the actual registration state back into the toggle.
                        self.launchAtLogin = LaunchAtLoginManager.isEnabled
                    }))

            LabeledPickerRow(
                title: "Refresh usage",
                subtitle: "How often SturtBar fetches Claude usage.")
            {
                Picker("Refresh usage", selection: self.$settings.refreshFrequency) {
                    ForEach(RefreshFrequency.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
            if self.settings.refreshFrequency == .manual {
                Text("Usage only refreshes when the menu opens or via Refresh Now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        SettingsSection(title: "Menu bar") {
            LabeledPickerRow(
                title: "Text next to icon",
                subtitle: self.settings.menuBarDisplayMode.description)
            {
                Picker("Text next to icon", selection: self.$settings.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        SettingsSection(title: "Display") {
            PreferenceToggleRow(
                title: "Show reset time as clock",
                subtitle: "Display reset times as absolute clock values instead of countdowns.",
                isOn: self.$settings.resetTimesShowAbsolute)

            PreferenceToggleRow(
                title: "Show usage as used",
                subtitle: "Progress bars fill as you consume quota (instead of showing remaining).",
                isOn: self.$settings.usageBarsShowUsed)
        }
    }

    // MARK: - Cost

    private var costSection: some View {
        SettingsSection(title: "Cost") {
            PreferenceToggleRow(
                title: "Track local token cost",
                subtitle: "Estimates spend locally from Claude Code session logs and shows it in the menu.",
                isOn: self.$settings.costUsageEnabled)

            if self.settings.costUsageEnabled {
                Stepper(value: self.$settings.costUsageHistoryDays, in: 1...365, step: 1) {
                    Text("History window: \(self.settings.costUsageHistoryDays) days")
                        .font(.footnote)
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        SettingsSection(title: "Notifications") {
            PreferenceToggleRow(
                title: "Session quota notifications",
                subtitle: "Notify when the session quota runs out and when it resets.",
                isOn: self.$settings.sessionQuotaNotificationsEnabled)

            PreferenceToggleRow(
                title: "Quota warning notifications",
                subtitle: "Warn before a quota runs out, at the thresholds below.",
                isOn: self.$settings.quotaWarningNotificationsEnabled)

            if self.settings.quotaWarningNotificationsEnabled {
                QuotaWarningSettingsView(settings: self.settings)
            }
        }
    }
}

// MARK: - Section / row components (legacy PreferencesComponents port)

struct SettingsSection<Content: View>: View {
    let title: String?
    private let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = self.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            VStack(alignment: .leading, spacing: 12) {
                self.content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PreferenceToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: self.$isOn) {
                Text(self.title)
                    .font(.body)
            }
            .toggleStyle(.checkbox)

            if let subtitle = self.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Title+subtitle on the left, a menu-style picker on the right (legacy GeneralPane row shape).
struct LabeledPickerRow<PickerContent: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let picker: () -> PickerContent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(.body)
                if let subtitle = self.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            self.picker()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
        }
    }
}

// MARK: - Quota warning block (legacy GlobalQuotaWarningSettingsView, trimmed)

struct QuotaWarningSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.session) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.session, enabled: $0) }))
                {
                    Text("Session").font(.footnote)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.weekly) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.weekly, enabled: $0) }))
                {
                    Text("Weekly").font(.footnote)
                }
                .toggleStyle(.checkbox)
            }

            self.thresholdField(.session, title: "Session warns at")
            self.thresholdField(.weekly, title: "Weekly warns at")

            Toggle(isOn: self.$settings.quotaWarningSoundEnabled) {
                Text("Play sound").font(.footnote)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.leading, 20)
    }

    private func thresholdField(_ window: QuotaWindow, title: String) -> some View {
        QuotaWarningThresholdField(
            title: title,
            thresholds: { self.settings.quotaWarningThresholds(window) },
            setThresholds: { self.settings.setQuotaWarningThresholds(window, thresholds: $0) })
            .disabled(!self.settings.quotaWarningWindowEnabled(window))
            .opacity(self.settings.quotaWarningWindowEnabled(window) ? 1 : 0.55)
    }
}

/// Upper/lower remaining-% pair editor (legacy QuotaWarningThresholdField, trimmed: no
/// localization, fixed two slots, Apply commits).
struct QuotaWarningThresholdField: View {
    let title: String
    let thresholds: () -> [Int]
    let setThresholds: ([Int]) -> Void

    @State private var upperText = ""
    @State private var lowerText = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(self.title)
                .font(.footnote.weight(.semibold))
                .frame(width: 110, alignment: .leading)

            Text("upper %")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("50", text: self.$upperText)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .frame(width: 56)
                .onChange(of: self.upperText) { _, value in
                    self.upperText = Self.filteredIntegerText(value)
                }
                .onSubmit { self.commit() }

            Text("lower %")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("20", text: self.$lowerText)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .frame(width: 56)
                .onChange(of: self.lowerText) { _, value in
                    self.lowerText = Self.filteredIntegerText(value)
                }
                .onSubmit { self.commit() }

            Button("Apply") { self.commit() }
                .controlSize(.small)
        }
        .onAppear { self.updateText(from: self.thresholds()) }
        .onChange(of: self.thresholds()) { _, value in
            self.updateText(from: value)
        }
    }

    private func commit() {
        let sanitized = QuotaWarningThresholds.resolved(
            upper: Self.integer(from: self.upperText),
            lower: Self.integer(from: self.lowerText))
        self.updateText(from: sanitized)
        self.setThresholds(sanitized)
    }

    private func updateText(from thresholds: [Int]) {
        let sanitized = QuotaWarningThresholds.sanitized(thresholds)
        self.upperText = sanitized.first.map(String.init) ?? ""
        self.lowerText = sanitized.dropFirst().first.map(String.init) ?? ""
    }

    private static func integer(from text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        return Int(text)
    }

    private static func filteredIntegerText(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(2))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Settings") {
    SettingsView(settings: SettingsStore(userDefaults: UserDefaults(suiteName: "settings-preview")!))
}
#endif
