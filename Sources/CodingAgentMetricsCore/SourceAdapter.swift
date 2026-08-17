import Foundation

/// A versioned, local source of allowlisted Usage Observations.
///
/// Adapters expose observations rather than database or UI types, so future
/// sources share the same canonical ingestion path.
public protocol SourceAdapter: Sendable {
    func loadObservations(clock: any Clock) throws -> [UsageObservation]
}
