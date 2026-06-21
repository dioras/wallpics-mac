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

    /// Hard cap on a single entry's uncompressed size. Widget bundle assets are small images and
    /// JSON; this stops a malicious archive from declaring a multi-GB `uncompSize` and forcing a
    /// huge allocation (decompression bomb).
    private static let maxEntryBytes = 64 * 1024 * 1024

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
            guard max(uncompSize, compSize) <= maxEntryBytes else { continue }
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

    /// Like ``entries(from:)`` but preserves each entry's full relative path inside the archive
    /// (e.g. `elevator/small/frame1.png`) instead of flattening to the base name. Widget bundles
    /// ship a nested `WidgetTemplates`-style tree, so the structure has to survive extraction.
    static func treeEntries(from zipData: Data) -> [Entry] {
        let b = [UInt8](zipData)
        guard b.count > 22 else { return [] }

        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24) }

        var eocd = -1
        let minStart = max(0, b.count - 22 - 65_536)
        var i = b.count - 22
        while i >= minStart {
            if u32(i) == eocdSig { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }

        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
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
            guard max(uncompSize, compSize) <= maxEntryBytes else { continue }
            let lNameLen = u16(localOffset + 26)
            let lExtraLen = u16(localOffset + 28)
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            guard compSize >= 0, dataStart + compSize <= b.count else { continue }
            let comp = Data(b[dataStart..<(dataStart + compSize)])

            let out: Data?
            switch method {
            case 0: out = comp
            case 8: out = inflate(comp, expectedSize: uncompSize)
            default: out = nil
            }
            if let out { result.append(Entry(name: name, data: out)) }
        }
        return result
    }

    /// Extract every file in the archive into `directory`, preserving the relative tree. Returns
    /// the number of files written. Path components are sanitised so a malicious entry can't
    /// escape `directory` via `..`.
    @discardableResult
    static func extractTree(from zipData: Data, to directory: URL) -> Int {
        let all = treeEntries(from: zipData)
        var written = 0
        let fm = FileManager.default
        for entry in all {
            let components = entry.name
                .split(separator: "/")
                .map(String.init)
                .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            guard let fileName = components.last else { continue }
            var dest = directory
            for dir in components.dropLast() { dest.appendPathComponent(dir) }
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try entry.data.write(to: dest.appendingPathComponent(fileName), options: .atomic)
                written += 1
            } catch {
                Log.cache.error("Widget bundle file write failed [\(entry.name, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        return written
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
