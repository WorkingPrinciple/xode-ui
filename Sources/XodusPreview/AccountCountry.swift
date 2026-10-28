// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI
import XodusManagement

struct XboxAccountCountry: Decodable, Equatable, Sendable {
    let countryCode: String?
    let locale: String?
    let reason: String?

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.object,
              Set(object.keys) == Set(["status", "countryCode", "locale", "source", "reason"]),
              value["source"]?.string == "xboxAccount.legalCountry" else {
            throw ManagementError.invalidPayload
        }
        switch value["status"]?.string {
        case "verified":
            guard let code = value["countryCode"]?.string, Self.normalized(code) != nil,
                  value["reason"] == .null,
                  value["locale"] == .null || value["locale"]?.string.map({
                      $0.range(of: "^[A-Za-z0-9]{1,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil
                          && (2...35).contains($0.utf8.count)
                  }) == true else { throw ManagementError.invalidPayload }
            countryCode = Self.normalized(code)
            locale = value["locale"]?.string
            reason = nil
        case "unknown":
            guard value["countryCode"] == .null, value["locale"] == .null,
                  let reason = value["reason"]?.string,
                  ["providerUnavailable", "responseInvalid"].contains(reason) else {
                throw ManagementError.invalidPayload
            }
            countryCode = nil
            locale = nil
            self.reason = reason
        default: throw ManagementError.invalidPayload
        }
    }

    static func normalized(_ code: String) -> String? {
        guard code.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { return nil }
        return code == "UK" ? "GB" : code
    }
}

struct AccountCountrySettings: View {
    @EnvironmentObject private var session: LiveSession
    @State private var selected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Account country", value: session.accountCountryLabel)
            if let error = session.accountCountryError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            if session.accountCountryChecking {
                ProgressView("Checking account country").controlSize(.small)
            } else if session.accountCountryNeedsConfirmation {
                Text("Xbox couldn't confirm your account country. Choose the country on your Microsoft account to use for games. This doesn't change your Microsoft account.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Country", selection: $selected) {
                    Text("Choose country").tag("")
                    ForEach(Locale.Region.isoRegions.map(\.identifier).filter {
                        $0.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
                    }.sorted {
                        countryName($0).localizedStandardCompare(countryName($1)) == .orderedAscending
                    }, id: \.self) { code in
                        Text(countryName(code)).tag(code)
                    }
                }
                Button("Confirm account country") { session.confirmAccountCountry(selected) }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("xodus.account.confirmCountry")
            }
            if session.hasConfirmedSignIn, !session.accountCountryChecking {
                Button("Check account country again") {
                    MicrosoftReadContext.explicit { Task { await session.refreshAccountCountry() } }
                }
            }
        }
        .onChange(of: session.accountHash) { _, _ in selected = "" }
    }

    private func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}
