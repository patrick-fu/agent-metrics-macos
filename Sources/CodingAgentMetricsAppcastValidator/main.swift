import CryptoKit
import Foundation

private enum ValidationError: Error {
    case invalidArguments
    case invalidSignature
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 1 {
        let appcastPath = arguments[0]
        let appcast = try String(contentsOfFile: appcastPath, encoding: .utf8)
        _ = try AppcastReleaseContract.validateFeed(appcast, currentBuild: 0)
    } else if arguments.count == 4, arguments[0] == "--verify-archive" {
        let appcastPath = arguments[1]
        let archivePath = arguments[2]
        let infoPlistPath = arguments[3]
        let appcast = try String(contentsOfFile: appcastPath, encoding: .utf8)
        let release = try AppcastReleaseContract.validateFeed(appcast, currentBuild: 0)
        let plistData = try Data(contentsOf: URL(fileURLWithPath: infoPlistPath))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let encodedPublicKey = plist["SUPublicEDKey"] as? String,
              let publicKeyData = Data(base64Encoded: encodedPublicKey),
              publicKeyData.count == 32,
              let signatureData = Data(base64Encoded: release.edSignature.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)),
              signatureData.count == 64 else {
            throw ValidationError.invalidSignature
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let archive = try Data(contentsOf: URL(fileURLWithPath: archivePath), options: .mappedIfSafe)
        guard !archive.isEmpty, publicKey.isValidSignature(signatureData, for: archive) else {
            throw ValidationError.invalidSignature
        }
    } else {
        throw ValidationError.invalidArguments
    }
}

do {
    try run()
} catch {
    fputs("appcast-validator: production update contract rejected\n", stderr)
    Foundation.exit(EXIT_FAILURE)
}
