// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import XodusPreview

private actor FreshResultTransport: PCGamesTransport {
    private var omitted = false
    private(set) var requests = 0

    func omitProduct() { omitted = true }

    func send(_ request: URLRequest) throws -> PCGamesHTTPResponse {
        requests += 1
        if omitted {
            return PCGamesHTTPResponse(status: 200, data: Data(#"{"Products":[]}"#.utf8))
        }
        return PCGamesHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: [
            "Products": [[
                "ProductId": "FIXTURE00001", "ProductType": "Game",
                "LocalizedProperties": [["ProductTitle": "Fresh result fixture", "Images": []]],
                "Properties": ["Categories": ["Games"]],
                "DisplaySkuAvailabilities": [[
                    "Sku": ["Properties": ["Packages": [[
                        "PlatformDependencies": [["PlatformName": "Windows.Desktop"]]
                    ]]]]
                ]]
            ]]
        ]))
    }
}

final class CatalogFreshResultChecks: XCTestCase {
    @MainActor
    func testFreshOmissionDoesNotReturnRetainedPCDisplayFact() async throws {
        let transport = FreshResultTransport()
        let catalogue = LibraryCatalogArtwork(transport: transport)
        let first = await catalogue.load(ids: ["FIXTURE00001"], market: "US", language: "en-US", refresh: true)
        XCTAssertTrue(first?.images["FIXTURE00001"]?.facts.pcPackageListed == true)
        await transport.omitProduct()
        let second = await catalogue.load(ids: ["FIXTURE00001"], market: "US", language: "en-US", refresh: true)
        XCTAssertNotNil(second)
        XCTAssertNil(second?.images["FIXTURE00001"])
        XCTAssertTrue(catalogue.images["FIXTURE00001"]?.facts.pcPackageListed == true)
        let requests = await transport.requests
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testSourceBoundPrivacyChecks() throws {
        try InstalledProductAccessChecks.checkLogging { passed, message in
            XCTAssertTrue(passed, message)
        }
    }
}
