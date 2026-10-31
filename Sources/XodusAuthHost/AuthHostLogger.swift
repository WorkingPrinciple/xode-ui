// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func authHostLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/xodus-authhost.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
    }
}
