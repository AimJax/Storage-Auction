-- StorageAuction — LEGACY TOOL, DO NOT RUN.
--
-- WHAT THIS WAS: a one-time map migration (Studio command bar, Edit mode)
-- that built Workspace.StorageAuctionMap from the ancient M1 one-unit
-- prototype layout.
--
-- WHY IT IS OBSOLETE: the current game has THREE auction units, three
-- auction areas, an ATM, warehouse district plots, and a warehouse template.
-- Regenerating from the old generator below would DESTROY all of that and
-- produce an incomplete single-unit map that fails validation. The old
-- generator body has therefore been REMOVED from this file (it lives on in
-- git history if anyone ever needs to read it).
--
-- If you run this file, it errors immediately on purpose. To recover or
-- re-seed the canonical map, restore `map/StorageAuctionMap` from version
-- control and sync it into Studio with Argon SERVER priority (never run
-- argon init, never merge backup-broken-2026-09-24 into main).
-- See AGENTS.md ("Sync workflow") for the exact steps.
--
-- SAFE: aborts without changing anything. This script is NOT part of Rojo
-- sync (tools/ is unmapped) and NEVER runs at game runtime.

error("[SA] LEGACY TOOL: tools/BuildMapOnce.luau builds only the ancient M1 one-unit prototype. " ..
	"Restore map/StorageAuctionMap from version control and sync with Argon SERVER priority instead. " ..
	"See AGENTS.md.", 0)
