// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusCore

extension Checks {
    /// M1: evidence-grounded package-type detection. Every case pins gathered
    /// file/manifest evidence to its expected neutral format verdict, and the
    /// classification round-trips through Codable so persisted evidence is stable.
    func packageTypeChecks() throws {
        let cases = try fixture("package-types-v1")["cases"]?.array ?? []
        check(cases.count >= 8, "Package-type corpus pins the format matrix across evidence combinations")
        for value in cases {
            guard let name = value["name"]?.string,
                  let expectedRaw = value["expected"]?.string,
                  let expected = PackageType(rawValue: expectedRaw),
                  let evidenceValue = value["evidence"] else {
                check(false, "Package-type case is well formed")
                continue
            }
            let evidence = try evidenceValue.decode(PackageTypeEvidence.self)
            check(PackageType.classify(evidence) == expected,
                  "Package-type detection: \(name) classifies as \(expected.label) from file evidence")
            let round = try JSONDecoder().decode(PackageTypeEvidence.self,
                from: JSONEncoder().encode(evidence))
            check(round == evidence && PackageType.classify(round) == expected,
                  "Package-type evidence round-trips through Codable without changing the verdict: \(name)")
        }
        // A fully empty evidence record is Unknown, never silently a supported format.
        check(PackageType.classify(PackageTypeEvidence()) == .unknown,
              "Absent package evidence is Unknown, not an invented format")
        // Full-trust universal manifests are packaged Win32 (Appx), not sandboxed UWP.
        check(PackageType.classify(PackageTypeEvidence(hasAppxManifest: true,
            targetDeviceFamilies: ["Windows.Universal"], declaresFullTrustEntryPoint: true)) == .appx,
              "A universal manifest declaring full trust is packaged Win32 (Appx), not UWP")
        check(PackageType.classify(PackageTypeEvidence(hasAppxManifest: true,
            targetDeviceFamilies: ["Windows.Universal"])) == .appx,
              "Device targeting alone never invents a UWP application model")
        for value in try fixture("package-types-v1")["manifests"]?.array ?? [] {
            guard let name = value["name"]?.string, let xml = value["xml"]?.string,
                  let expected = value["expected"]?.string.flatMap(PackageType.init(rawValue:)) else {
                check(false, "Manifest fixture is well formed"); continue
            }
            let facts = try AppxManifestFacts.parse(Data(xml.utf8))
            let evidence = PackageTypeEvidence(hasAppxManifest: true,
                targetDeviceFamilies: facts.targetDeviceFamilies,
                declaresFullTrustEntryPoint: facts.fullTrust, declaresUWPApplication: facts.uwpApplication)
            check(PackageType.classify(evidence) == expected, "Actual manifest XML: \(name)")
        }
        for xml in ["", "<Other/>", "<Package/>", "<Package><Applications>",
                    "<!DOCTYPE Package [<!ENTITY e 'expanded'>]><Package><Applications><Application EntryPoint='Fixture.App'/></Applications>&e;</Package>",
                    "<Package xmlns='urn:foreign'><Applications><Application EntryPoint='Fake.App'/></Applications></Package>",
                    "<Package xmlns:m='http://schemas.microsoft.com/appx/manifest/uap/windows10/10' xmlns:n='http://schemas.microsoft.com/appx/manifest/uap/windows10/10'><Applications><Application m:RuntimeBehavior='windowsApp' n:RuntimeBehavior='win32App'/></Applications></Package>",
                    "<Package xmlns:m='http://schemas.microsoft.com/appx/manifest/uap/windows10/10'><Applications><Application m:RuntimeBehavior='windowsApp' m:TrustLevel='mediumIL'/></Applications></Package>"] {
            do { _ = try AppxManifestFacts.parse(Data(xml.utf8)); check(false, "Invalid manifest refused") }
            catch { check(error is AppxManifestError, "Invalid manifest refused") }
        }
        var container = Data(repeating: 0, count: 4096)
        container.replaceSubrange(0x200..<0x208, with: Data("msft-xvd".utf8))
        check(PackageType.hasMSIXVCHeader(container), "MSIXVC requires an observed MSFT-XVD header")
        check(!PackageType.hasMSIXVCHeader(Data(container.prefix(1024))),
              "Truncated container header is not MSIXVC evidence")
        container[0x200] = 0
        check(!PackageType.hasMSIXVCHeader(container), "Incorrect container magic is refused")
        var pe = Data(repeating: 0, count: 128)
        pe.replaceSubrange(0..<2, with: Data([0x4d, 0x5a]))
        pe[0x3c] = 64
        pe.replaceSubrange(64..<68, with: Data([0x50, 0x45, 0, 0]))
        check(PackageType.hasPEHeader(pe), "Win32 file evidence requires DOS and PE headers")
        pe[0x3f] = 0xff
        check(!PackageType.hasPEHeader(pe), "Out-of-bounds PE header offset is refused")
        var encrypted = Data(repeating: 0, count: 64)
        encrypted.replaceSubrange(0..<4, with: Data("EXPH".utf8))
        encrypted[4] = 64
        check(PackageType.hasEncryptedAppxHeader(encrypted), "Encrypted Appx requires content signature and bounded header")
        encrypted[4] = 65
        check(!PackageType.hasEncryptedAppxHeader(encrypted), "Truncated encrypted Appx header is not format evidence")
        check(!PackageType.hasEncryptedAppxHeader(Data()), "Empty encrypted-package placeholder is not evidence")
    }
}
