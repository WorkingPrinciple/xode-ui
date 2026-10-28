# SPDX-License-Identifier: GPL-3.0-only
"""The only Python home for pre-Ode names in this repository (REQ-150, COR-308).

Two kinds of name live here and nowhere else in tools/:

* Inherited upstream identities the backend keeps (xodus-gaming/xodus crates and the
  binary they build). These stay until the backend contract says otherwise.
* Legacy names that an earlier installed build or the pinned producer still uses.
  These are marked REMOVE AFTER NEXT RELEASE.

Swift has its own single counterpart: Sources/OdeLegacyCompatibility/LegacyCompatibility.swift.
"""

# Inherited upstream Cargo crates and the CLI binary they produce. Not renamed by REQ-146.
CRATE_CORE = "xodus"
CRATE_CLI = "xodus-cli"
CRATE_SERVICE = "xodus-service"
# Owned management crate, renamed in the pinned producer 285696f9 (REQ-161).
CRATE_MANAGEMENT = "ode-management"
WORKSPACE_CRATES = frozenset({"msixvc", "msixvc-common", CRATE_CORE, CRATE_CLI, CRATE_MANAGEMENT, CRATE_SERVICE})

# File names in the pinned producer's output directory. The app bundle renames them on copy
# (Contents/Resources/OdeEngine/ode-cli and ode-window-monitor.exe). REMOVE AFTER NEXT RELEASE.
PRODUCER_CLI = CRATE_CLI
PRODUCER_WINDOW_HELPER = "xodus-window-monitor.exe"

# Where a build installed before the rename keeps its CLI. REMOVE AFTER NEXT RELEASE.
LEGACY_BUNDLED_CLI = "Contents/Resources/XodusEngine/xodus-cli"
LEGACY_BUNDLED_WINDOW_HELPER = "Contents/Resources/XodusEngine/xodus-window-monitor.exe"

# Launcher scripts and the game library folder written by builds before the X Ode game root
# (tools/migrate_game_root.py). REMOVE AFTER NEXT RELEASE.
LEGACY_GAME_LIBRARY_FOLDER = "Xodus"
LEGACY_GAME_FOLDER_EXPORT = "export XODUS_GAME_FOLDER="

# Runtime outcome log prefix before the rename; host parsers accept it for one release (the runtime
# emits only "ode outcome:"). REMOVE AFTER NEXT RELEASE.
LEGACY_OUTCOME_PREFIX = "xodus outcome:"

# Schema ID prefix of producers built before the rename; the renamed app must not pair with them.
# REMOVE AFTER NEXT RELEASE.
LEGACY_SCHEMA_ID_PREFIX = "urn:xodus:"

# Signing identifiers of apps installed before the rename. Only the read-only check of the installed
# prior candidate accepts them; new signatures use the Ode identifiers. REMOVE AFTER NEXT RELEASE.
LEGACY_SIGNING_IDENTIFIERS = {"app": "io.github.dragoshont.xodus",
                              "cli": "io.github.dragoshont.xodus.cli",
                              "helper": "io.github.dragoshont.xodus.auth-host",
                              "broker": "io.github.dragoshont.xodus.credential-broker"}
