// SPDX-License-Identifier: GPL-3.0-only

enum LibraryContentStatus {
    enum Request: Equatable {
        case idle
        case loading
        case cancelled
        case succeeded
        case partial(String)
        case failed(String)
    }

    enum Results: Equatable {
        case none
        case current
        case retainedSameScope
        case retainedDifferentScope

        var isUsable: Bool {
            switch self {
            case .current, .retainedSameScope: true
            case .none, .retainedDifferentScope: false
            }
        }
    }

    enum State: Equatable {
        case loading
        case empty
        case content
        case partial(message: String, retainsContent: Bool)
        case cancelled
        case failed(String)
        case retainedAfterFailure(String)

        var retainsContent: Bool {
            switch self {
            case .content, .retainedAfterFailure: true
            case .partial(_, let retainsContent): retainsContent
            case .loading, .empty, .cancelled, .failed: false
            }
        }

        var offersRetry: Bool {
            switch self {
            case .partial, .cancelled, .failed, .retainedAfterFailure: true
            case .loading, .empty, .content: false
            }
        }

        var message: String? {
            switch self {
            case .partial(let message, _), .failed(let message), .retainedAfterFailure(let message): message
            case .loading, .empty, .content, .cancelled: nil
            }
        }
    }

    static func resolve(request: Request, results: Results) -> State {
        switch request {
        case .idle, .succeeded:
            return results.isUsable ? .content : .empty
        case .loading:
            return results.isUsable ? .content : .loading
        case .cancelled:
            return results.isUsable ? .content : .cancelled
        case .partial(let message):
            return .partial(message: message, retainsContent: results.isUsable)
        case .failed(let message):
            return results.isUsable ? .retainedAfterFailure(message) : .failed(message)
        }
    }

    static func checkAll(_ check: (Bool, String) -> Void) {
        let cases: [(Request, Results, State)] = [
            (.idle, .none, .empty),
            (.idle, .current, .content),
            (.idle, .retainedSameScope, .content),
            (.idle, .retainedDifferentScope, .empty),
            (.loading, .none, .loading),
            (.loading, .current, .content),
            (.loading, .retainedSameScope, .content),
            (.loading, .retainedDifferentScope, .loading),
            (.cancelled, .none, .cancelled),
            (.cancelled, .current, .content),
            (.cancelled, .retainedSameScope, .content),
            (.cancelled, .retainedDifferentScope, .cancelled),
            (.succeeded, .none, .empty),
            (.succeeded, .current, .content),
            (.succeeded, .retainedSameScope, .content),
            (.succeeded, .retainedDifferentScope, .empty),
            (.partial("Some results could not be loaded."), .none,
             .partial(message: "Some results could not be loaded.", retainsContent: false)),
            (.partial("Some results could not be loaded."), .current,
             .partial(message: "Some results could not be loaded.", retainsContent: true)),
            (.partial("Some results could not be loaded."), .retainedSameScope,
             .partial(message: "Some results could not be loaded.", retainsContent: true)),
            (.partial("Some results could not be loaded."), .retainedDifferentScope,
             .partial(message: "Some results could not be loaded.", retainsContent: false)),
            (.failed("The service is unavailable."), .none, .failed("The service is unavailable.")),
            (.failed("The service is unavailable."), .current,
             .retainedAfterFailure("The service is unavailable.")),
            (.failed("The service is unavailable."), .retainedSameScope,
             .retainedAfterFailure("The service is unavailable.")),
            (.failed("The service is unavailable."), .retainedDifferentScope,
             .failed("The service is unavailable."))
        ]

        for (request, results, expected) in cases {
            check(resolve(request: request, results: results) == expected,
                  "\(request) + \(results) resolves to \(expected)")
        }

        check(State.retainedAfterFailure("Refresh failed.").retainsContent,
              "Same-scope service failure retains prior content")
        check(State.retainedAfterFailure("Refresh failed.").offersRetry,
              "Retained content offers actionable retry")
        check(State.failed("Refresh failed.").offersRetry,
              "Empty service failure offers actionable retry")
        check(State.cancelled.offersRetry, "Cancellation remains distinct and can be retried")
        check(!State.empty.retainsContent && !State.empty.offersRetry,
              "A successful empty result is neither a failure nor a retained result")
    }
}
