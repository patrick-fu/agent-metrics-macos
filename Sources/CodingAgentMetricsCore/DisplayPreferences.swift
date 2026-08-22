import Foundation

public struct DisplayPreferencesStore: @unchecked Sendable {
    public static let cadenceKey = "displayCadenceSeconds"
    public static let windowKey = "outputThroughputWindowSeconds"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var cadence: DisplayCadence {
        get {
            guard defaults.object(forKey: Self.cadenceKey) != nil else { return .default }
            return DisplayCadence(rawValue: defaults.integer(forKey: Self.cadenceKey)) ?? .default
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.cadenceKey)
        }
    }

    public var window: OutputThroughputWindow {
        get {
            guard defaults.object(forKey: Self.windowKey) != nil else { return .default }
            return OutputThroughputWindow(rawValue: defaults.integer(forKey: Self.windowKey)) ?? .default
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.windowKey)
        }
    }
}
