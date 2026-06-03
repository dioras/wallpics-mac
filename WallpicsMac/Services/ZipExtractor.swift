import Foundation
import Compression

/// Minimal, dependency-free, sandbox-safe ZIP reader. The backend ships shader wallpapers as a
/// .zip containing a single `.msl`/`.metal` file, and a sandboxed app can't shell out to `unzip`,
/// so we parse the archive ourselves: read the central directory, then inflate each entry
/// (STORE or DEFLATE). DEFLATE uses Apple's Compression framework (`COMPRESSION_ZLIB` decodes the
/// raw DEFLATE stream ZIP uses). macOS resource-fork entries (`__MACOSX/…`, `._name`) are skipped.
enum ZipExtractor {
    struct Entry {
        let name: String
        let data: Data
    }

    private static let eocdSig = 0x06054b50
    private static let centralSig = 0x02014b50
    private static let localSig = 0x04034b50

    /// All real file entries in the archive (directories and macOS metadata excluded).
    static func entries(from zipData: Data) -> [Entry] {
        let b = [UInt8](zipData)
        guard b.count > 22 else { return [] }

        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24) }

        // Locate End Of Central Directory (scan back over the optional comment, max 64KB).
        var eocd = -1
        let minStart = max(0, b.count - 22 - 65_536)
        var i = b.count - 22
        while i >= minStart {
            if u32(i) == eocdSig { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }

        let count = u16(eocd + 10)
        var p = u32(eocd + 16)            // central directory offset
        var result: [Entry] = []

        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == centralSig else { break }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let uncompSize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let localOffset = u32(p + 42)
            let nameBytes = Array(b[(p + 46)..<min(p + 46 + nameLen, b.count)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            let base = name.split(separator: "/").last.map(String.init) ?? name
            if name.hasSuffix("/") || name.hasPrefix("__MACOSX") || base.hasPrefix("._") { continue }

            guard localOffset + 30 <= b.count, u32(localOffset) == localSig else { continue }
            let lNameLen = u16(localOffset + 26)
            let lExtraLen = u16(localOffset + 28)
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            guard compSize >= 0, dataStart + compSize <= b.count else { continue }
            let comp = Data(b[dataStart..<(dataStart + compSize)])

            let out: Data?
            switch method {
            case 0: out = comp                                   // STORE
            case 8: out = inflate(comp, expectedSize: uncompSize) // DEFLATE
            default: out = nil
            }
            if let out { result.append(Entry(name: base, data: out)) }
        }
        return result
    }

    /// Extract the first entry whose extension matches, writing it to `directory`. Returns its URL.
    static func extractFirstFile(from zipData: Data, extensions: Set<String>, to directory: URL, baseName: String) -> URL? {
        let all = entries(from: zipData)
        guard let match = all.first(where: { extensions.contains(($0.name as NSString).pathExtension.lowercased()) })
                ?? all.first
        else { return nil }
        let ext = (match.name as NSString).pathExtension.lowercased()
        let dest = directory.appendingPathComponent("\(baseName).\(ext.isEmpty ? "msl" : ext)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try match.data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return data.isEmpty ? Data() : nil }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            data.withUnsafeBytes { srcRaw -> Int in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, expectedSize, srcPtr, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }
}
