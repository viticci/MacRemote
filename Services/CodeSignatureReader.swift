import CoreServices
import Foundation
import Security

/// Reads a binary's static code signature without ever running it (spec §2.6).
protocol SignatureReading: Sendable {
    func signatureTrust(atPath path: String) -> DiscoveredCLICandidate.SignatureTrust
}

/// Security.framework static-signature reader: parses `LC_CODE_SIGNATURE`
/// on disk via `SecStaticCode*` — the binary is never launched. Apple-signed
/// results cannot occur because system scope is excluded from scans (§2.3).
struct CodeSignatureReader: SignatureReading {
    init() {}

    func signatureTrust(atPath path: String) -> DiscoveredCLICandidate.SignatureTrust {
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return .unchecked
        }

        let validity = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        if validity == errSecCSUnsigned {
            return .unsigned
        }

        var rawInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        )
        guard infoStatus == errSecSuccess, let info = rawInfo as? [String: Any] else {
            return validity == errSecSuccess ? .adhoc : .invalid
        }

        if validity != errSecSuccess {
            return .invalid
        }

        let flags = (info[kSecCodeInfoFlags as String] as? UInt32)
            ?? (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
            ?? 0
        let isAdhoc = flags & 0x2 != 0   // kSecCodeSignatureAdhoc
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String

        guard !isAdhoc, let team, !team.isEmpty else {
            return .adhoc
        }

        var signerName: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            // Certificate subject text is third-party data like any other.
            let scrubbed = CLIHarvestedTextSanitizer.scrubbedDisplayText(summary)
            signerName = scrubbed.map { String($0.prefix(80)) }
        }
        return .developerID(team: team, name: signerName)
    }
}

/// Reads `kMDItemWhereFroms` through the Spotlight metadata *read* API — the
/// origin domain shown in a row's Details (spec §2.6). Read-only; no network.
enum SpotlightOriginReader {
    static func originDomain(atPath path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let values = MDItemCopyAttribute(item, "kMDItemWhereFroms" as CFString) as? [String],
              let first = values.first else {
            return nil
        }
        let host = URLComponents(string: first)?.host ?? first
        return CLIHarvestedTextSanitizer.sanitizedOriginDomain(host)
    }
}
