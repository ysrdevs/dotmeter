import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SystemMonitor.self) private var monitor

    @State private var keyDraft = ""
    @State private var editingKey = false
    @State private var keyError: String?
    @State private var launchAtLogin = false
    @Environment(UninstallHelper.self) private var helper
    @Environment(UpdateModel.self) private var updates

    private var updateStatus: String {
        if let release = updates.release, updates.waiting { return "\(release.version) is available" }
        if updates.phase == .checking { return "Checking…" }
        guard let checked = updates.checkedAt else { return "Not checked yet" }
        return "Checked \(checked.formatted(.relative(presentation: .named)))"
    }

    private var helperStatus: String {
        switch helper.state {
        case .on: return "On: uninstalls need no password"
        case .needsApproval: return "Waiting to be allowed in Login Items"
        case .off: return "Off: the first uninstall that needs it asks"
        case .missing: return "Not in this copy"
        }
    }

    var body: some View {
        @Bindable var settings = settings
        ScrollViewReader { proxy in
        Form {
            Section {
                Picker("Answers come from", selection: $settings.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text("\(provider.assistant) · \(provider.company)").tag(provider)
                    }
                }
                .onChange(of: settings.provider) { _, _ in
                    // The key field belongs to one provider: a half-typed key must not be saved under the other.
                    editingKey = false
                    keyDraft = ""
                    keyError = nil
                }
                if settings.hasAPIKey && !editingKey {
                    HStack {
                        Label("\(settings.provider.company) API key saved in Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.green)
                        Spacer()
                        Button("Replace…") { editingKey = true }
                        Button("Remove", role: .destructive) { settings.removeAPIKey() }
                    }
                } else {
                    SecureField("\(settings.provider.company) API key", text: $keyDraft, prompt: Text(settings.provider.keyPrompt))
                        .onSubmit(saveKey)
                    HStack {
                        if let keyError {
                            Text(keyError).font(.caption).foregroundStyle(Theme.red)
                        } else {
                            Text(settings.provider.keyHelp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.hasAPIKey { Button("Cancel") { editingKey = false; keyDraft = "" } }
                        Button("Save to Keychain", action: saveKey)
                            .keyboardShortcut(.defaultAction)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Picker("Model", selection: $settings.activeModel) {
                    ForEach(settings.provider.models) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                Text(settings.provider.models.first { $0.id == settings.activeModel }?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Effort", selection: $settings.effort) {
                    Text("Low · fastest").tag("low")
                    Text("Medium").tag("medium")
                    Text("High · most thorough").tag("high")
                }
            } header: {
                Text("Assistant")
            } footer: {
                footer("Each analysis or explanation sends a few thousand tokens of system stats to \(settings.provider.host) and costs about a cent. Each provider keeps its own key, so you can switch back and forth.")
            }

            Section {
                ForEach(AppSettings.menuBarSections) { section in
                    let shown = settings.isInMenuBar(section)
                    LabeledContent {
                        HStack(spacing: 10) {
                            if section == .dashboard {
                                Picker("Beside the icon", selection: $settings.menuBarStyle) {
                                    ForEach(AppSettings.MenuBarStyle.allCases) { style in
                                        Text(style.title).tag(style)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 158)
                                .disabled(!shown)
                            } else {
                                Picker("Style", selection: Binding(get: { settings.itemStyle(for: section) }, set: { settings.setItemStyle($0, for: section) })) {
                                    ForEach(AppSettings.MenuBarItemStyle.allCases) { style in
                                        Text(style.title).tag(style)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 158)
                                .disabled(!shown)
                            }
                            Toggle("Show \(section.title)", isOn: Binding(get: { shown }, set: { settings.setInMenuBar(section, $0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(shown && !settings.canRemoveFromMenuBar(section))
                        }
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
            } header: {
                Text("Menu bar items")
            } footer: {
                footer("Each area can sit in the menu bar on its own, with a live graph and a panel about just that area. Dashboard is the overview of all of them. One item always stays, so the app can be reached. Right-click any item to add or remove others.")
            }

            Section("General") {
                Picker("Refresh every", selection: $settings.refreshInterval) {
                    Text("Second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        if settings.launchAtLogin != value { settings.launchAtLogin = value }
                    }
                // The helper that removes apps the system owns. An uninstall that needs it asks for it; this is where it goes off.
                LabeledContent("Uninstall helper") {
                    HStack(spacing: 8) {
                        Text(helperStatus).foregroundStyle(.secondary)
                        if helper.state == .on || helper.state == .needsApproval {
                            Button("Switch off") { Task { await helper.turnOff() } }
                        }
                    }
                }
                .onAppear { helper.refresh() }
            }

            Section {
                Toggle("The Mac runs hot or throttles", isOn: notifies(.hot))
                    .id("alerts")
                Toggle("An app holds \(Int(settings.appAlertCores)) cores for \(Int(settings.appAlertMinutes)) minutes", isOn: notifies(.app))
                Stepper("Cores: \(Int(settings.appAlertCores))", value: $settings.appAlertCores, in: 1...64)
                Stepper("Minutes: \(Int(settings.appAlertMinutes))", value: $settings.appAlertMinutes, in: 1...60)
                Toggle("Memory pressure rises", isOn: notifies(.memory))
                Toggle("Free disk space falls under \(Int(settings.diskAlertGB)) GB", isOn: notifies(.disk))
                Stepper("Gigabytes: \(Int(settings.diskAlertGB))", value: $settings.diskAlertGB, in: 5...500, step: 5)
                Toggle("The connection drops", isOn: notifies(.offline))
                Toggle("Something plugged in runs slower than it could", isOn: notifies(.usb))
                if Hardware.hasBattery {
                    Toggle("The battery falls under \(Int(settings.batteryAlertPercent))%", isOn: notifies(.battery))
                    Stepper("Percent: \(Int(settings.batteryAlertPercent))", value: $settings.batteryAlertPercent, in: 5...50, step: 5)
                }
            } header: {
                Text("Notify me when")
            } footer: {
                footer("Every one of these is written to the Timeline whether or not it is switched on here; the figures above decide what counts. A switch adds a notification, at most once every ten minutes each.")
            }

            Section {
                Toggle("Time echoes to the router and the internet", isOn: $settings.latencyEnabled)
                Toggle("Look up this Mac's external IP address", isOn: $settings.publicAddressEnabled)
                LabeledContent("Electricity price per kWh") {
                    HStack(spacing: 4) {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Price", value: $settings.energyPrice, format: .number.precision(.fractionLength(0...3)), prompt: Text("0.00"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 84)
                    }
                }
                Picker("Total energy and cost over", selection: $settings.energyPeriod) {
                    ForEach(EnergyPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
            } header: {
                Text("Network and power")
            } footer: {
                footer("Echoes go to your router and to \(LatencyProbe.internetHost) every two seconds, only while the Network area is open. The external address is asked of the same host, over HTTPS, when the Network panel or area opens and at most once every five minutes. A speed test runs only when you press its button. With a price set, in dollars, the Power area, its menu bar panel and the Timeline show what the energy cost. The period can also be chosen on the Power page.")
            }

            Section("Sensors") {
                if let thermal = monitor.snapshot?.thermal {
                    LabeledContent("Thermal state", value: thermal.state.title)
                    if let limit = thermal.cpuSpeedLimit { LabeledContent("CPU speed limit", value: "\(limit)%") }
                    ForEach(thermal.fans) { fan in
                        LabeledContent("Fan \(fan.index + 1)", value: "\(Format.rpm(fan.rpm)) rpm · \(Format.rpm(fan.minRPM))–\(Format.rpm(fan.maxRPM))")
                    }
                    DisclosureGroup("Temperature sensors (\(thermal.sensors.count))") {
                        ForEach(thermal.sensors) { sensor in
                            LabeledContent(sensor.label, value: String(format: "%.1f°", sensor.celsius))
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                        }
                    }
                } else {
                    Text("Reading…").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("\(App.name) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")") {
                    HStack(spacing: 8) {
                        Text(updateStatus).foregroundStyle(.secondary)
                        if updates.waiting {
                            Button("Update…") { updates.present(false) }
                        } else {
                            Button("Check Now") { updates.check() }.disabled(updates.phase == .checking)
                        }
                    }
                }
                .id("updates")
                Toggle("Check for updates every day", isOn: $settings.updateChecks)
            } header: {
                Text("Updates")
            } footer: {
                footer("A check asks GitHub which version is the newest and sends nothing about this Mac. A new version is downloaded only when you press Install, and it is installed only if it is signed by \(App.possessive) developer and notarized by Apple.")
            }

            Section {
                Text("A menu bar check-up for your Mac. Built with Swift; answers come from Claude or GPT, with your own key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 560, maxHeight: 780)
        .onAppear {
            launchAtLogin = settings.launchAtLogin
            // Debug: DOTMETER_SETTINGS_SCROLL=alerts opens the form at that section, for captures.
            if let target = ProcessInfo.processInfo.environment["DOTMETER_SETTINGS_SCROLL"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(target, anchor: .top) }
            }
        }
        }
    }

    private func notifies(_ kind: TimelineEvent.Kind) -> Binding<Bool> {
        Binding(get: { settings.notifies(kind) }, set: { on in
            settings.setNotifies(kind, on)
            if on { AlertCenter.shared.requestAuthorization() }
        })
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try settings.saveAPIKey(key)
            keyDraft = ""
            keyError = nil
            editingKey = false
        } catch {
            keyError = error.localizedDescription
        }
    }
}
