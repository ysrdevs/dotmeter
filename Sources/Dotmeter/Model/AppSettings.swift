import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum MenuBarStyle: String, CaseIterable, Identifiable {
        case icon, cpu, temperature, fan
        var id: String { rawValue }
        var title: String {
            switch self {
            case .icon: return "Icon only"
            case .cpu: return "CPU usage"
            case .temperature: return "Temperature"
            case .fan: return "Fan speed"
            }
        }
    }

    /// How one area draws itself in the menu bar.
    enum MenuBarItemStyle: String, CaseIterable, Identifiable {
        case graph, icon, compact
        var id: String { rawValue }
        var title: String {
            switch self {
            case .graph: return "Graph and value"
            case .icon: return "Icon and value"
            case .compact: return "Graph only"
            }
        }
    }

    /// The areas that can sit in the menu bar, in the order they appear there.
    static let menuBarSections: [AppSection] = [.dashboard, .cpu, .gpu, .memory, .storage, .thermal, .network, .usb, .power] + (Hardware.hasBattery ? [.battery] : [])

    /// The Dashboard's cards in the order the user put them. Empty until one has been moved.
    /// Debug: DOTMETER_DASHBOARD_ORDER=network,thermal,cpu sets it for one run without saving.
    var dashboardOrder: [String] {
        didSet { if ProcessInfo.processInfo.environment["DOTMETER_DASHBOARD_ORDER"] == nil { defaults.set(dashboardOrder, forKey: "dashboardOrder") } }
    }

    /// The colour the dots are lit in. Debug: DOTMETER_THEME=amber chooses one for a run without saving it.
    var theme: DotTheme {
        didSet {
            if ProcessInfo.processInfo.environment["DOTMETER_THEME"] == nil { defaults.set(theme.rawValue, forKey: "theme") }
            DotTheme.current = theme
        }
    }

    /// Who answers: Claude or GPT. Each keeps its own key and its own choice of model.
    var provider: AIProvider {
        didSet {
            if ProcessInfo.processInfo.environment["DOTMETER_PROVIDER"] == nil { defaults.set(provider.rawValue, forKey: "provider") }
            AIProvider.current = provider
        }
    }

    /// The Claude model, as it always was, and the OpenAI one beside it.
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    var openAIModel: String { didSet { defaults.set(openAIModel, forKey: AIProvider.openai.modelDefaultsKey) } }

    /// The model of whichever provider is chosen.
    var activeModel: String {
        get { provider == .anthropic ? model : openAIModel }
        set { if provider == .anthropic { model = newValue } else { openAIModel = newValue } }
    }
    var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
    var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    /// Which providers have a key in the Keychain.
    private(set) var keys: Set<AIProvider>
    /// The chosen provider has its key.
    var hasAPIKey: Bool { keys.contains(provider) }
    /// Which kinds of event also send a notification. Running hot is `alertsEnabled`, as it always was.
    private(set) var alertKinds: Set<String>
    /// Free space, in gigabytes, under which the disk counts as nearly full.
    var diskAlertGB: Double { didSet { defaults.set(diskAlertGB, forKey: "diskAlertGB") } }
    /// An app counts as busy when it holds this many cores for this many minutes.
    var appAlertCores: Double { didSet { defaults.set(appAlertCores, forKey: "appAlertCores") } }
    var appAlertMinutes: Double { didSet { defaults.set(appAlertMinutes, forKey: "appAlertMinutes") } }
    /// The charge, in percent, under which a Mac on battery counts as low.
    var batteryAlertPercent: Double { didSet { defaults.set(batteryAlertPercent, forKey: "batteryAlertPercent") } }
    /// Echo the router and the internet while the Network area is open.
    var latencyEnabled: Bool { didSet { defaults.set(latencyEnabled, forKey: "latencyEnabled") } }
    /// Ask an outside server for this Mac's public address while the Network panel or area is open.
    var publicAddressEnabled: Bool { didSet { defaults.set(publicAddressEnabled, forKey: "publicAddressEnabled") } }
    /// Ask GitHub once a day whether a newer version is out.
    var updateChecks: Bool { didSet { defaults.set(updateChecks, forKey: "updateChecks") } }
    /// What a kilowatt-hour costs, in dollars. Zero hides the cost.
    var energyPrice: Double { didSet { if !temporaryPrice { defaults.set(energyPrice, forKey: "energyPrice") } } }
    /// The period the Power area totals energy and cost over.
    var energyPeriod: EnergyPeriod { didSet { defaults.set(energyPeriod.rawValue, forKey: "energyPeriod") } }
    /// Debug: DOTMETER_ENERGY_PRICE=0.16 sets a price for one run without saving it.
    @ObservationIgnored private let temporaryPrice = ProcessInfo.processInfo.environment["DOTMETER_ENERGY_PRICE"] != nil
    /// Which areas have their own menu bar item. Never empty: the app must stay reachable.
    private(set) var menuBarItems: [AppSection]
    private(set) var menuBarItemStyles: [AppSection: MenuBarItemStyle] = [:]

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Debug: DOTMETER_MENU_ITEMS=dashboard,cpu,network chooses the items for one run without saving the choice.
    @ObservationIgnored private let temporaryItems: Bool

    private init() {
        provider = AIProvider.current
        theme = DotTheme.current
        dashboardOrder = ProcessInfo.processInfo.environment["DOTMETER_DASHBOARD_ORDER"]?.split(separator: ",").map(String.init) ?? defaults.stringArray(forKey: "dashboardOrder") ?? []
        model = defaults.string(forKey: "model") ?? AIProvider.anthropic.defaultModel
        let openAIChoice = defaults.string(forKey: AIProvider.openai.modelDefaultsKey)
        openAIModel = AIProvider.openai.models.contains { $0.id == openAIChoice } ? openAIChoice ?? "" : AIProvider.openai.defaultModel
        effort = defaults.string(forKey: "effort") ?? "low"
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = interval > 0 ? interval : 2
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .icon
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        keys = Set(AIProvider.allCases.filter { Keychain.exists($0.keyAccount) })
        alertKinds = Set(defaults.stringArray(forKey: "alertKinds") ?? [])
        diskAlertGB = defaults.object(forKey: "diskAlertGB") as? Double ?? 25
        appAlertCores = defaults.object(forKey: "appAlertCores") as? Double ?? 4
        appAlertMinutes = defaults.object(forKey: "appAlertMinutes") as? Double ?? 5
        batteryAlertPercent = defaults.object(forKey: "batteryAlertPercent") as? Double ?? 20
        latencyEnabled = defaults.object(forKey: "latencyEnabled") as? Bool ?? true
        publicAddressEnabled = defaults.object(forKey: "publicAddressEnabled") as? Bool ?? true
        updateChecks = defaults.object(forKey: "updateChecks") as? Bool ?? true
        energyPrice = ProcessInfo.processInfo.environment["DOTMETER_ENERGY_PRICE"].flatMap(Double.init) ?? defaults.double(forKey: "energyPrice")
        energyPeriod = EnergyPeriod(rawValue: ProcessInfo.processInfo.environment["DOTMETER_ENERGY_PERIOD"] ?? defaults.string(forKey: "energyPeriod") ?? "") ?? .month

        let override = ProcessInfo.processInfo.environment["DOTMETER_MENU_ITEMS"]
        temporaryItems = override != nil
        let saved = override?.split(separator: ",").map(String.init) ?? defaults.stringArray(forKey: "menuBarItems") ?? ["dashboard"]
        let chosen = Self.menuBarSections.filter { saved.contains($0.rawValue) }
        menuBarItems = chosen.isEmpty ? [.dashboard] : chosen
        let style = ProcessInfo.processInfo.environment["DOTMETER_MENU_STYLE"].flatMap(MenuBarItemStyle.init(rawValue:))
        for section in Self.menuBarSections {
            if let value = style ?? defaults.string(forKey: "menuBarItemStyle." + section.rawValue).flatMap(MenuBarItemStyle.init(rawValue:)) {
                menuBarItemStyles[section] = value
            }
        }
    }

    // MARK: Alerts

    func notifies(_ kind: TimelineEvent.Kind) -> Bool {
        kind == .hot || kind == .throttled ? alertsEnabled : alertKinds.contains(kind.rawValue)
    }

    func setNotifies(_ kind: TimelineEvent.Kind, _ on: Bool) {
        if kind == .hot || kind == .throttled {
            alertsEnabled = on
        } else {
            if on { alertKinds.insert(kind.rawValue) } else { alertKinds.remove(kind.rawValue) }
            defaults.set(Array(alertKinds), forKey: "alertKinds")
        }
    }

    // MARK: Menu bar items

    func isInMenuBar(_ section: AppSection) -> Bool { menuBarItems.contains(section) }

    /// The last item cannot be taken out, or there would be no way back to the app.
    func canRemoveFromMenuBar(_ section: AppSection) -> Bool { menuBarItems.count > 1 }

    func setInMenuBar(_ section: AppSection, _ shown: Bool) {
        guard Self.menuBarSections.contains(section), shown != isInMenuBar(section) else { return }
        if !shown && !canRemoveFromMenuBar(section) { return }
        var wanted = Set(menuBarItems)
        if shown { wanted.insert(section) } else { wanted.remove(section) }
        menuBarItems = Self.menuBarSections.filter { wanted.contains($0) }
        if !temporaryItems { defaults.set(menuBarItems.map(\.rawValue), forKey: "menuBarItems") }
    }

    func itemStyle(for section: AppSection) -> MenuBarItemStyle { menuBarItemStyles[section] ?? .graph }

    func setItemStyle(_ style: MenuBarItemStyle, for section: AppSection) {
        menuBarItemStyles[section] = style
        if !temporaryItems { defaults.set(style.rawValue, forKey: "menuBarItemStyle." + section.rawValue) }
    }

    var modelTitle: String { provider.models.first { $0.id == activeModel }?.title ?? activeModel }

    /// Saves the key of the chosen provider.
    func saveAPIKey(_ key: String) throws {
        try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: provider.keyAccount, label: "\(App.name) — \(provider.company) API key")
        keys.insert(provider)
    }

    /// Looks again at which providers have a key, after one has been carried over from the app's earlier name.
    func refreshKeys() {
        keys = Set(AIProvider.allCases.filter { Keychain.exists($0.keyAccount) })
    }

    func removeAPIKey() {
        Keychain.delete(provider.keyAccount)
        keys.remove(provider)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }
}
