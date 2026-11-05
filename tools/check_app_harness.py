#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Source wiring checks only; not authentication or native AX acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class AppHarnessSourceChecks(unittest.TestCase):
    def test_library_hero_scroll_observation_does_not_issue_scroll_commands(self):
        source = (ROOT / "Sources/XodusPreview/LiveLibraryView.swift").read_text()
        carousel = source.split("    private var heroCarousel:", 1)[1].split(
            "    private func hero(", 1)[0]
        self.assertNotIn(".scrollPosition(", carousel)
        self.assertIn("ScrollViewReader { pager in", carousel)
        self.assertIn("HeroPageSnap.pageIndex(", carousel)
        self.assertIn(".scrollTargetBehavior(HeroPageSnap())", carousel)
        observation = carousel.split("} action: { index in", 1)[1].split(
            ".scrollIndicators", 1)[0]
        self.assertIn("selection.heroID = heroGames[index].id", observation)
        self.assertNotIn("scrollTo", observation)
        self.assertEqual(carousel.count("pager.scrollTo("), 3)

    def test_current_service_configuration_is_not_a_historical_game_recipe_pin(self):
        source = (ROOT / "Sources/XodusPreview/LiveSession.swift").read_text()
        factories = source.split("    var nativeLifecycleConfiguration:", 1)[1].split(
            "    var canStartWelcomeSignIn:", 1)[0]
        self.assertNotIn("NativeLifecyclePins.cliSHA256", factories)
        self.assertEqual(factories.count("ShippingPairAdmission.connectedServiceConfiguration("), 2)
        self.assertIn("guard hasConfirmedSignIn, !connectionTransitioning, !signingOut", factories)
        self.assertIn("supports(.odeAccountRead)", factories)
        profile = (ROOT / "Sources/XodusPreview/NativeLaunchConfiguration.swift").read_text()
        self.assertIn("catalogue.cliSha256 == NativeLifecyclePins.cliSHA256", profile)

    def test_sandbox_uses_production_credential_adapter(self):
        source = (ROOT / "Sources/XodusPreview/AuthenticatedScenarioChecks.swift").read_text()
        self.assertIn("PCGamesCredentialStore(sandboxBroker:", source)
        adapter = (ROOT / "Sources/XodusPreview/PCGamesCredentialStore.swift").read_text()
        self.assertIn("#if !XODUS_SHIPPING\n    init(sandboxBroker:", adapter)
        self.assertIn("try await sandboxBroker(request)", adapter)
        self.assertIn("CredentialRequest(data: request.encoded())", source)
        self.assertIn("CredentialResponse(data: response.encoded(), request: request)", source)

    def test_fixture_runner_dispatches_before_app_state(self):
        source = (ROOT / "Sources/XodusPreview/XodusPreviewApp.swift").read_text()
        initializer = source.split("    init() {", 1)[1]
        self.assertLess(initializer.index("AuthenticatedScenarioChecks.launch()"),
                        initializer.index("AppState("))
        self.assertIn('"--authenticated-scenario-runner"', source)
        self.assertIn('"--real-account-scenario-runner"', source)
        self.assertLess(initializer.index("RealAccountScenarioChecks.launch()"),
                        initializer.index("AppState("))
        self.assertLess(initializer.index("RealAccountScenarioChecks.launch()"),
                        initializer.index("LiveSession("))
        self.assertNotIn("private var session = LiveSession()", source)

    def test_fixture_is_excluded_from_shipping(self):
        manifest = (ROOT / "Package.swift").read_text()
        self.assertIn('"AuthenticatedScenarioChecks.swift"', manifest.split("let shippingSettings")[0])
        self.assertIn('"RealAccountScenarioChecks.swift"', manifest.split("let shippingSettings")[0])
        self.assertIn("exclude: shipping ? previewOnly + scenarioOnly : []", manifest)
        self.assertIn('name: "XodusAppHarnessChecks"', manifest)

    def test_settings_identifiers_and_real_key_assertions(self):
        view = (ROOT / "Sources/XodusPreview/LiveAccountView.swift").read_text()
        for suffix in ("tab.general", "tab.engines", "tab.account", "tab.advanced",
                       "engine.picker", "engine.refresh", "catalog.market", "catalog.language"):
            self.assertIn(f'.accessibilityIdentifier("xodus.settings.{suffix}")', view)
        runner = (ROOT / "tools/test_settings_accessibility.swift").read_text()
        for key in ("kVK_ANSI_Comma", "kVK_Tab", "kVK_Escape", "kAXFocusedUIElementAttribute"):
            self.assertIn(key, runner)
        self.assertIn("postToPid(process.processIdentifier)", runner)

    def test_engines_has_only_canonical_tabbed_settings_route(self):
        source = ROOT / "Sources/XodusPreview"
        settings = (source / "LiveAccountView.swift").read_text()
        self.assertIn("TabView(selection: $state.settingsTab)", settings)
        self.assertIn("state.openEngineSettings(open: openSettings.callAsFunction)", settings)
        self.assertIn('DisclosureGroup("Advanced registry and game runtime")', settings)
        self.assertIn("NativeEngineSettings(", settings)
        app = (source / "XodusPreviewApp.swift").read_text()
        self.assertEqual(app.count("EngineSettingsButton(state: state)"), 2)
        self.assertIn("LiveSettingsView()", app.split("        Settings {", 1)[1])
        self.assertIn("state.openEngineSettings(open: openSettings.callAsFunction)",
                      (source / "XboxCompanionViews.swift").read_text())
        setup = (source / "OdeReadinessSetupView.swift").read_text()
        self.assertIn("EngineSettingsButton(state: state)", setup)
        self.assertIn("calimocho.isVerified", setup)
        self.assertNotIn("gptk.isInstalled", setup)
        for path in source.glob("*.swift"):
            text = path.read_text()
            self.assertNotIn("struct EnginesView:", text, path.name)
            self.assertNotIn("struct RuntimeInstallationPicker:", text, path.name)
            self.assertNotIn("struct EngineProviderOverview:", text, path.name)
            self.assertNotIn("openAccount(.engines)", text, path.name)
        self.assertFalse((source / "RuntimeInstallationPicker.swift").exists())

    def test_release_hold_and_local_only_packager(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("tags: ['v*']", workflow)
        self.assertIn("tools/release_workflow.py qualified-app", workflow)
        self.assertIn("sh tools/package_release.sh", workflow)
        self.assertIn("gh release upload", workflow)
        source = (ROOT / "tools/package_release.sh").read_text()
        self.assertIn("verify_release_admission", source)
        self.assertIn("run_hdiutil verify", source)
        self.assertIn("ditto -x -k", source)
        self.assertNotIn("notarytool", source)
        self.assertNotIn("codesign --force", source)
        self.assertNotIn("gh release", source)

    def test_operator_prompt_precedes_unified_auth_construction(self):
        source = (ROOT / "Sources/XodusPreview/RealAccountScenarioChecks.swift").read_text()
        self.assertLess(source.index("OperatorAvailabilityGate.confirm("),
                        source.index("let session = LiveSession()"))
        self.assertIn("session.canStartWelcomeSignIn", source)
        self.assertIn("await session.beginSignIn()", source)
        self.assertNotIn("PCGamesController(", source)
        self.assertNotIn("NSWorkspace", source)

    def test_synthetic_unified_library_uses_existing_consumer(self):
        source = (ROOT / "Sources/XodusPreview/AuthenticatedScenarioChecks.swift").read_text()
        self.assertIn("unifiedLibrary.useUnifiedAccount(session)", source)
        self.assertIn("await unifiedLibrary.refreshInBackground()", source)
        self.assertIn("unifiedLibrary.accessIsCurrent(for: productID)", source)
        self.assertIn('trace.contains("library:US")', source)


if __name__ == "__main__":
    unittest.main()
