import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import SwiftUI

struct SummaryPopoverView: View {
    @State private var snapshot: LightSnapshot?
    let lifecycleServices: AppLifecycleServices
    var loadSnapshot: (MetricFilter) -> LightSnapshot?

    init(
        snapshot: LightSnapshot?,
        lifecycleServices: AppLifecycleServices = .live,
        loadSnapshot: @escaping (MetricFilter) -> LightSnapshot? = { _ in nil }
    ) {
        _snapshot = State(initialValue: snapshot)
        self.lifecycleServices = lifecycleServices
        self.loadSnapshot = loadSnapshot
    }

    var body: some View {
        let presentation = snapshot.map(LightSnapshotPresentation.init)
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding Agent Metrics")
                .font(.headline)
            filterRow(
                title: "Agent",
                chips: presentation?.agentChips ?? [
                    FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                ],
                count: presentation?.agentActiveCount ?? 0,
                axis: .agent
            )
            filterRow(
                title: "Model",
                chips: presentation?.modelChips ?? [
                    FilterChip(id: "all", title: "All", isSelected: true, action: .selectAll)
                ],
                count: presentation?.modelActiveCount ?? 0,
                axis: .model
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
            SettingsView(lifecycleServices: lifecycleServices)
        }
        .padding(14)
        .frame(width: AppIdentity.popoverWidth, alignment: .leading)
        .background(.regularMaterial)
    }

    private func filterRow(title: String, chips: [FilterChip], count: Int, axis: FilterAxis) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(count == 0 ? title : "\(title) \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
                .accessibilityLabel(count == 0 ? "\(title) filter" : "\(title) filter, \(count) selected")
            Menu {
                ForEach(chips) { chip in
                    Button {
                        apply(chip.action, on: axis)
                    } label: {
                        if chip.isSelected {
                            Label(chip.title, systemImage: "checkmark")
                        } else {
                            Text(chip.title)
                        }
                    }
                    .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("\(title) filter menu")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        Button(chip.title) {
                            apply(chip.action, on: axis)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(chip.isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .overlay(
                            Capsule().stroke(chip.isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                        )
                        .clipShape(Capsule())
                        .accessibilityLabel(chip.title)
                        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func apply(_ action: FilterChipAction, on axis: FilterAxis) {
        snapshot = LightSnapshot.updated(
            from: snapshot,
            applying: action,
            on: axis,
            load: loadSnapshot
        )
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
