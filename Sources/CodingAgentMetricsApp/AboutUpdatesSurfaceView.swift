import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import SwiftUI

struct AboutUpdatesSurfaceProjection: Equatable {
    let name: String
    let versionText: String
    let minimumOSText: String
    let stableFeedText: String
    let metrics: [AppAboutPresentation.Metric]
    let localFirstSummary: String
    let privacyBoundary: String
    let networkBoundary: String
    let checkForUpdatesTitle: String

    static func make(_ presentation: AppAboutPresentation) -> Self {
        Self(
            name: presentation.name,
            versionText: "Version \(presentation.shortVersion) (Build \(presentation.build))",
            minimumOSText: "Requires macOS \(presentation.minimumOS)",
            stableFeedText: "Stable feed: \(presentation.stableFeedURL)",
            metrics: presentation.metrics,
            localFirstSummary: presentation.localFirstSummary,
            privacyBoundary: presentation.privacyBoundary,
            networkBoundary: presentation.networkBoundary,
            checkForUpdatesTitle: "Check for Updates"
        )
    }
}

struct AboutUpdatesSurfaceView: View {
    let presentation: AppAboutPresentation
    let updates: UpdateCheckController
    @ObservedObject private var accessibility: AccessibilitySession
    @FocusState private var focusedControl: AccessibilityNavigation.Control?

    init(
        presentation: AppAboutPresentation = AppAboutPresentation(),
        updates: UpdateCheckController,
        accessibility: AccessibilitySession? = nil
    ) {
        self.presentation = presentation
        self.updates = updates
        _accessibility = ObservedObject(wrappedValue: accessibility ?? AccessibilitySession())
    }

    var projection: AboutUpdatesSurfaceProjection {
        AboutUpdatesSurfaceProjection.make(presentation)
    }

    var body: some View {
        let projection = self.projection
        VStack(alignment: .leading, spacing: 12) {
            card("App") {
                Text(projection.name)
                    .font(.subheadline.weight(.semibold))
                caption(projection.versionText)
                caption(projection.minimumOSText)
                caption(projection.stableFeedText)
                    .textSelection(.enabled)
            }
            card("Metrics") {
                ForEach(projection.metrics, id: \.name) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.name)
                            .font(.caption.weight(.semibold))
                        caption(metric.definition)
                    }
                }
            }
            card("Privacy") {
                caption(projection.localFirstSummary)
                caption(projection.privacyBoundary)
                caption(projection.networkBoundary)
            }
            Button(projection.checkForUpdatesTitle) {
                accessibility.activate(.aboutCheckForUpdates)
                updates.checkForUpdates()
            }
            .focused($focusedControl, equals: .aboutCheckForUpdates)
            .accessibilityFocusChrome(focusedControl == .aboutCheckForUpdates)
            .accessibilityHint("Checks the stable update feed and always requires user confirmation to install.")
        }
        .frame(
            minWidth: AppIdentity.popoverWidth,
            idealWidth: AppIdentity.popoverWidth,
            maxWidth: AppIdentity.popoverWidth,
            alignment: .leading
        )
        .onAppear { syncFocus() }
        .onChange(of: accessibility.navigation.focusedControl) { _, _ in syncFocus() }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncFocus() {
        let control = accessibility.focusedControl
        focusedControl = control == .statusItem ? nil : control
    }
}
