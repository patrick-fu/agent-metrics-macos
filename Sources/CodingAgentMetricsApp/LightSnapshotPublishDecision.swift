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
}
