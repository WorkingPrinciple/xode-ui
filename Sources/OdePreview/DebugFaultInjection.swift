// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import OdeManagement

/// Development-only service fault injection for native recovery observation (REQ-12). Set
/// `ODE_DEBUG_FAULT_FILE` at launch; while that file exists, each seam named on one of its lines
/// (`catalog`, `account`, `descriptors`, or `all`) fails as an unreachable service. Removing the file
/// restores normal requests mid-session. Shipping builds compile it to a no-op.
enum DebugFaultInjection {
    enum Seam: String { case catalog, account, descriptors }

    static func check(_ seam: Seam) throws {
#if !ODE_SHIPPING
        guard active(seam, environment: ProcessInfo.processInfo.environment) else { return }
        throw ManagementError.backendError("NETWORK_UNAVAILABLE", retryable: true)
#endif
    }

    static func checkHTTP() throws {
#if !ODE_SHIPPING
        guard active(.descriptors, environment: ProcessInfo.processInfo.environment) else { return }
        throw PCGamesError.transport
#endif
    }

    static func active(_ seam: Seam, environment: [String: String]) -> Bool {
#if ODE_SHIPPING
        return false
#else
        guard let path = environment["ODE_DEBUG_FAULT_FILE"], !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let seams = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return seams.contains(seam.rawValue) || seams.contains("all")
#endif
    }
}
