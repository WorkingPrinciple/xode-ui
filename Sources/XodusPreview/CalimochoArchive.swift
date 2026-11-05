// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

enum CalimochoArchive {
    // Validate the pinned ZIP's directory before invoking ditto. No archive may create
    // a symlink parent, escape the single release folder or exceed its published size.
    static func validate(_ data: Data, release: CalimochoRelease) throws {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        func u32(_ i: Int) -> Int { u16(i) | (u16(i + 2) << 16) }
        func require(_ condition: Bool) throws {
            guard condition else { throw CalimochoInstallFailure.archive }
        }
        try require(bytes.count >= 22)
        var end: Int?
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if u32(i) == 0x06054b50, i + 22 + u16(i + 20) == bytes.count { end = i; break }
        }
        guard let end else { throw CalimochoInstallFailure.archive }
        let count = u16(end + 10), start = u32(end + 16)
        try require(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == count
                    && count > 0 && count <= 4096 && start <= end && u32(end + 12) == end - start)
        var cursor = start, expanded: Int64 = 0
        var paths: [String: Int] = [:]
        var normalized = Set<String>()
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            try require(cursor <= end - 46 && u32(cursor) == 0x02014b50)
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let nameSize = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32)
            let size = u32(cursor + 24), compressed = u32(cursor + 20), offset = u32(cursor + 42)
            try require(flags & ~0x080e == 0 && [0, 8].contains(method) && u16(cursor + 34) == 0
                        && cursor + 46 + nameSize + extra + comment <= end)
            let nameBytes = bytes[(cursor + 46)..<(cursor + 46 + nameSize)]
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty,
                  name.utf8.count <= 1024, !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw CalimochoInstallFailure.archive
            }
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            try require(parts.first.map(String.init) == release.rawValue
                        && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
                        && normalized.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted)
            let mode = (u32(cursor + 38) >> 16) & 0xf000
            let unix = u16(cursor + 4) >> 8 == 3
            let kind = unix && mode != 0 ? mode : (directory ? 0x4000 : 0x8000)
            try require([0x4000, 0x8000, 0xa000].contains(kind) && (kind == 0x4000) == directory
                        && (!directory || size == 0) && (kind != 0xa000 || size <= 4096))
            expanded += Int64(size)
            try require(expanded <= release.expandedBytes && offset <= start - 30
                        && u32(offset) == 0x04034b50 && u16(offset + 6) == flags
                        && u16(offset + 8) == method && u16(offset + 26) == nameSize
                        && offset + 30 + nameSize + u16(offset + 28) <= start)
            try require(bytes[(offset + 30)..<(offset + 30 + nameSize)] == nameBytes)
            let dataStart = offset + 30 + nameSize + u16(offset + 28)
            try require(compressed <= start - dataStart)
            let dataEnd = dataStart + compressed
            var recordEnd = dataEnd
            if flags & 8 == 0 {
                try require(u32(offset + 14) == u32(cursor + 16)
                            && u32(offset + 18) == compressed && u32(offset + 22) == size)
            } else {
                let descriptor = dataEnd + (dataEnd + 4 <= start && u32(dataEnd) == 0x08074b50 ? 4 : 0)
                try require(descriptor + 12 <= start && u32(descriptor) == u32(cursor + 16)
                            && u32(descriptor + 4) == compressed && u32(descriptor + 8) == size)
                recordEnd = descriptor + 12
            }
            paths[path] = kind
            ranges.append(offset..<recordEnd)
            cursor += 46 + nameSize + extra + comment
        }
        try require(cursor == end && expanded == release.expandedBytes && paths[release.rawValue] == 0x4000)
        for path in paths.keys {
            let parts = path.split(separator: "/")
            for count in 1..<parts.count {
                if let kind = paths[parts.prefix(count).joined(separator: "/")] { try require(kind == 0x4000) }
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        for pair in zip(ranges, ranges.dropFirst()) { try require(pair.0.upperBound <= pair.1.lowerBound) }
    }

    static func validateExtracted(root: URL, release: CalimochoRelease) throws {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard children.count == 1, children[0].lastPathComponent == release.rawValue else {
            throw CalimochoInstallFailure.archive
        }
        let engine = children[0]
        try GameScriptFiles.checkPath(engine)
        var enumerationError: Error?
        guard let files = FileManager.default.enumerator(at: engine, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CalimochoInstallFailure.archive
        }
        var count = 0
        while let file = files.nextObject() as? URL {
            try Task.checkCancellation()
            count += 1
            guard count <= 4096 else { throw CalimochoInstallFailure.archive }
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw CalimochoInstallFailure.archive }
            let type = info.st_mode & S_IFMT
            guard [S_IFDIR, S_IFREG, S_IFLNK].contains(type) else { throw CalimochoInstallFailure.archive }
            if type == S_IFLNK {
                guard let resolved = realpath(file.path, nil) else { throw CalimochoInstallFailure.archive }
                defer { free(resolved) }
                guard String(cString: resolved).hasPrefix(engine.path + "/") else {
                    throw CalimochoInstallFailure.archive
                }
            }
        }
        if let enumerationError { throw enumerationError }
    }
}
