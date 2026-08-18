#if canImport(CodingAgentMetricsLifecycle)
import CodingAgentMetricsLifecycle
#endif
import Foundation

private enum CommandError: Error {
    case invalidArguments
    case invalidFixture
    case productionGateUnavailable
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.isEmpty || arguments == ["--dry-run"] else {
        throw CommandError.invalidArguments
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let fixture = root.appendingPathComponent("Fixtures/release/public-beta", isDirectory: true)
    let appData = try Data(contentsOf: fixture.appendingPathComponent("app-info.plist"))
    let appcastXML = try String(
        contentsOf: fixture.appendingPathComponent("appcast.xml"),
        encoding: .utf8
    )
    let inspectionData = try Data(contentsOf: fixture.appendingPathComponent("inspection.json"))
    let inspection = try JSONDecoder().decode(ReleaseDryRunInspection.self, from: inspectionData)
    let artifact = fixture.appendingPathComponent(inspection.artifactFilename)
    let attributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
    guard let size = attributes[.size] as? NSNumber else {
        throw CommandError.invalidFixture
    }
    let summary = try ReleaseDryRunChecker.validate(
        ReleaseDryRunInput(
            appPropertyList: appData,
            appcastXML: appcastXML,
            artifactByteLength: size.uint64Value,
            inspection: inspection
        )
    )

    let productionGate: ProductionReleaseGate
    do {
        let productionPlist = try Data(
            contentsOf: root.appendingPathComponent("Sources/CodingAgentMetricsApp/Info.plist")
        )
        productionGate = try ReleaseDryRunChecker.productionGate(
            appPropertyList: productionPlist
        )
    } catch {
        throw CommandError.productionGateUnavailable
    }

    print("release-check result=PASS mode=synthetic-dry-run fixture=\(summary.fixtureLabel)")
    print("release-check stages=\(summary.completedStages.map(\.rawValue).joined(separator: ">"))")
    switch productionGate {
    case .blockedByIssue27MissingSparklePublicKey:
        print("release-check production-gate=BLOCKED issue=#27 reason=missing-or-invalid-SUPublicEDKey")
    case .requiresIssue27ManualKeyValidation:
        print("release-check production-gate=MANUAL issue=#27 reason=validate-SUPublicEDKey-locally")
    }
    print("release-check automation=none publication=not-attempted credentials=not-required")
    print("release-check next=docs/release/public-beta-runbook.md#issue-27-human-gates")
}

do {
    try run()
} catch CommandError.invalidArguments {
    print("release-check result=FAIL reason=only-dry-run-is-supported")
    Foundation.exit(EXIT_FAILURE)
} catch CommandError.productionGateUnavailable {
    print("release-check result=FAIL reason=production-gate-unavailable")
    Foundation.exit(EXIT_FAILURE)
} catch {
    print("release-check result=FAIL reason=synthetic-contract-rejected")
    Foundation.exit(EXIT_FAILURE)
}
