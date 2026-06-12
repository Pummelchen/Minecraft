# Pummelchen Swift and DuckDB Migration Plan

Status: implementation planning document
Audience: AI coding agents and human maintainers
Target platforms: Debian 13 VPS server, macOS Apple Silicon clients
Current production system: Python, Bash, nginx, systemd, LaunchAgent, generated static website, DuckDB/SQLite-style project state
Target system: nginx edge, Swift server daemon with embedded DuckDB, Swift macOS client app/helper with embedded DuckDB
Last revised: 2026-06-12 after release/client/webpage hardening work

## 1. Executive Summary

The project should migrate toward two compiled Swift applications:

- `PummelchenServer`: a Debian 13 Swift service running behind nginx, owning the authoritative project DuckDB.
- `PummelchenClient`: a macOS Swift app plus background helper, owning a local client DuckDB inventory/cache.

nginx remains the public edge for the website, large downloads, HTTPS, static release files, and reverse proxying API/WebSocket traffic to the Swift server app.

DuckDB must be embedded locally on each side. Do not attempt to expose DuckDB directly over TCP or share one database file across clients. Server and client apps communicate through versioned HTTPS APIs and, later, WebSocket events.

The migration should be staged. The current scripts are production safety rails and must not be removed until the Swift implementation proves equivalent through repeated live releases.

Recent production work changed the migration target. The Swift system must now preserve the full release updater experience, not merely replace the old script set. The current baseline includes immutable release folders, DMG generation, a manual website repair command, client defaults enforcement, BSL shader defaults, ModernArch resource-pack ordering, release health monitoring, a safe world reset workflow with 1000-block radius pregeneration, and a compact sortable Tested Updates table on the website.

Current scale snapshot from the generated status page:

```text
283 server-side active mods
29 client-side extras
312 client install entries
29 failed/inactive mods
```

## 2. Goals

1. Replace scattered Bash/Python operational logic with maintainable Swift apps.
2. Give macOS players a simple GUI for sync status, manual sync, repair, and history.
3. Keep client state portable through a local DuckDB file.
4. Keep server release/mod/client state authoritative in a server-side DuckDB file.
5. Support near-realtime client notices through WebSocket after the basic HTTPS sync protocol is stable.
6. Preserve current production capabilities:
   - mod manifest generation
   - release activation
   - client package downloads
   - checksum validation
   - stale/unmanaged mod quarantine
   - client update reporting
   - terminal manual updater with clear progress and no-download summary
   - DMG installer generation and publication
   - client default config enforcement
   - shader/resource-pack default activation
   - server health checks
   - release health monitoring
   - world reset safety workflow
   - 1000-block radius spawn pregeneration after safe reset
   - status website
   - tested updates feed and sortable/filterable web table
7. Keep nginx for public traffic, static downloads, caching, logs, TLS, and reverse proxying.

## 3. Non-Goals

1. Do not rewrite everything in one step.
2. Do not make clients connect directly to DuckDB.
3. Do not expose the server app directly to the public internet.
4. Do not remove nginx.
5. Do not require an Apple Developer account for the first private-group version.
6. Do not embed the Swift compiler in the macOS client. The client is a compiled Swift app.
7. Do not block current production release operations while the Swift migration is in progress.

## 4. Target Architecture

```text
Internet
  |
  | HTTPS / WebSocket / static downloads
  v
nginx :80/:443
  |
  |-- /                         -> generated/static website
  |-- /downloads/...             -> static releases, DMG, client files
  |-- /downloads/client-files/... -> manual repair/helper downloads during migration
  |-- /api/v1/...                -> reverse proxy to PummelchenServer
  |-- /ws/v1                     -> reverse proxy to PummelchenServer WebSocket
  |-- /client-logs/...           -> compatibility route during migration
  |
  v
127.0.0.1:8787
PummelchenServer.service
  |
  |-- DuckDB authoritative project DB
  |-- release/mod/client state
  |-- Minecraft systemd control
  |-- safe world reset orchestration
  |-- release health monitor state
  |-- tested updates feed generation
  |-- manifest/report generation
  |-- client status receiver
```

```text
macOS player machine
  |
PummelchenClient.app
  |
  |-- SwiftUI/AppKit GUI
  |-- LaunchAgent background helper
  |-- local DuckDB inventory/cache
  |-- HTTPS manifest/status sync
  |-- static file downloads from nginx
  |-- built-in CLI repair/sync helper
  |-- optional WebSocket for near-realtime notices
  |
Minecraft folder
  |
  |-- mods/
  |-- resourcepacks/
  |-- shaderpacks/
  |-- .pummelchen/
```

## 5. Why Keep nginx

nginx remains a hard requirement because it is better than the Swift app at:

- serving large ZIP/JAR downloads efficiently
- serving static website assets
- TLS termination and future Let's Encrypt automation
- reverse proxying API/WebSocket traffic
- rate limiting and request size limits
- access logs
- cache headers
- keeping downloads/site available while the Swift app restarts

The Swift server should bind only to localhost.

Recommended binding:

```text
PummelchenServer listens on 127.0.0.1:8787
nginx proxies public /api/v1 and /ws/v1 to 127.0.0.1:8787
```

## 6. Technology Choices

### Server

- Language: Swift 6.3.2
- Platform: Debian 13
- Runtime: systemd service
- Database: DuckDB embedded file
- HTTP/WebSocket framework: prefer Vapor if dependencies are acceptable; otherwise use SwiftNIO directly.
- Static files: served by nginx, not by Swift.
- Process control: Swift executes narrowly scoped commands for `systemctl`, backup tools, and Minecraft RCON/query where required.

### Client

- Language: Swift 6.3.2 or current Xcode Swift equivalent on macOS development machine
- Platform: macOS Apple Silicon
- UI: SwiftUI with narrow AppKit interop where needed
- Database: DuckDB embedded file in `~/Library/Application Support/Pummelchen/client.duckdb`
- Background agent: LaunchAgent helper
- Distribution: unsigned or ad-hoc signed for private group initially
- Networking: URLSession for HTTPS, URLSessionWebSocketTask for WebSocket
- File sync: native Swift file operations, checksum validation, resumable downloads where practical
- CLI helper: same sync engine as GUI, with text progress suitable for Terminal support

### DuckDB

Use DuckDB as embedded state, not as a network database.

Server DB:

```text
/var/minecraft_mods/data/pummelchen.duckdb
```

Client DB:

```text
~/Library/Application Support/Pummelchen/client.duckdb
```

## 6.1 Current Production Contracts To Preserve

The Swift migration must treat the following behaviors as compatibility contracts.

### Release and Packaging

- Release directories remain immutable once activated.
- `current-release.json`, `client-sync-manifest.tsv`, client ZIP, MRPACK, DMG, and SHA256 sidecars remain published under `/downloads`.
- Client sync manifests keep section/name/size/sha256/url semantics so old Bash clients and new Swift clients can coexist.
- DMG builds include the current updater/helper, default config files, resource packs, shader packs, and launch defaults.
- NeoForge preflight remains part of release/DMG build gating. The system should report whether the configured NeoForge version is current before publishing.
- Release health checks must run after release activation and DMG publication.

### Client Defaults

The Swift client must apply the same defaults that the current Bash updater applies:

- 8 GB standard Minecraft memory allocation for clients.
- Pummelchen multiplayer server entry.
- BSL shader active by default when shader support is installed.
- Complementary Reimagined available as an alternate shader.
- ModernArch resource pack stack enabled in order:
  1. base mod resources
  2. `ModernArch v2.8.2 [26.1] [128x]`
  3. `ModernArch FA Extension v2.2`
  4. `ModernArch Denser Grass Addon`
- Known-compatible resource packs must not be left in the incompatible-resource-pack list after sync.
- NeoForge/Forge load warning popups and noisy client checks stay suppressed where current defaults suppress them.
- Untitled Duck server/client config defaults set:
  ```toml
  duck_tamed_no_follow = true
  goose_tamed_no_follow = true
  ```

### Manual Repair and Terminal UX

- The website keeps a one-line Terminal repair command.
- During migration, that command may download Bash or Swift helpers, but it must keep the same user promise: repair updater/helper files, make them executable, and run a forced sync.
- Manual forced sync must print a clear terminal status.
- If no downloads are required, it must still print a friendly summary with server release, client release, file count, verified count, and "all synced, no downloads required".
- If downloads are required, it must show deterministic progress suitable for non-technical macOS users.

### Server Defaults and World Reset

- Server config overrides are first-class release inputs, not ad-hoc files.
- Safe world reset must:
  - require dry-run support
  - backup before destructive changes
  - delete the old world only after backup succeeds
  - write the requested seed
  - reinstall datapacks and server config overrides
  - preserve bonus chest behavior
  - apply gamerules such as keep inventory and block-damage controls
  - detect spawn after first boot
  - pregenerate a 1000-block radius around spawn
  - record the operation and result

### Website

- The website remains a static nginx-served page during migration.
- Server/VPS stats and charts remain visible.
- Manual client update and safe reset sections remain documented.
- Tested Updates remains a compact table with:
  - first column `Updated At`
  - timestamp format `YYYY-MM-DD HH:MM:SS`
  - sortable headers
  - free-text filtering
  - hyperlink support for mod/update names
- Every script or command shown on the website keeps a copy-to-clipboard icon button.

### Watch Agents and Health

- Existing systemd timers/services remain active until Swift replacements prove equivalent.
- Release health must continue to report a single pass/fail/warn summary.
- Client log receiver/client status ingestion must remain backward compatible with installed clients.
- Failed mod tracking and Tested Updates generation remain part of the live site.

## 7. Protocol Design

Use HTTPS JSON first. Add WebSocket only after the sync path is stable.

### API Versioning

All routes must be versioned:

```text
/api/v1/...
/ws/v1
```

Every response should include:

```json
{
  "api_version": "v1",
  "server_time": "2026-06-12T00:00:00Z",
  "request_id": "uuid"
}
```

### Core HTTPS Endpoints

```text
GET  /api/v1/status
GET  /api/v1/releases/current
GET  /api/v1/releases/{release_id}
GET  /api/v1/releases/{release_id}/manifest
GET  /api/v1/releases/{release_id}/health
GET  /api/v1/tested-updates
GET  /api/v1/site/status
POST /api/v1/clients/register
POST /api/v1/clients/{client_id}/heartbeat
POST /api/v1/clients/{client_id}/sync-runs
POST /api/v1/clients/{client_id}/inventory
POST /api/v1/clients/{client_id}/diagnostics
POST /api/v1/clients/{client_id}/installer-events
GET  /api/v1/messages
```

Downloads stay on nginx:

```text
/downloads/releases/{release_id}/client-sync-manifest.tsv
/downloads/releases/{release_id}/minecraft_26.1.2_client_macos_apple_silicon.zip
/downloads/client-files/...
```

### WebSocket Events

Use WebSocket for small control/status events only, not for file downloads.

```text
/ws/v1
```

Event examples:

```json
{"type":"release.available","release_id":"release_20260612_V3_updater-summary"}
{"type":"message.server","severity":"info","title":"Restart in 10 minutes","body":"Please finish your current activity."}
{"type":"client.sync.request","reason":"critical_mod_update"}
{"type":"server.health","minecraft_up":true,"players_online":4}
{"type":"release.health","release_id":"release_20260612_V16_duck-goose-no-follow-defaults-v2","status":"healthy"}
```

## 8. Authentication and Security

Private group does not mean no security. Use simple, robust controls.

### Client Identity

Each client gets:

- `client_id`: random UUID
- `client_secret`: random 256-bit token

Store on macOS:

```text
~/Library/Application Support/Pummelchen/client-id
Keychain or local config for token
```

For first private release, a file token is acceptable if permissions are locked down. Prefer Keychain when the Swift app is mature.

### Request Authentication

Use HTTPS with bearer token:

```http
Authorization: Bearer <client_secret>
X-Pummelchen-Client-ID: <client_id>
```

### Manifest Integrity

Each release manifest must include:

- release id
- Minecraft version
- NeoForge version
- file list
- SHA256 per file
- total file count
- generation timestamp

Future improvement: sign manifest with an Ed25519 server key and verify in the client.

### File Safety

Client must:

- download to temporary path first
- verify SHA256 before install
- never partially overwrite a live mod file
- quarantine unmanaged files instead of deleting them
- avoid updating while Minecraft is running unless operation is safe

## 9. Data Model

### Server DuckDB Tables

Initial authoritative tables:

```sql
CREATE TABLE releases (
  release_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  activated_at TIMESTAMP,
  status VARCHAR NOT NULL,
  minecraft_version VARCHAR NOT NULL,
  neoforge_version VARCHAR NOT NULL,
  manifest_sha256 VARCHAR,
  client_zip_sha256 VARCHAR,
  notes VARCHAR
);

CREATE TABLE release_files (
  release_id VARCHAR NOT NULL,
  section VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  size_bytes BIGINT NOT NULL,
  sha256 VARCHAR NOT NULL,
  url_path VARCHAR NOT NULL,
  role VARCHAR,
  PRIMARY KEY (release_id, section, name)
);

CREATE TABLE mods (
  mod_id VARCHAR PRIMARY KEY,
  name VARCHAR NOT NULL,
  source_url VARCHAR,
  side VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  current_file VARCHAR,
  notes VARCHAR
);

CREATE TABLE clients (
  client_id VARCHAR PRIMARY KEY,
  registered_at TIMESTAMP NOT NULL,
  display_name VARCHAR,
  last_seen_at TIMESTAMP,
  current_release_id VARCHAR,
  os_version VARCHAR,
  app_version VARCHAR,
  status VARCHAR
);

CREATE TABLE client_sync_runs (
  run_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  started_at TIMESTAMP NOT NULL,
  finished_at TIMESTAMP,
  from_release_id VARCHAR,
  target_release_id VARCHAR,
  result VARCHAR NOT NULL,
  files_verified INTEGER,
  files_downloaded INTEGER,
  files_quarantined INTEGER,
  error_message VARCHAR
);

CREATE TABLE client_inventory_snapshots (
  snapshot_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  created_at TIMESTAMP NOT NULL,
  release_id VARCHAR,
  file_count INTEGER,
  payload_json VARCHAR NOT NULL
);

CREATE TABLE server_messages (
  message_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  severity VARCHAR NOT NULL,
  title VARCHAR NOT NULL,
  body VARCHAR NOT NULL,
  expires_at TIMESTAMP
);

CREATE TABLE release_health_runs (
  run_id VARCHAR PRIMARY KEY,
  release_id VARCHAR,
  created_at TIMESTAMP NOT NULL,
  status VARCHAR NOT NULL,
  ok_count INTEGER NOT NULL,
  warn_count INTEGER NOT NULL,
  error_count INTEGER NOT NULL,
  summary VARCHAR NOT NULL,
  payload_json VARCHAR NOT NULL
);

CREATE TABLE tested_updates (
  update_id VARCHAR PRIMARY KEY,
  tested_at TIMESTAMP NOT NULL,
  title VARCHAR NOT NULL,
  event_type VARCHAR NOT NULL,
  source VARCHAR NOT NULL,
  source_url VARCHAR,
  file_name VARCHAR,
  file_version VARCHAR,
  test_label VARCHAR,
  notes VARCHAR
);

CREATE TABLE client_installer_events (
  event_id VARCHAR PRIMARY KEY,
  client_id VARCHAR,
  created_at TIMESTAMP NOT NULL,
  session_id VARCHAR,
  phase VARCHAR,
  status VARCHAR NOT NULL,
  message VARCHAR,
  payload_json VARCHAR
);

CREATE TABLE server_config_overrides (
  override_id VARCHAR PRIMARY KEY,
  path VARCHAR NOT NULL,
  sha256 VARCHAR NOT NULL,
  applied_at TIMESTAMP,
  payload_text VARCHAR NOT NULL
);

CREATE TABLE world_reset_runs (
  run_id VARCHAR PRIMARY KEY,
  requested_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  status VARCHAR NOT NULL,
  seed VARCHAR NOT NULL,
  radius_blocks INTEGER NOT NULL,
  backup_path VARCHAR,
  spawn_x INTEGER,
  spawn_z INTEGER,
  chunks_requested INTEGER,
  chunks_completed INTEGER,
  error_message VARCHAR,
  payload_json VARCHAR
);
```

### Client DuckDB Tables

```sql
CREATE TABLE client_state (
  key VARCHAR PRIMARY KEY,
  value VARCHAR NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE TABLE installed_files (
  section VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  path VARCHAR NOT NULL,
  size_bytes BIGINT,
  sha256 VARCHAR,
  release_id VARCHAR,
  verified_at TIMESTAMP,
  status VARCHAR NOT NULL,
  PRIMARY KEY (section, name)
);

CREATE TABLE sync_runs (
  run_id VARCHAR PRIMARY KEY,
  started_at TIMESTAMP NOT NULL,
  finished_at TIMESTAMP,
  from_release_id VARCHAR,
  target_release_id VARCHAR,
  result VARCHAR NOT NULL,
  files_verified INTEGER,
  files_downloaded INTEGER,
  files_quarantined INTEGER,
  error_message VARCHAR
);

CREATE TABLE sync_events (
  event_id VARCHAR PRIMARY KEY,
  run_id VARCHAR NOT NULL,
  timestamp TIMESTAMP NOT NULL,
  level VARCHAR NOT NULL,
  message VARCHAR NOT NULL,
  file_name VARCHAR
);

CREATE TABLE release_history (
  release_id VARCHAR PRIMARY KEY,
  first_seen_at TIMESTAMP NOT NULL,
  installed_at TIMESTAMP,
  status VARCHAR NOT NULL,
  manifest_sha256 VARCHAR
);

CREATE TABLE settings (
  key VARCHAR PRIMARY KEY,
  value VARCHAR NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

CREATE TABLE client_defaults (
  key VARCHAR PRIMARY KEY,
  desired_value VARCHAR NOT NULL,
  applied_value VARCHAR,
  applied_at TIMESTAMP,
  status VARCHAR NOT NULL,
  source VARCHAR NOT NULL
);

CREATE TABLE installer_events (
  event_id VARCHAR PRIMARY KEY,
  timestamp TIMESTAMP NOT NULL,
  phase VARCHAR,
  status VARCHAR NOT NULL,
  message VARCHAR,
  payload_json VARCHAR
);
```

## 10. macOS Client GUI

The client should be a practical status and repair app.

### Navigation

Use a compact sidebar or segmented control:

```text
Status | Sync | History | Mods | Settings
```

### Status View

Primary question: can the player play safely?

Show:

- state badge: `Synced`, `Update Available`, `Syncing`, `Repair Needed`, `Server Offline`, `Minecraft Running`
- server release id
- client release id
- verified file count
- last check
- background helper state
- Minecraft folder path
- active shader
- active resource-pack stack
- client memory allocation
- default config health

Actions:

- Sync Now
- Repair Client
- Open Minecraft Folder
- Copy Diagnostics
- Reapply Client Defaults

Success copy:

```text
All synced. No downloads required.
Server release: release_...
Client release: release_...
271 files verified.
```

### Sync View

Live progress:

- current phase
- current file
- progress bar
- verified/downloaded/skipped/quarantined/failed counts
- event stream

### History View

Show local sync runs from DuckDB:

```text
Date        Result    Server Release        Files Changed    Duration
Today       OK        20260612_V3           0                14s
Yesterday   OK        20260612_V2           1                31s
Jun 11      Failed    20260611_V3           0                Network timeout
```

Click row for details:

- manifest URL
- before/after release
- downloaded files
- quarantined files
- error log
- checksum failures

### Mods View

Show installed mods and expected server manifest status.

Filters:

- All
- Server-required
- Client-only
- Outdated
- Problem

### Defaults View

Show enforced defaults and their current state:

```text
Memory: 8 GB
Shader: BSL_v10.1.3.zip active
Resource packs: ModernArch base, FA Extension, Denser Grass
Server entry: present
Duck/goose no-follow: true
Warnings suppressed: true
```

Each row should show:

- desired value
- detected value
- status: `OK`, `Needs Repair`, `Unknown`
- last applied timestamp

The `Reapply Client Defaults` action runs the same default writer used after sync.

### Settings View

Fields:

- Server URL
- Minecraft folder
- Auto-sync interval
- background sync enabled
- notifications enabled
- diagnostics level

Advanced actions:

- Reset Local Sync State
- Reinstall Current Release
- Quarantine Unmanaged Mods
- Reapply Client Defaults

## 11. Server App Responsibilities

`PummelchenServer` should eventually own:

1. API and WebSocket server.
2. Authoritative release state in DuckDB.
3. Current release pointer.
4. Client status ingestion.
5. Server-side mod metadata tracking.
6. Release creation orchestration.
7. Safe world reset workflow.
8. Minecraft service health and systemd control.
9. Status website data generation, or direct API data for a static/SSR page.
10. Compatibility endpoints while old clients still exist.
11. Release health monitoring and health history.
12. Tested Updates feed generation.
13. Server config override inventory and application.
14. DMG/client package publication metadata.
15. Website repair command payload/version management.

It should not:

- serve huge files itself unless nginx is unavailable
- expose DuckDB directly
- run as root unless unavoidable
- accept unauthenticated client write calls

## 12. Migration Phases

### Phase 0: Baseline and Contracts

No behavior replacement yet.

Tasks:

1. Freeze current behavior in documentation:
   - updater flows
   - manual repair one-liner
   - client no-download summary
   - DMG contents
   - client default config writer
   - release creation
   - manifest format
   - server health checks
   - release health checks
   - tested updates table/feed shape
   - world reset behavior
2. Define JSON API schemas.
3. Define DuckDB schemas and migrations.
4. Define client identity/token model.
5. Add conformance tests that compare Swift-produced manifests with current manifests.

Acceptance:

- No production behavior changed.
- API/schema docs exist.
- Current scripts still pass `scripts/validate_project.sh`.

### Phase 1: Swift Shared Core Library

Create shared Swift package:

```text
Packages/PummelchenCore
```

Responsibilities:

- release id parsing
- manifest model
- SHA256 hashing
- file inventory model
- DuckDB access wrapper
- JSON API models
- logging primitives
- filesystem safety helpers
- Minecraft options/config default writer
- resource-pack and shader option model
- timestamp formatting for website/API output

Acceptance:

- Unit tests pass on macOS and Debian.
- Can parse current `client-sync-manifest.tsv`.
- Can hash and verify current client files.
- Can apply client defaults into fixture Minecraft config folders without duplicate keys.
- Can render Tested Updates timestamps as `YYYY-MM-DD HH:MM:SS`.

### Phase 2: Server Read-Only API

Create `PummelchenServer` service with read-only endpoints:

- `/api/v1/status`
- `/api/v1/releases/current`
- `/api/v1/releases/{release_id}/manifest`

nginx proxies `/api/v1` to localhost.

Acceptance:

- API returns current release identical to static `current-release.json`.
- nginx proxy works.
- systemd service restarts cleanly.
- No write operations yet.

### Phase 3: Client GUI Read-Only Status

Create macOS app:

- status screen
- server URL setting
- local DuckDB initialization
- current release fetch
- local installed release read
- display synced/outdated/offline state
- display current default-config health

Acceptance:

- App runs unsigned/ad-hoc signed.
- Shows correct server release.
- Shows local release.
- Writes local status into DuckDB.
- Does not mutate Minecraft folder yet.
- Clearly reports whether shader/resource-pack/memory/server-entry defaults are OK.

### Phase 4: Swift Client Sync Engine

Implement native sync in macOS client:

- fetch manifest
- compare installed files
- download missing/changed files
- verify SHA256
- install atomically
- quarantine unmanaged files
- apply client defaults after sync
- update local DuckDB
- report sync run to server

Keep existing Bash updater available as fallback.

Acceptance:

- Swift sync produces same filesystem result as current Bash updater.
- Forced sync with no downloads shows "all synced".
- Failed checksum leaves original file untouched.
- Minecraft-running state is handled explicitly.
- Local DuckDB history is accurate.
- BSL shader, ModernArch stack, 8 GB memory, server entry, suppressed warnings, and duck/goose no-follow defaults are applied idempotently.
- Re-running sync does not duplicate config keys.

### Phase 5: Server Write APIs and Client Reports

Implement:

- client register
- heartbeat
- sync run report
- inventory upload
- diagnostics upload
- installer/defaults event upload

Acceptance:

- Server DuckDB shows client status.
- Status page can show aggregate client health.
- Bad tokens are rejected.
- Request payloads are size-limited.
- Server can distinguish `synced`, `needs defaults repair`, `failed checksum`, and `stale release`.

### Phase 6: Release Pipeline in Swift

Move release logic into `PummelchenServer` or a companion Swift CLI:

- build manifest
- validate dependencies
- create release directory
- activate current release
- build/publish client ZIP
- build/publish DMG metadata and checksums
- write/publish current release pointer
- publish manual repair/helper artifacts
- trigger service restart if required
- generate status page data
- generate tested updates feed
- run release health monitor

During transition, Swift should call existing scripts only through narrow wrappers. Remove wrappers only after equivalent Swift logic exists and tests pass.

Acceptance:

- Swift-created release matches current release format.
- Client can sync from Swift-created release.
- Rollback remains possible.
- DMG contains the correct helper/defaults files.
- Release health result is persisted and visible.
- Tested Updates website table data is generated from Swift-owned state or an equivalent compatibility feed.

### Phase 7: WebSocket Realtime Events

Add `/ws/v1`.

Events:

- release available
- server message
- server restart notice
- client sync requested
- health update

Acceptance:

- Client reconnects safely.
- Missed messages are fetched via HTTPS fallback.
- No downloads happen over WebSocket.

### Phase 8: Safe World Reset in Swift

Port safe reset workflow:

- backup world
- delete existing world after backup
- write seed
- ensure datapacks
- ensure server config overrides
- ensure gamerules
- start/restart server
- detect spawn
- pregenerate configured radius; current production default is 1000 blocks around spawn
- record operation in DuckDB

Acceptance:

- Dry-run mode matches current script plan.
- Backup is created before destructive changes.
- Gamerules/datapacks are verified after reset.
- Pregeneration completion is recorded.
- Existing world is gone after successful reset.
- New world uses the requested seed.

### Phase 9: Decommission Scripts

Remove or archive old scripts only after:

- two or more production releases were created by Swift path
- multiple clients synced through Swift client
- rollback tested
- safe world reset tested on staging
- status page and health monitoring still work

Keep emergency fallback scripts in `legacy/` until the new system has lived through several updates.

## 13. Testing Strategy

### Server Tests

- DuckDB migration tests
- API contract tests
- manifest generation comparison tests
- release activation dry-run tests
- release health monitor tests
- tested updates feed/table contract tests
- DMG publication metadata tests
- server config override application tests
- nginx proxy smoke tests
- systemd restart tests
- world reset dry-run tests
- world reset new-seed and old-world deletion tests
- pregeneration plan/result tests
- backup/rollback tests

### Client Tests

- local DB migration tests
- manifest parse tests
- hash verification tests
- no-download sync tests
- changed-file sync tests
- failed checksum tests
- interrupted download tests
- unmanaged mod quarantine tests
- Minecraft-running detection tests
- client defaults idempotency tests
- shader/resource-pack activation tests
- incompatible resource-pack cleanup tests
- manual repair CLI output tests
- no-download summary output tests
- GUI state tests

### End-to-End Tests

- server creates release
- client sees release
- client syncs
- client reports status
- server records inventory
- website shows client health
- website shows Tested Updates table with sortable/filterable data
- manual repair command still works
- rollback release
- client downgrades or holds based on policy

## 14. Deployment Strategy

### Server

Systemd unit:

```text
/etc/systemd/system/pummelchen-server.service
```

Binary:

```text
/opt/pummelchen/bin/PummelchenServer
```

DB:

```text
/var/minecraft_mods/data/pummelchen.duckdb
```

Config:

```text
/etc/pummelchen/server.toml
```

Logs:

```text
journalctl -u pummelchen-server.service
```

### Client

Install:

```text
/Applications/PummelchenClient.app
```

or private-group local install:

```text
~/Applications/PummelchenClient.app
```

Data:

```text
~/Library/Application Support/Pummelchen/
```

LaunchAgent:

```text
~/Library/LaunchAgents/com.pummelchen.client.helper.plist
```

## 15. Operational Safeguards

1. Never update mods while Minecraft is actively using files unless the update is known safe.
2. Never delete unmanaged files immediately; quarantine first.
3. Never activate release without manifest validation.
4. Never write partial downloads to final paths.
5. Never expose localhost server app port publicly.
6. Never accept unauthenticated client write requests.
7. Always keep one known-good release available for rollback.
8. Always include a manual repair path on the website.
9. Always maintain compatibility with the existing updater during migration.
10. Always apply client defaults idempotently; duplicate config keys are release blockers.
11. Always validate DMG contents before publishing.
12. Always run release health after release activation and package publication.
13. Always keep old Bash/Python repair path available until the Swift CLI has survived multiple real client repairs.

## 16. AI Coding Agent Instructions

When implementing this plan:

1. Read existing project behavior before replacing it.
2. Prefer narrow vertical slices over broad rewrites.
3. Preserve current release and updater compatibility.
4. Add tests for every behavior moved from scripts to Swift.
5. Do not remove existing scripts until the acceptance criteria for the replacement phase pass.
6. Keep nginx in front of the Swift server.
7. Keep DuckDB embedded locally; do not build network access to DuckDB itself.
8. Use explicit schema migrations.
9. Treat the macOS client as a user-facing app; every sync failure needs a clear UI state and a repair option.
10. Treat the server app as production infrastructure; every destructive operation needs dry-run, backup, and rollback.
11. Before replacing a script, write a fixture test that proves the Swift result matches the current script result.
12. Preserve the current website user contract: manual commands have copy buttons, Tested Updates is a table, and status/release information is visible without logging in.

## 17. Server Perspective Review

### Strengths

- The target architecture keeps nginx, which reduces risk for downloads, TLS, static content, and reverse proxying.
- The server owns the authoritative database and release state, which is correct.
- The staged migration avoids breaking existing update/release workflows.
- DuckDB is suitable for release metadata, client health, inventory snapshots, and audit logs.
- A Swift daemon can centralize current script logic and reduce operational drift.

### Risks

1. Swift on Linux has fewer operations libraries than Python. Some scripting tasks may take longer to port.
2. Running process-control actions from a server daemon can become unsafe if permissions are too broad.
3. Release creation and world reset workflows are destructive and need stronger transactional boundaries than ordinary API calls.
4. WebSocket should not become a second control plane that bypasses HTTPS validation.
5. DuckDB concurrency must be managed carefully. A single server process should own writes, and background jobs must serialize schema-changing operations.

### Required Server Revisions

1. Add explicit job queue semantics for long-running server work:
   - release creation
   - world reset
   - pregeneration
   - large validation runs
2. Server API should submit jobs and expose job status, not run destructive workflows directly inside request handlers.
3. Use least-privilege systemd configuration where possible.
4. Keep compatibility routes for old clients until all clients are migrated.
5. Add database backup before every schema migration and before release/world operations.

### Revised Server Plan Additions

Add tables:

```sql
CREATE TABLE jobs (
  job_id VARCHAR PRIMARY KEY,
  kind VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  created_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP,
  finished_at TIMESTAMP,
  requested_by VARCHAR,
  input_json VARCHAR NOT NULL,
  result_json VARCHAR,
  error_message VARCHAR
);

CREATE TABLE audit_log (
  event_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  actor VARCHAR NOT NULL,
  action VARCHAR NOT NULL,
  target VARCHAR,
  payload_json VARCHAR
);
```

Add endpoints:

```text
POST /api/v1/jobs
GET  /api/v1/jobs/{job_id}
GET  /api/v1/jobs
```

Long-running operations must run through this job system.

## 18. Client Perspective Review

### Strengths

- Native SwiftUI client is the right fit for private macOS players.
- Local DuckDB gives clear history and diagnostics.
- The proposed UI answers the player's main question quickly: "am I synced?"
- Keeping Bash updater fallback during migration reduces support risk.
- A LaunchAgent helper maps well to background sync.

### Risks

1. Unsigned/ad-hoc signed apps will still trigger macOS trust friction.
2. Clipboard, quarantine, file permissions, and background execution behavior vary across macOS versions.
3. If the app tries to do too much initially, it can become less reliable than the current simple updater.
4. Detecting whether Minecraft is running must be conservative.
5. A GUI-only updater is not enough; a command-line repair path is still needed for broken installs.

### Required Client Revisions

1. Keep a CLI-compatible helper inside the app bundle:
   ```text
   PummelchenClient.app/Contents/MacOS/pummelchen-client-cli
   ```
2. Website manual repair command should continue to exist and can later download the Swift helper/app instead of Bash scripts.
3. Add a clear "Copy Diagnostics" action from day one.
4. Add a first-run permission/trust page explaining private-group unsigned app behavior.
5. Treat Minecraft-running detection as a blocking warning unless user chooses a safe check-only action.

### Revised Client Plan Additions

Client app bundle should contain:

```text
PummelchenClient.app
  Contents/MacOS/PummelchenClient
  Contents/MacOS/PummelchenClientHelper
  Contents/MacOS/pummelchen-client-cli
  Contents/Resources/default-config.json
```

Minimum first useful version:

1. Status screen
2. Sync Now
3. History screen
4. Settings screen
5. Copy Diagnostics
6. CLI helper with:
   ```text
   pummelchen-client-cli status
   pummelchen-client-cli sync --force
   pummelchen-client-cli repair
   pummelchen-client-cli diagnostics
   ```

## 19. Final Revised Implementation Order

After server and client review, the recommended order is:

1. Define contracts: schemas, manifest model, API JSON, client identity.
2. Build `PummelchenCore` Swift package.
3. Build server read-only API behind nginx.
4. Build macOS read-only client GUI.
5. Build Swift config/defaults engine with fixture parity against the current updater.
6. Build client DuckDB history and inventory.
7. Build Swift CLI helper with `status`, `sync --force`, `repair`, and `diagnostics`, while keeping Bash fallback.
8. Build Swift client sync engine and wire it into both GUI and CLI.
9. Add client report APIs and server-side client dashboard data.
10. Add server job queue and audit log.
11. Port release health and Tested Updates feed generation.
12. Port release pipeline into Swift job system, including DMG metadata/publication.
13. Add WebSocket events.
14. Port safe world reset into Swift job system.
15. Decommission legacy scripts only after repeated live success.

## 20. Sign-Off Criteria

Do not declare the migration complete until:

- all clients can sync through the Swift client
- the server can create and activate releases through Swift
- nginx serves downloads and proxies APIs correctly
- current website/manual repair path still exists
- Tested Updates table remains sortable/filterable and timestamped
- DMG publication and manifest publication are verified
- client defaults are applied idempotently without duplicate config keys
- shader/resource-pack/memory defaults are visible in the client GUI
- safe world reset is implemented with dry-run and backup
- safe world reset deletes the old world, applies the requested seed, and pregenerates 1000 blocks around spawn
- DuckDB migrations are tested and backed up
- rollback from bad release is tested
- at least two production releases complete without using legacy scripts
- player-facing GUI clearly reports synced/update/error states
- server-side health monitoring reports clean after release activation
- the website manual repair command can recover at least one real macOS client using the Swift CLI/helper path
