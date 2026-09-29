import Foundation

enum NativeArchiveError: LocalizedError {
    case unsupported(String)
    case bzip(String)
    case tar(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .bzip(let s): return s
        case .tar(let s): return s
        }
    }
}

enum NativeModelArchive {
    static func install(from source: URL, to destination: URL, progress: @escaping (Double, String) -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let lower = source.lastPathComponent.lowercased()
        if source.hasDirectoryPath {
            try copyDirectoryContents(from: source, to: destination)
            progress(1, "Model folder copied")
            return
        }

        guard lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".bz2") else {
            throw NativeArchiveError.unsupported("Select a model folder or .tar.bz2 archive.")
        }

        progress(0.02, "Opening bzip2 archive")
        let tar = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tar")
        defer { try? fm.removeItem(at: tar) }

        try decompressBzip2(source: source, destination: tar) { fraction in
            progress(0.05 + fraction * 0.70, "Decompressing archive")
        }
        try extractTar(source: tar, destination: destination) { fraction in
            progress(0.75 + fraction * 0.24, "Installing model files")
        }
        try flattenSingleTopDirectory(destination)
        progress(1, "Model installed")
    }

    private static func decompressBzip2(source: URL, destination: URL, progress: (Double) -> Void) throws {
        guard let input = fopen(source.path, "rb") else {
            throw NativeArchiveError.bzip("Could not open \(source.lastPathComponent)")
        }
        defer { fclose(input) }

        guard let output = fopen(destination.path, "wb") else {
            throw NativeArchiveError.bzip("Could not create temporary TAR file")
        }
        defer { fclose(output) }

        let total = ((try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.doubleValue ?? 0
        var bzError: Int32 = BZ_OK
        guard let bz = BZ2_bzReadOpen(&bzError, input, 0, 0, nil, 0), bzError == BZ_OK else {
            throw NativeArchiveError.bzip("BZ2_bzReadOpen failed (\(bzError))")
        }
        defer {
            var closeError: Int32 = BZ_OK
            BZ2_bzReadClose(&closeError, bz)
        }

        var buffer = [Int8](repeating: 0, count: 256 * 1024)
        while true {
            let read = BZ2_bzRead(&bzError, bz, &buffer, Int32(buffer.count))
            if read > 0 {
                let written = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return fwrite(base, 1, Int(read), output)
                }
                if written != Int(read) {
                    throw NativeArchiveError.bzip("Failed writing temporary TAR")
                }
            }

            if total > 0 {
                progress(min(1, max(0, Double(ftell(input)) / total)))
            }

            if bzError == BZ_STREAM_END { break }
            if bzError != BZ_OK {
                throw NativeArchiveError.bzip("Bzip2 decompression failed (\(bzError))")
            }
        }
    }

    private static func extractTar(source: URL, destination: URL, progress: (Double) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let total = Double((try? handle.seekToEnd()) ?? 0)
        try handle.seek(toOffset: 0)

        while true {
            let header = try handle.read(upToCount: 512) ?? Data()
            if header.isEmpty { break }
            guard header.count == 512 else {
                throw NativeArchiveError.tar("Truncated TAR header")
            }
            if header.allSatisfy({ $0 == 0 }) { break }

            let name = tarString(header, 0, 100)
            let prefix = tarString(header, 345, 155)
            let rawPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let sizeText = tarString(header, 124, 12).trimmingCharacters(in: .whitespacesAndNewlines)
            let size = Int64(sizeText.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")), radix: 8) ?? 0
            let type = header[156]

            let safe = sanitizeTarPath(rawPath)
            let target = destination.appendingPathComponent(safe)
            if !safe.isEmpty {
                if type == 53 { // '5' directory
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } else if type == 0 || type == 48 { // regular file
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: target.path, contents: nil)
                    let out = try FileHandle(forWritingTo: target)
                    var remaining = size
                    while remaining > 0 {
                        let n = Int(min(Int64(1024 * 1024), remaining))
                        guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else {
                            try? out.close()
                            throw NativeArchiveError.tar("Unexpected end of TAR while reading \(safe)")
                        }
                        try out.write(contentsOf: chunk)
                        remaining -= Int64(chunk.count)
                    }
                    try out.close()

                    let padding = (512 - (size % 512)) % 512
                    if padding > 0 { try handle.seek(toOffset: handle.offsetInFile + UInt64(padding)) }
                } else {
                    let skip = size + ((512 - (size % 512)) % 512)
                    if skip > 0 { try handle.seek(toOffset: handle.offsetInFile + UInt64(skip)) }
                }
            } else {
                let skip = size + ((512 - (size % 512)) % 512)
                if skip > 0 { try handle.seek(toOffset: handle.offsetInFile + UInt64(skip)) }
            }

            if total > 0 { progress(min(1, Double(handle.offsetInFile) / total)) }
        }
    }

    private static func tarString(_ data: Data, _ start: Int, _ length: Int) -> String {
        guard start < data.count else { return "" }
        let end = min(data.count, start + length)
        let bytes = data[start..<end].prefix { $0 != 0 }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    private static func sanitizeTarPath(_ input: String) -> String {
        let pieces = input.split(separator: "/").map(String.init)
        var safe: [String] = []
        for p in pieces {
            if p.isEmpty || p == "." { continue }
            if p == ".." { return "" }
            safe.append(p)
        }
        return safe.joined(separator: "/")
    }

    private static func flattenSingleTopDirectory(_ root: URL) throws {
        let fm = FileManager.default
        var children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        children.removeAll { $0.lastPathComponent.hasPrefix(".") }
        guard children.count == 1,
              (try children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return }

        let nested = children[0]
        let nestedChildren = try fm.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil)
        for child in nestedChildren {
            let dst = root.appendingPathComponent(child.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: child, to: dst)
        }
        try fm.removeItem(at: nested)
    }

    private static func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try fm.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }
}
