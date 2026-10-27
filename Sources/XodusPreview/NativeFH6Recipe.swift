// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XodusManagement

enum NativeFH6Recipe {
  static var enabled: Bool {
    #if XODUS_FH6_QUALIFICATION
      true
    #else
      false
    #endif
  }

  static func requireEnabled(productID: String) throws {
    if productID == self.productID, !enabled { throw NativeLaunchError.titleRecipeUnavailable }
  }

  static let id = "calimocho-06-fh6-v1"
  static let productID = "9NR1R1XWLCNB"
  static let packageIdentity = "Microsoft.ForteBaseGame"
  static let engineName = "calimocho-11.20-4.0b3-06-fh6"
  static let executable = "forzahorizon6.exe"
  static let overlaySHA256 = "c72b5cae6d3da617b482086193ffeb99616a07c18383e629f4bbec0a4b16c1f5"
  static let overlaySource = "lib/wine/x86_64-windows/d3d12_tsshim.dll"
  static let overlayDestination = "drive_c/windows/system32/d3d12.dll"

  static func validate(game: InstalledGame, engine: String) throws {
    guard game.storeId == productID || engine == engineName else { return }
    guard game.storeId == productID, game.identityName == packageIdentity, engine == engineName
    else {
      throw NativeLaunchError.titleRecipeUnavailable
    }
  }

  static func validate(profile: NativeTitleLaunchProfile) throws {
    guard profile.productID == productID, profile.engine == engineName,
      profile.executable == executable,
      profile.wineSha256 == CalimochoReleasePin.release06.wineSha256,
      profile.wineserverSha256 == CalimochoReleasePin.release06.wineserverSha256,
      profile.environment.isEmpty, profile.unsetEnvironment == nil,
      profile.shimDirectory == nil, profile.crossOverEnvironment == nil,
      profile.prefixOverlays == nil, profile.prefixRegistryImports == nil,
      profile.requiredFiles == nil, profile.dllOverrides == nil,
      profile.dllOverrideEvidence == nil, profile.preservedPrefixPath == nil,
      profile.registrySHA256 == nil, profile.provider == nil,
      profile.timeoutSeconds == nil,
      profile.noAutoDismiss == true && profile.autoDismissRules == nil
        || profile.noAutoDismiss != true && profile.autoDismissRules == "fh6-compat",
      profile.runtime?.primarySHA256
        == "a64fefb1041c476bf9b064abaf4cad6ea30559fd25b35bbe6e2ff603a23f6257",
      profile.runtime?.legacySHA256
        == "dfeea51fb0c59d91f7ad71f43a1263e8318ed89379a672a953954121014196af"
    else {
      throw NativeLaunchError.titleRecipeUnavailable
    }
  }

  static var arguments: [String] {
    ["--title-recipe", id, "--package-identity", packageIdentity]
  }

  static func prefix(root: URL) -> URL {
    root.appendingPathComponent(productID).appendingPathComponent(id)
  }

  static func environment(root: URL) -> [String: String] {
    [
      "WINELOADER": root.appendingPathComponent("bin/wine").path,
      "WINESERVER": root.appendingPathComponent("bin/wineserver").path,
      "WINEDLLOVERRIDES": "mscoree,mshtml=;windows.web=b", "WINEDEBUG": "-all",
      "CX_APPLEGPTK_LIBD3DSHARED_PATH": root.appendingPathComponent(
        "lib/external/libd3dshared.dylib"
      ).path,
      "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS": "1", "MVK_CONFIG_USE_METAL_PRIVATE_API": "1",
      "CALIMOCHO_FIX_ROSETTA_WX": "1", "CALIMOCHO_FIX_ROSETTA_MXCSR": "1",
      "CALIMOCHO_FIX_FIBER_GS": "1", "CALIMOCHO_FIX_NX_ALWAYS": "1",
      "CALIMOCHO_FIX_THREADPOOL_IO": "1", "CALIMOCHO_FIX_ICON_REPLY": "1",
      "D3DM_VENDOR_ID": "0x10de", "D3DM_DEVICE_ID": "0x2786",
      "D3DM_DEVICE_DESCRIPTION": "NVIDIA GeForce RTX 4070", "D3DM_MTL4": "0",
      "XODUS_PRIVATE_LOCAL_SAVES": "1",
      "HB_D3D12_REAL": "Z:" + root.path.replacingOccurrences(of: "/", with: "\\")
        + "\\lib\\wine\\x86_64-windows\\d3d12.dll",
    ]
  }

  static func registryData(_ engine: VerifiedCalimochoEngine) throws -> Data {
    guard engine.pin == .release06 else { throw NativeLaunchError.titleRecipeUnavailable }
    let source = engine.root.appendingPathComponent(overlaySource)
    try GameScriptFiles.checkPath(source)
    guard try CalimochoReleaseEngines.fileDigest(source) == overlaySHA256 else {
      throw NativeLaunchError.titleRecipeUnavailable
    }
    return try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 1, "blocked": [],
        "engines": [
          [
            "name": engineName, "kind": "free", "renderer": engine.pin.renderer,
            "install_path": engine.root.path, "wine": engine.wine.path,
            "wineserver": engine.wineserver.path,
            "sha256": engine.pin.wineSha256, "wineserver_sha256": engine.pin.wineserverSha256,
            "provider": ["id": "calimocho", "contract_version": 1],
            "environment": environment(root: engine.root),
            "prefix_overlays": [
              ["source": source.path, "destination": overlayDestination, "sha256": overlaySHA256]
            ],
          ]
        ],
      ], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
  }

  static func renderRegistry(
    _ engine: VerifiedCalimochoEngine,
    registries: URL
  ) throws -> (url: URL, digest: String) {
    let bytes = try registryData(engine)
    let url = registries.appendingPathComponent(engineName + ".json")
    try GameScriptFiles.writePrivate(bytes, to: url)
    return (url, CalimochoReleaseEngines.digest(bytes))
  }
}

struct NativeTitleRecipeInspection: Decodable, Equatable {
  let schemaVersion: Int
  let capability: String
  let recipeID: String
  let productID: String
  let packageIdentity: String
  let engineName: String
  let registrySha256: String
  let wineSha256: String
  let wineserverSha256: String
  let overlaySha256: String
  let postWinebootPreparation: Bool
  let ready: Bool
  let error: EngineInspection.Failure?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, capability, recipeID, productID, packageIdentity, engineName
    case registrySha256, wineSha256, wineserverSha256, overlaySha256
    case postWinebootPreparation, ready, error
  }

}

struct NativeTitleRecipeReceipt: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let capability: String
  let recipeID: String
  let productID: String
  let packageIdentity: String
  let engineName: String
  let registrySha256: String
  let wineSha256: String
  let wineserverSha256: String
  let overlaySha256: String
  let sourcePath: String
  let destinationRelativePath: String
  let sourceSha256: String
  let destinationPath: String
  let destinationSha256Before: String?
  let destinationSha256AfterUpdate: String?
  let destinationSha256BeforeFinalCheck: String?
  let destinationSha256After: String
  let updateRan: Bool
  let preparationCompleted: Bool
  let status: String
  let attestation: String
  var receiptPath: String? = nil

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, capability, recipeID, productID, packageIdentity, engineName
    case registrySha256, wineSha256, wineserverSha256, overlaySha256, sourcePath
    case destinationRelativePath, sourceSha256, destinationPath, destinationSha256Before
    case destinationSha256AfterUpdate, destinationSha256BeforeFinalCheck, destinationSha256After
    case updateRan, preparationCompleted, status, attestation, receiptPath
  }

  func validate(logDirectory: String) throws {
    guard schemaVersion == 1, capability == "titleRecipeV1",
      recipeID == NativeFH6Recipe.id, productID == NativeFH6Recipe.productID,
      packageIdentity == NativeFH6Recipe.packageIdentity, engineName == NativeFH6Recipe.engineName,
      EngineInspection.validDigest(registrySha256),
      wineSha256 == CalimochoReleasePin.release06.wineSha256,
      wineserverSha256 == CalimochoReleasePin.release06.wineserverSha256,
      overlaySha256 == NativeFH6Recipe.overlaySHA256, sourceSha256 == overlaySha256,
      destinationSha256After == overlaySha256,
      [destinationSha256Before, destinationSha256AfterUpdate, destinationSha256BeforeFinalCheck]
        .allSatisfy({ $0 == nil || EngineInspection.validDigest($0) }),
      sourcePath.hasSuffix("/" + NativeFH6Recipe.overlaySource),
      destinationPath.hasSuffix("/" + NativeFH6Recipe.overlayDestination),
      destinationRelativePath == NativeFH6Recipe.overlayDestination,
      updateRan, preparationCompleted, status == "pre_exec_verified",
      attestation == "staged bytes, not in-memory loaded modules",
      receiptPath
        == URL(fileURLWithPath: logDirectory).appendingPathComponent("title-recipe.json").path
    else {
      throw GameScriptError.invalidReceipt
    }
  }

  static func validateShape(_ value: JSONValue, includesPath: Bool) throws {
    guard case .object(let fields) = value,
      Set(fields.keys)
        == Set(CodingKeys.allCases.map(\.rawValue))
        .subtracting(includesPath ? [] : ["receiptPath"])
    else {
      throw GameScriptError.invalidReceipt
    }
  }
}

extension NativeTitleRecipeInspection {
  static func decode(_ bytes: Data, selection: AdmittedEngineSelection, exitCode: Int32) throws
    -> Self
  {
    let json = try JSONValue.decodeUnique(bytes, maximumBytes: 32_768)
    guard case .object(let fields) = json,
      Set(fields.keys) == Set(CodingKeys.allCases.map(\.rawValue))
    else {
      throw EngineInspectionError.invalidResponse
    }
    let value = try json.decode(Self.self)
    guard exitCode == 0, value.ready, value.error == nil,
      value.schemaVersion == 1, value.capability == "titleRecipeV1",
      value.recipeID == NativeFH6Recipe.id, value.productID == NativeFH6Recipe.productID,
      value.packageIdentity == NativeFH6Recipe.packageIdentity,
      value.engineName == NativeFH6Recipe.engineName,
      value.registrySha256 == selection.inspection.registrySha256,
      value.wineSha256 == CalimochoReleasePin.release06.wineSha256,
      value.wineserverSha256 == CalimochoReleasePin.release06.wineserverSha256,
      value.overlaySha256 == NativeFH6Recipe.overlaySHA256,
      value.postWinebootPreparation
    else {
      throw NativeLaunchError.titleRecipeUnavailable
    }
    try selection.validate(
      registryPath: selection.registryPath, engineName: value.engineName,
      registryDigest: value.registrySha256)
    try NativeFH6Recipe.requireEnabled(productID: value.productID)
    return value
  }
}
