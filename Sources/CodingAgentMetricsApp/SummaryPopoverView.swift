import CodingAgentMetricsCore
import SwiftUI

struct SummaryPopoverView: View {
    let snapshot: LightSnapshot?

    var body: some View {
        let presentation = snapshot.map(LightSnapshotPresentation.init)
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding Agent Metrics")
                .font(.headline)
            filterRow(
                title: "Agent",
                chips: presentation?.agentChips ?? [FilterChip(id: "all", title: "All", isSelected: true)]
            )
            filterRow(
                title: "Model",
                chips: presentation?.modelChips ?? [FilterChip(id: "all", title: "All", isSelected: true)]
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(presentation?.title ?? "Output Throughput")
                        .font(.subheadline)
                    Spacer()
                    Text(presentation?.windowLabel ?? "3m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(presentation?.valueText ?? "-")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(presentation?.unitText ?? "tokens/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                meta(title: "Quality", value: presentation?.qualityText ?? "Unavailable")
                meta(title: "State", value: presentation?.dataStateText ?? "Absent")
                meta(title: "Coverage", value: presentation?.coverageText ?? "Complete")
            }
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
    }

    private func filterRow(title: String, chips: [FilterChip]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        Text(chip.title)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(chip.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                            .overlay(
                                Capsule().stroke(chip.isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                            )
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) filter")
    }

    private func meta(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.primary.opacity(0.04))
    }
}
