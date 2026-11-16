import Foundation

/// Result of one full setup test (PLAN section 6.10).
public struct ProbeOutcome: Codable {
    public var displayId: String
    public var displayName: String
    public var interface: LinkInterface
    public var panelWidth: Int
    public var panelHeight: Int
    public var date: Date
    public var link: LinkResult
    public var outcomes: [CandidateOutcome]
    public var recommendation: Recommendation

    public init(displayId: String, displayName: String, interface: LinkInterface, panelWidth: Int,
                panelHeight: Int, date: Date = Date(), link: LinkResult, outcomes: [CandidateOutcome],
                recommendation: Recommendation) {
        self.displayId = displayId
        self.displayName = displayName
        self.interface = interface
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        self.date = date
        self.link = link
        self.outcomes = outcomes
        self.recommendation = recommendation
    }
}

/// Probe results cached per (Display id, interface type), stored in UserDefaults.
public enum ProbeCache {
    public static let defaultsKey = "probe.cache.v1"

    public static func key(displayId: String, interface: LinkInterface) -> String {
        "\(displayId)|\(interface.rawValue)"
    }

    public static func store(_ o: ProbeOutcome, in defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
        guard let data = try? JSONEncoder().encode(o) else { return }
        all[key(displayId: o.displayId, interface: o.interface)] = data
        defaults.set(all, forKey: defaultsKey)
    }

    public static func load(displayId: String, interface: LinkInterface,
                            from defaults: UserDefaults = .standard) -> ProbeOutcome? {
        let all = (defaults.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
        guard let data = all[key(displayId: displayId, interface: interface)] else { return nil }
        return try? JSONDecoder().decode(ProbeOutcome.self, from: data)
    }

    /// Most recent cached result for a Display, over all interface types.
    public static func latest(displayId: String, from defaults: UserDefaults = .standard) -> ProbeOutcome? {
        LinkInterface.allCases.compactMap { load(displayId: displayId, interface: $0, from: defaults) }
            .max { $0.date < $1.date }
    }
}
