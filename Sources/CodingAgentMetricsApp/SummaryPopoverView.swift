import CodingAgentMetricsCore
import CodingAgentMetricsLifecycle
import SwiftUI

struct SummaryPopoverView: View {
    private enum Activity: String, CaseIterable, Identifiable {
        case burn = "Burn"
        case calls = "Calls"
        var id: String { rawValue }
    }

    @State private var snapshot: LightSnapshot?
    @State private var activity: Activity = .burn
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
            HStack(spacing: 8) {
                kpi(title: "Token Burn/min", value: presentation?.burnValueText ?? "Unavailable", unit: presentation?.burnUnitText ?? "tokens/min")
                kpi(title: "Calls/min", value: presentation?.callsValueText ?? "Unavailable", unit: presentation?.callsUnitText ?? "calls/min")
            }
            Picker("Activity", selection: $activity) {
                ForEach(Activity.allCases) { activity in
                    Text(activity.rawValue).tag(activity)
                }
            }
            .pickerStyle(.segmented)
            activityDetail(presentation)
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

    @ViewBuilder
    private func activityDetail(_ presentation: LightSnapshotPresentation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if activity == .burn {
                Text("Burn composition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation?.burnCompositionText ?? "Unavailable")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    meta(title: "Quality", value: presentation?.burnQualityText ?? "Unavailable")
                    meta(title: "State", value: presentation?.burnStateText ?? "Absent")
                    meta(title: "Coverage", value: presentation?.burnCoverageText ?? "Partial")
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation?.callsDetailText ?? "Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(presentation?.callsWindowLabel ?? "10m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    meta(title: "Quality", value: presentation?.callsQualityText ?? "Unavailable")
                    meta(title: "State", value: presentation?.callsStateText ?? "Unavailable")
                    meta(title: "Coverage", value: presentation?.callsCoverageText ?? "Partial")
                }
            }
        }
    }

    private func kpi(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04))
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
