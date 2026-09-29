import Foundation
@_implementationOnly import libbz2
import SWCompression

enum ArchiveExtractor {
    private static let chunkSize = 1 << 16

    static func extractTarBz2(from source: URL, to destination: URL, progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let tempTar = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tar")
        defer { try? fm.removeItem(at: tempTar) }

        try bunzip(source: source, destination: tempTar, progress: progress)
        try untar(source: tempTar, destination: destination, progress: progress)
        try flattenSingleRoot(destination)
        progress(1)
    }

    private static func bunzip(source: URL, destination: URL, progress: @escaping (Double) -> Void) throws {
        guard let src = fopen(source.path, "rb") else { throw err(10, "Cannot open bzip2 archive") }
        defer { fclose(src) }
        guard let dst = fopen(destination.path, "wb") else { throw err(11, "Cannot create temporary tar") }
        defer { fclose(dst) }

        let sourceSize = ((try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var bzError: Int32 = BZ_OK
        guard let bz = BZ2_bzReadOpen(&bzError, src, 0, 0, nil, 0), bzError == BZ_OK else {
            throw err(12, "BZ2_bzReadOpen failed (\(bzError))")
        }

        var buffer = [Int8](repeating: 0, count: chunkSize)
        while true {
            let count = BZ2_bzRead(&bzError, bz, &buffer, Int32(buffer.count))
            if bzError != BZ_OK && bzError != BZ_STREAM_END {
                BZ2_bzReadClose(&bzError, bz)
                throw err(13, "bzip2 decode failed (\(bzError))")
            }
            if count > 0 {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return fwrite(base, 1, Int(count), dst)
                }
                guard written == Int(count) else {
                    BZ2_bzReadClose(&bzError, bz)
                    throw err(14, "Failed writing decompressed tar")
                }
            }
            if sourceSize > 0 {
                progress(min(0.78, (Double(ftell(src)) / Double(sourceSize)) * 0.78))
            }
            if bzError == BZ_STREAM_END { break }
        }
        BZ2_bzReadClose(&bzError, bz)
    }

    private static func untar(source: URL, destination: URL, progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var reader = TarReader(fileHandle: handle)

        while let entry = try reader.read() {
            let name = sanitize(entry.info.name)
            if name.isEmpty { continue }
            let dest = destination.appendingPathComponent(name)
            switch entry.info.type {
            case .directory:
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            case .regular:
                guard let data = entry.data else { continue }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: remapKnownSherpaFilename(dest), options: .atomic)
            default:
                break
            }
            if size > 0 {
                progress(0.78 + min(0.21, (Double(handle.offsetInFile) / Double(size)) * 0.21))
            }
        }
    }

    private static func sanitize(_ raw: String) -> String {
        var value = raw
        while value.hasPrefix("/") { value.removeFirst() }
        if value.hasPrefix("./") { value.removeFirst(2) }
        let safe = value.split(separator: "/").filter { $0 != ".." && $0 != "." }.map(String.init)
        return safe.joined(separator: "/")
    }

    private static func flattenSingleRoot(_ destination: URL) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        guard children.count == 1,
              (try? children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return }

        for item in try fm.contentsOfDirectory(at: children[0], includingPropertiesForKeys: nil) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: item, to: target)
        }
        try fm.removeItem(at: children[0])
    }

    private static func remapKnownSherpaFilename(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        switch url.lastPathComponent {
        case "encoder-epoch-99-avg-1.onnx": return parent.appendingPathComponent("encoder.onnx")
        case "decoder-epoch-99-avg-1.onnx": return parent.appendingPathComponent("decoder.onnx")
        case "joiner-epoch-99-avg-1.int8.onnx": return parent.appendingPathComponent("joiner.onnx")
        default: return url
        }
    }

    private static func err(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "G2LabsArchive", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
