import Compression
import Foundation

enum CloudflaredArchiveError: LocalizedError, Equatable {
    case archiveSizeMismatch(expected: Int, actual: Int)
    case archiveHashMismatch
    case notGzip
    case inflateFailed(String)
    case inflateOverflow
    case gzipTrailerMismatch(String)
    case malformedArchive(String)
    case rejectedEntry(String)
    case executableSizeMismatch(expected: Int, actual: Int)
    case executableHashMismatch
    case signatureMismatch(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .archiveSizeMismatch(let expected, let actual):
            "The download is \(actual) bytes but Cloudflare published \(expected) bytes."
        case .archiveHashMismatch:
            "The download's SHA-256 does not match the one Cloudflare published."
        case .notGzip:
            "The download is not the compressed archive Cloudflare publishes."
        case .inflateFailed(let detail):
            "The download could not be unpacked: \(detail)"
        case .inflateOverflow:
            "The download expands to more data than Cloudflare published."
        case .gzipTrailerMismatch(let detail):
            "The unpacked data failed its own checksum: \(detail)"
        case .malformedArchive(let detail):
            "The download is not shaped like Cloudflare's release archive: \(detail)"
        case .rejectedEntry(let detail):
            "The archive contains something MacRemote will not unpack: \(detail)"
        case .executableSizeMismatch(let expected, let actual):
            "The unpacked helper is \(actual) bytes but Cloudflare published \(expected) bytes."
        case .executableHashMismatch:
            "The unpacked helper's SHA-256 does not match the one Cloudflare published."
        case .signatureMismatch(let detail):
            "The unpacked helper is not signed by Cloudflare: \(detail)"
        case .writeFailed(let detail):
            "MacRemote could not write the unpacked helper: \(detail)"
        }
    }
}

/// Unpacks Cloudflare's release archive in-process: no subprocess, no `tar`,
/// no shell. The archive is verified byte-for-byte before it is opened, then a
/// deliberately narrow gzip + USTAR reader accepts exactly one shape — a single
/// regular file named `cloudflared` of the published size — and rejects
/// everything else (symlinks, hard links, directories, path traversal, PAX and
/// GNU extensions, and any second entry).
enum CloudflaredArchiveExtractor {
    static let blockSize = 512

    /// Verifies the archive, unpacks it to `destination`, then verifies the
    /// unpacked binary's size, SHA-256, and Developer ID team.
    static func extract(
        archiveAt archiveURL: URL,
        artifact: CloudflaredArtifact,
        to destination: URL,
        expectedEntryName: String = CloudflaredManifest.expectedEntryName,
        expectedTeamIdentifier: String = CloudflaredManifest.expectedTeamIdentifier,
        signatureReader: any SignatureReading = CodeSignatureReader()
    ) throws {
        let archive = try loadVerifiedArchive(at: archiveURL, artifact: artifact)
        let tar = try gunzip(archive, maxOutputByteCount: artifact.uncompressedTarByteCount)
        let payload = try singlePayload(
            inTar: tar,
            expectedEntryName: expectedEntryName,
            expectedByteCount: artifact.executableByteCount
        )

        do {
            try? FileManager.default.removeItem(at: destination)
            try Data(payload).write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            throw CloudflaredArchiveError.writeFailed(error.localizedDescription)
        }

        // Re-read from disk: what gets launched later is what is checked now.
        let writtenByteCount = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)??.intValue ?? -1
        guard writtenByteCount == artifact.executableByteCount else {
            try? FileManager.default.removeItem(at: destination)
            throw CloudflaredArchiveError.executableSizeMismatch(
                expected: artifact.executableByteCount,
                actual: writtenByteCount
            )
        }
        guard let digest = try? CloudflaredInstallStore.sha256(ofFileAt: destination),
              digest == artifact.executableSHA256 else {
            try? FileManager.default.removeItem(at: destination)
            throw CloudflaredArchiveError.executableHashMismatch
        }

        // Executable permission is needed before the signature can be checked
        // the same way it will be at launch.
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        let trust = signatureReader.signatureTrust(atPath: destination.path)
        guard case .developerID(let team, _) = trust, team == expectedTeamIdentifier else {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try? FileManager.default.removeItem(at: destination)
            throw CloudflaredArchiveError.signatureMismatch("expected Developer ID team \(expectedTeamIdentifier)")
        }
    }

    // MARK: - Archive verification

    static func loadVerifiedArchive(at url: URL, artifact: CloudflaredArtifact) throws -> [UInt8] {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? -1
        guard byteCount == artifact.archiveByteCount else {
            throw CloudflaredArchiveError.archiveSizeMismatch(expected: artifact.archiveByteCount, actual: byteCount)
        }
        guard let digest = try? CloudflaredInstallStore.sha256(ofFileAt: url), digest == artifact.archiveSHA256 else {
            throw CloudflaredArchiveError.archiveHashMismatch
        }
        guard let data = try? Data(contentsOf: url) else {
            throw CloudflaredArchiveError.malformedArchive("the file could not be read")
        }
        return [UInt8](data)
    }

    // MARK: - gzip

    /// Hand-parsed gzip container around a Compression-framework raw inflate,
    /// capped at the published uncompressed size and checked against the
    /// container's own CRC-32 and length trailer.
    static func gunzip(_ bytes: [UInt8], maxOutputByteCount: Int) throws -> [UInt8] {
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else {
            throw CloudflaredArchiveError.notGzip
        }
        guard bytes[2] == 0x08 else {
            throw CloudflaredArchiveError.notGzip
        }
        let flags = bytes[3]
        var offset = 10

        if flags & 0x04 != 0 {  // FEXTRA
            guard bytes.count >= offset + 2 else { throw CloudflaredArchiveError.notGzip }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {  // FNAME
            guard let terminator = bytes[offset...].firstIndex(of: 0) else { throw CloudflaredArchiveError.notGzip }
            offset = terminator + 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            guard let terminator = bytes[offset...].firstIndex(of: 0) else { throw CloudflaredArchiveError.notGzip }
            offset = terminator + 1
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
        }
        guard offset < bytes.count - 8 else {
            throw CloudflaredArchiveError.notGzip
        }

        let deflated = Array(bytes[offset..<(bytes.count - 8)])
        let inflated = try inflate(deflated, maxOutputByteCount: maxOutputByteCount)

        let trailerStart = bytes.count - 8
        let expectedCRC = littleEndianUInt32(bytes, at: trailerStart)
        let expectedSize = littleEndianUInt32(bytes, at: trailerStart + 4)
        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize else {
            throw CloudflaredArchiveError.gzipTrailerMismatch("the unpacked length does not match the archive")
        }
        guard crc32(inflated) == expectedCRC else {
            throw CloudflaredArchiveError.gzipTrailerMismatch("the CRC-32 does not match the archive")
        }
        return inflated
    }

    private static func inflate(_ deflated: [UInt8], maxOutputByteCount: Int) throws -> [UInt8] {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw CloudflaredArchiveError.inflateFailed("the decompressor could not start")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 1 << 16
        var output = [UInt8]()
        output.reserveCapacity(min(maxOutputByteCount, 1 << 22))
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var finished = false

        try deflated.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else {
                throw CloudflaredArchiveError.inflateFailed("the archive body is empty")
            }
            stream.src_ptr = base
            stream.src_size = source.count

            while !finished {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { destination -> compression_status in
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    guard output.count + produced <= maxOutputByteCount else {
                        throw CloudflaredArchiveError.inflateOverflow
                    }
                    output.append(contentsOf: buffer[0..<produced])
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    finished = true
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 {
                        throw CloudflaredArchiveError.inflateFailed("the archive body ended early")
                    }
                default:
                    throw CloudflaredArchiveError.inflateFailed("the archive body is corrupt")
                }
            }
        }
        return output
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - USTAR

    /// Accepts exactly one regular-file entry with the expected name and size,
    /// followed by nothing but zero padding.
    static func singlePayload(
        inTar tar: [UInt8],
        expectedEntryName: String,
        expectedByteCount: Int
    ) throws -> ArraySlice<UInt8> {
        guard tar.count >= blockSize * 3, tar.count % blockSize == 0 else {
            throw CloudflaredArchiveError.malformedArchive("its length is not a whole number of 512-byte blocks")
        }
        let header = Array(tar[0..<blockSize])

        guard checksumMatches(header) else {
            throw CloudflaredArchiveError.malformedArchive("the entry header checksum is wrong")
        }

        let magic = string(header, at: 257, count: 6)
        let version = Array(header[263..<265])
        guard magic == "ustar", header[262] == 0, version == [0x30, 0x30] else {
            // "ustar  \0" is GNU tar's variant; PAX/GNU extensions are refused.
            throw CloudflaredArchiveError.rejectedEntry("only plain USTAR archives are accepted")
        }

        let typeFlag = header[156]
        guard typeFlag == UInt8(ascii: "0") || typeFlag == 0 else {
            let name = String(UnicodeScalar(typeFlag))
            throw CloudflaredArchiveError.rejectedEntry("entry type \"\(name)\" is not a plain file")
        }

        guard header[345..<500].allSatisfy({ $0 == 0 }) else {
            throw CloudflaredArchiveError.rejectedEntry("prefixed entry paths are not accepted")
        }
        guard header[157..<257].allSatisfy({ $0 == 0 }) else {
            throw CloudflaredArchiveError.rejectedEntry("linked entries are not accepted")
        }

        let name = string(header, at: 0, count: 100)
        guard name == expectedEntryName else {
            throw CloudflaredArchiveError.rejectedEntry("the archive holds \"\(name)\", not \"\(expectedEntryName)\"")
        }

        guard let size = octal(header, at: 124, count: 12) else {
            throw CloudflaredArchiveError.malformedArchive("the entry size could not be read")
        }
        guard size == expectedByteCount else {
            throw CloudflaredArchiveError.executableSizeMismatch(expected: expectedByteCount, actual: size)
        }

        let paddedSize = ((size + blockSize - 1) / blockSize) * blockSize
        guard tar.count >= blockSize + paddedSize + blockSize * 2 else {
            throw CloudflaredArchiveError.malformedArchive("it ends before the end-of-archive marker")
        }
        guard tar[(blockSize + size)...].allSatisfy({ $0 == 0 }) else {
            throw CloudflaredArchiveError.rejectedEntry("the archive holds more than one entry")
        }
        return tar[blockSize..<(blockSize + size)]
    }

    private static func checksumMatches(_ header: [UInt8]) -> Bool {
        guard let declared = octal(header, at: 148, count: 8) else { return false }
        var unsigned = 0
        var signed = 0
        for (index, byte) in header.enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return declared == unsigned || declared == signed
    }

    private static func string(_ header: [UInt8], at offset: Int, count: Int) -> String {
        let field = header[offset..<(offset + count)]
        let trimmed = field.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func octal(_ header: [UInt8], at offset: Int, count: Int) -> Int? {
        let field = header[offset..<(offset + count)]
        var value = 0
        var sawDigit = false
        for byte in field {
            if byte == 0 || byte == UInt8(ascii: " ") {
                if sawDigit { break }
                continue
            }
            guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) else { return nil }
            value = value * 8 + Int(byte - UInt8(ascii: "0"))
            sawDigit = true
        }
        return sawDigit ? value : nil
    }
}
