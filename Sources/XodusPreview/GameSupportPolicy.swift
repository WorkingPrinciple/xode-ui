// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum GameSupportPolicy {
    static func packageFormat(observed: String?, classified: String?) -> String? {
        // Extraction can leave only a PE executable; Win32 is not its source container format.
        if observed == nil || ["win32", "unknown"].contains(observed?.lowercased() ?? "") {
            return classified ?? observed
        }
        return observed
    }

    static func issues(packageFormat: String?, antiCheat: String?) -> [LibraryCompatibilityIssue] {
        let formats = packageFormat?.split(separator: "/").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        } ?? []
        var issues: [LibraryCompatibilityIssue] = []
        if formats != ["MSIXVC"] {
            let format = packageFormat.flatMap { $0.isEmpty ? nil : $0 } ?? "Package format not identified"
            issues.append(LibraryCompatibilityIssue(kind: .packageType, title: format,
                detail: "\(format). Ode to X 0.1 supports MSIXVC packages only.", source: nil))
        }
        let technology = antiCheat?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let technology, !technology.isEmpty,
           !["none", "unknown", "unspecified"].contains(technology.lowercased()) {
            issues.append(LibraryCompatibilityIssue(kind: .antiCheat, title: "Uses \(technology)",
                detail: "\(technology) is not supported by Ode to X 0.1.", source: nil))
        }
        return issues
    }
}
