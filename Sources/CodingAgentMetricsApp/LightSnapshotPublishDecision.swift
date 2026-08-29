import Foundation

struct LightSnapshotPublishDecision: Equatable, Sendable {
    private var pendingHeroPromotion = false

    mutating func noteRequested(publishHero: Bool) {
        if publishHero {
            pendingHeroPromotion = true
        }
    }

    mutating func shouldPublishHero(forThisCompletion publishHero: Bool) -> Bool {
        let shouldPublish = publishHero || pendingHeroPromotion
        pendingHeroPromotion = false
        return shouldPublish
    }

    /// Keep the last good snapshot when a load returns nil, but still consume a
    /// pending hero tick so cadence display is not blocked by a failed ingest.
    mutating func complete<Snapshot>(
        output: Snapshot?,
        publishHero: Bool,
        latest: Snapshot?
    ) -> (latest: Snapshot?, hero: Snapshot?) {
        let nextLatest = output ?? latest
        let hero = shouldPublishHero(forThisCompletion: publishHero) ? nextLatest : nil
        return (nextLatest, hero)
    }
}
