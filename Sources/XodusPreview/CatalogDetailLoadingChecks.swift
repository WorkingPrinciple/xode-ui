// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private actor DetailPriorityTransport: PCGamesTransport {
    let malformedPrice: Bool
    init(malformedPrice: Bool = false) { self.malformedPrice = malformedPrice }
    private(set) var started = false
    private(set) var finished = false
    private(set) var detailRequests = 0
    private var releaseBulk: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> PCGamesHTTPResponse {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = items.first(where: { $0.name == "bigIds" })?.value ?? ""
        if ids == "FIXTURE00001" {
            started = true
            await withCheckedContinuation { releaseBulk = $0 }
            finished = true
        } else {
            detailRequests += 1
        }
        var product: [String: Any] = [
                "ProductId": ids,
                "LocalizedProperties": [["ProductTitle": "Synthetic game", "Images": [],
                                         "ProductDescription": "Synthetic description."]],
                "Properties": ["Categories": ["Games"]],
        ]
        if malformedPrice {
            product["DisplaySkuAvailabilities"] = [[
                "Sku": ["SkuType": "full"],
                "Availabilities": [["OrderManagementData": ["Price": ["ListPrice": "invalid"]]]]
            ]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["Products": [product]])
        return PCGamesHTTPResponse(status: 200, data: data)
    }

    func release() { releaseBulk?.resume(); releaseBulk = nil }
}

@MainActor
enum CatalogDetailLoadingChecks {
    static func run(check: (Bool, String) -> Void) async throws {
        let transport = DetailPriorityTransport()
        let catalogue = LibraryCatalogArtwork(transport: transport)
        let bulk = Task { await catalogue.load(ids: ["FIXTURE00001"], market: "US", language: "en-US") }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await transport.started else { throw PCGamesError.transport }
        await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        let bulkFinished = await transport.finished
        check(!bulkFinished && catalogue.images["FIXTURE00002"]?.detail?.description == "Synthetic description.",
              "Selected details publish before a blocked bulk catalogue request finishes")
        await catalogue.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        let detailRequests = await transport.detailRequests
        check(detailRequests == 1, "Reopening cached selected details does not fetch them again")
        await transport.release()
        await bulk.value
        check(catalogue.images["FIXTURE00001"] != nil && catalogue.images["FIXTURE00002"] != nil,
              "Bulk artwork completion preserves independently loaded selected details")
        let changedTransport = DetailPriorityTransport()
        let changedCatalogue = LibraryCatalogArtwork(transport: changedTransport)
        let oldScope = Task {
            await changedCatalogue.load(ids: ["FIXTURE00001"], market: "US", language: "en-US")
        }
        for _ in 0..<100 {
            if await changedTransport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await changedCatalogue.loadDetail(id: "FIXTURE00002", market: "GB", language: "en-GB")
        await changedTransport.release()
        await oldScope.value
        check(changedCatalogue.images["FIXTURE00001"] == nil &&
              changedCatalogue.images["FIXTURE00002"]?.product.market == "GB",
              "Old bulk scope cannot replace selected details after a region change")
        let malformed = LibraryCatalogArtwork(transport: DetailPriorityTransport(malformedPrice: true))
        await malformed.loadDetail(id: "FIXTURE00002", market: "US", language: "en-US")
        check(malformed.images["FIXTURE00002"]?.product.title == "Synthetic game"
              && malformed.images["FIXTURE00002"]?.facts.commerce == nil
              && malformed.images["FIXTURE00002"]?.detail?.description == "Synthetic description.",
              "#40/#41: Invalid optional pricing cannot hide catalogue identity/details or manufacture a free offer")
    }
}
