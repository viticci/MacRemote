import Foundation

// TRUST BOUNDARY — same rule as `ConnectedAppIdentity`, one tier lower.
//
// MCP 2026-07-28 lets a client hang icons off its `clientInfo`
// (`Implementation` extends `Icons`). The specification is explicit about what
// that field is worth: "The value is self-reported by the client and is not
// verified by the protocol. It is intended for display, logging, and debugging.
// Servers SHOULD NOT use it to change their behavior, and SHOULD NOT rely on it
// for security decisions."
//
// So this type carries a picture and nothing else. It cannot outrank a curated
// mark, and accepting one changes no trust, permission, or approval outcome.
//
// Two hard rules, both enforced here rather than at the call site:
//
//   - `data:` URIs only. An `http(s)` icon would mean MacRemote making a
//     request to a host the app picked, on the app's schedule — a fetch it can
//     use to learn that this Mac is online, and a hole in the "no runtime
//     fetching" rule the bundled-artwork policy rests on.
//   - Raster only, and small. PNG or JPEG, checked by magic bytes rather than
//     by the declared MIME type, because the declaration is also self-reported.
//     SVG is refused outright: it is a scriptable document.
//
// OAuth Dynamic Client Registration's `logo_uri` stays dropped and is not
// modelled here at all. See the note in `Services/OAuthCoordinator.swift`.

/// One accepted, already-decoded icon an app supplied about itself.
struct ClientSuppliedIcon: Equatable, Hashable, Sendable {
    /// Which appearance the app says the icon is drawn for. Per the MCP schema,
    /// `light` means "designed to be used with a light background".
    enum Theme: String, Equatable, Hashable, Sendable {
        case light
        case dark
        /// No theme declared: usable on either appearance.
        case any
    }

    /// Decoded image bytes. Held in memory only — never written to disk.
    let imageData: Data
    /// The MIME type this decodes to, as determined from the bytes.
    let mimeType: String
    let theme: Theme
}

extension ClientSuppliedIcon {
    /// Why an icon was refused. Surfaced so a refusal can be logged and tested
    /// precisely instead of vanishing into a `nil`.
    enum RejectionReason: Error, Equatable, Sendable {
        case notADataURI(scheme: String)
        case malformedDataURI
        case unsupportedImageFormat(String)
        case tooLarge(bytes: Int)
    }

    /// Largest decoded image accepted per icon. A `hero` mark is 64 pt, so even
    /// a @3x asset has no honest reason to exceed this; the cap exists so a
    /// client cannot park megabytes in this process by handshaking.
    static let maximumImageByteCount = 256 * 1024

    /// Most icons kept per client. The tier only ever draws one, but a client
    /// may legitimately send a light/dark pair plus an untagged fallback.
    static let maximumIconsPerClient = 4

    /// Parse one `Icon` object from a client handshake.
    ///
    /// `mimeType` and `sizes` from the wire are deliberately ignored for
    /// validation: the format is decided by the bytes, and the size we draw at
    /// is ours to choose.
    static func parse(_ raw: [String: Any]) -> Result<ClientSuppliedIcon, RejectionReason> {
        guard let src = raw["src"] as? String else {
            return .failure(.malformedDataURI)
        }
        let theme: Theme
        switch raw["theme"] as? String {
        case "light": theme = .light
        case "dark": theme = .dark
        default: theme = .any
        }
        return parse(src: src, theme: theme)
    }

    static func parse(src: String, theme: Theme = .any) -> Result<ClientSuppliedIcon, RejectionReason> {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)

        // Scheme check first, and by prefix rather than by `URL(string:)`:
        // "data:" is the only accepted answer, so anything else is named in the
        // rejection for the log line.
        guard trimmed.lowercased().hasPrefix("data:") else {
            let scheme = trimmed.prefix { $0 != ":" }.lowercased()
            return .failure(.notADataURI(scheme: scheme.isEmpty ? "none" : String(scheme)))
        }

        // data:[<mediatype>][;base64],<data> — only the base64 form is taken.
        // Percent-encoded text payloads are refused with the format rejection
        // they deserve rather than being decoded into an image guess.
        let body = trimmed.dropFirst("data:".count)
        guard let comma = body.firstIndex(of: ",") else {
            return .failure(.malformedDataURI)
        }
        let parameters = String(body[body.startIndex..<comma]).lowercased()
        guard parameters.contains(";base64") else {
            return .failure(.malformedDataURI)
        }
        let payload = String(body[body.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              !data.isEmpty else {
            return .failure(.malformedDataURI)
        }

        // Cap before sniffing: refusing a 40 MB payload should not depend on
        // whether it happens to be a valid PNG.
        guard data.count <= maximumImageByteCount else {
            return .failure(.tooLarge(bytes: data.count))
        }
        guard let mimeType = rasterMIMEType(of: data) else {
            return .failure(.unsupportedImageFormat(declaredFormatDescription(parameters)))
        }
        return .success(ClientSuppliedIcon(imageData: data, mimeType: mimeType, theme: theme))
    }

    /// PNG and JPEG only, by magic bytes. Everything else — SVG, WebP, HTML
    /// wearing an `image/png` label — is refused.
    private static func rasterMIMEType(of data: Data) -> String? {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        if data.count > png.count, Array(data.prefix(png.count)) == png {
            return "image/png"
        }
        if data.count > jpeg.count, Array(data.prefix(jpeg.count)) == jpeg {
            return "image/jpeg"
        }
        return nil
    }

    private static func declaredFormatDescription(_ parameters: String) -> String {
        let declared = parameters
            .split(separator: ";")
            .first { $0.contains("/") }
            .map(String.init)
        return declared ?? "unknown"
    }
}

/// The icons one app supplied, kept in the order received.
struct ClientSuppliedIconSet: Equatable, Hashable, Sendable {
    let icons: [ClientSuppliedIcon]

    init(icons: [ClientSuppliedIcon]) {
        self.icons = Array(icons.prefix(ClientSuppliedIcon.maximumIconsPerClient))
    }

    var isEmpty: Bool { icons.isEmpty }

    /// Prefer the variant the app tagged for this appearance, then an untagged
    /// one, then whatever it did send — the same "recognition beats appearance"
    /// rule the bundled tier uses.
    func icon(forDarkAppearance isDarkAppearance: Bool) -> ClientSuppliedIcon? {
        let wanted: ClientSuppliedIcon.Theme = isDarkAppearance ? .dark : .light
        return icons.first { $0.theme == wanted }
            ?? icons.first { $0.theme == .any }
            ?? icons.first
    }

    /// Build a set from the raw `icons` array of an MCP `Implementation`.
    /// Returns `nil` when the app sent no usable icon, so callers can tell
    /// "nothing supplied" apart from "supplied an empty set".
    ///
    /// `rejections` is reported for logging, not for behavior.
    static func parse(
        clientInfoIcons raw: Any?,
        rejections: inout [ClientSuppliedIcon.RejectionReason]
    ) -> ClientSuppliedIconSet? {
        guard let entries = raw as? [[String: Any]], !entries.isEmpty else { return nil }
        var accepted: [ClientSuppliedIcon] = []
        for entry in entries {
            // Stop parsing once the cap is reached; the rest are not even
            // base64-decoded.
            guard accepted.count < ClientSuppliedIcon.maximumIconsPerClient else { break }
            switch ClientSuppliedIcon.parse(entry) {
            case .success(let icon):
                accepted.append(icon)
            case .failure(let reason):
                rejections.append(reason)
            }
        }
        return accepted.isEmpty ? nil : ClientSuppliedIconSet(icons: accepted)
    }
}
