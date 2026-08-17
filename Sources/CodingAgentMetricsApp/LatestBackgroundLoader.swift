import CodingAgentMetricsCore
import Foundation

/// Runs at most one load at a time, coalesces queued work to the latest request,
/// and publishes only if no newer request has superseded the result.
@MainActor
final class LatestBackgroundLoader<Input: Sendable & Equatable, Output: Sendable> {
    typealias Completion = @MainActor @Sendable (Output) -> Void

    private struct Request: Sendable {
        var generation: UInt64
        var input: Input
        var completion: Completion
        var startWhenCurrentFinishes: Bool
    }

    private let queue: DispatchQueue
    private let gate: DetailQueryGate
    private let load: @Sendable (Input) -> Output?
    private var generation: UInt64 = 0
    private var selectedInput: Input?
    private var inFlight: Request?
    private var pending: Request?

    init(
        queue: DispatchQueue,
        gate: DetailQueryGate,
        load: @escaping @Sendable (Input) -> Output?
    ) {
        self.queue = queue
        self.gate = gate
        self.load = load
    }

    func submit(_ input: Input, completion: @escaping Completion) {
        if selectedInput != input {
            generation &+= 1
            selectedInput = input
        }
        let startsAfterCurrent = inFlight.map {
            $0.input != input || $0.generation != generation
        } ?? false
        pending = Request(
            generation: generation,
            input: input,
            completion: completion,
            startWhenCurrentFinishes: startsAfterCurrent
        )
        startNextIfNeeded()
    }

    func invalidate() {
        generation &+= 1
        selectedInput = nil
        pending = nil
    }

    private func startNextIfNeeded() {
        guard inFlight == nil, let request = pending, gate.begin() else { return }
        pending = nil
        inFlight = request
        let load = load
        let gate = gate
        queue.async { [weak self] in
            let output = load(request.input)
            gate.end()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = nil
                if request.generation == self.generation,
                   request.input == self.selectedInput,
                   let output {
                    request.completion(output)
                }
                if self.pending?.startWhenCurrentFinishes == true {
                    self.startNextIfNeeded()
                }
            }
        }
    }
}
