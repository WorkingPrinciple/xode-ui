// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@MainActor
enum HostOutputFence {
    static func drain(_ pending: Task<Void, Never>?, failed: () -> Bool) async throws {
        await pending?.value
        guard !failed() else { throw HostFailure.channelClosed }
    }
}
