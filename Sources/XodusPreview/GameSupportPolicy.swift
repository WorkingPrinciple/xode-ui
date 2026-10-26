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
        let blockers = formats.filter { !["", "MSIXVC", "UNKNOWN", "UNSPECIFIED", "WIN32"].contains($0) }
        if !blockers.isEmpty {
            let format = blockers.joined(separator: " / ")
            issues.append(LibraryCompatibilityIssue(kind: .packageType, title: format,
                detail: "This game comes as a \(format) package, which \(AppBrand.displayName) can't install yet.",
                source: nil))
        }
        let technology = antiCheat?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let technology, !technology.isEmpty,
           !["none", "unknown", "unspecified"].contains(technology.lowercased()) {
            issues.append(LibraryCompatibilityIssue(kind: .antiCheat, title: "Uses \(technology)",
                detail: "Games that use \(technology) can't run in \(AppBrand.displayName) yet.", source: nil))
        }
        return issues
    }
}
