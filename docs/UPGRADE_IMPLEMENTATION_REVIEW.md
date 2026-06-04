# Upgrade Implementation Review

Date: 2026-06-04

## Plan Comparison

### Release System With Rollback

Implemented:

- `scripts/release_manager.py` creates immutable releases with server files,
  client package manifest, ZIP/MRPack/DMG artifacts when available, DB snapshot,
  checksums, metadata, changelog, tested status, activation state, and public
  release manifest.
- Clients resolve `/downloads/current-release.json` and sync from a release-id
  manifest instead of the moving legacy manifest.
- `rollback` restores server mods/datapacks, client package artifacts, and can
  restore the DB snapshot with `--restore-db`.
- `scripts/daily_update.py` creates and activates a release only after
  successful applied updates.
- `systemd/pummelchen-minecraft.service` makes the game server an explicit
  managed service instead of an ad hoc shell process.

Checks:

- `scripts/validate_project.sh` creates two fixture releases, validates them,
  activates them, rolls back, and confirms newer files are removed.
- The fixture includes a fake upload token and asserts it is not exposed in the
  public release tree.

### Real Server Observability

Implemented:

- `scripts/minecraft_metrics_exporter.py` exposes Minecraft-specific Prometheus
  metrics on localhost port `7792`.
- Prometheus now scrapes `pummelchen_minecraft`.
- Grafana datasource/dashboard provisioning is stored under
  `monitoring/grafana/`.
- `scripts/live_stats_feed.py` and the generated status page include active
  release, player count, and Minecraft RSS alongside existing live VPS graphs.

Known limitation:

- TPS/MSPT are best-effort log parses unless a profiler/mod writes those values
  to logs or a later RCON/spark integration is added.

### CI/CD And Git

Implemented:

- `.github/workflows/ci.yml` runs the project quality gate.
- `scripts/validate_project.sh` automates compile, shell syntax, migrations,
  release/rollback fixture, manifest checks, website generation, live stats,
  exporter, load-lab dry run, monitoring JSON, and optional Nginx syntax.
- `scripts/deploy_project.sh` validates, syncs project-owned files, installs
  systemd/Nginx/Prometheus/Grafana config, regenerates the site, smoke-tests,
  and optionally creates a deploy release.

Known limitation:

- The deploy script intentionally does not install third-party apt packages.
  Prometheus, node exporter, blackbox exporter, Grafana, Nginx, and SQLite are
  configured/reloaded when present. Package bootstrap can be added as a separate
  explicit provisioning step.

### Gameplay Load Lab

Implemented:

- `scripts/gameplay_load_lab.py` supports schema init, scenario listing, dry
  runs, and real scenarios against a temporary world.
- Scenario samples are written to `load_lab_runs` and `load_lab_samples`.
- Supported scenarios are `fresh_world_idle`, `chunk_spiral`, and
  `manual_join_window`.

Known limitation:

- Fully automated 100-client synthetic joins are not implemented. The current
  lab covers server boot, temporary fresh worlds, chunk-generation proxy load,
  and measured manual join windows. Real bot-client load should be added only
  after selecting a protocol-compatible bot framework for Minecraft 26.1.2.

## Bug Check Notes

- Fixed load-lab dry-run so it no longer writes to `/var/minecraft_mods` during
  local/CI validation.
- Fixed load-lab CPU sampling to carry previous process state between samples.
- Included release metadata JSON in artifact validation.
- Changed DMG and generated command installer to resolve the active release
  pointer and verify the selected ZIP checksum.
- Kept public release publishing scoped to client mods/resourcepacks/shaderpacks
  and package artifacts; private tools such as upload tokens are not published.

## Remaining Production Hardening

- Add RCON or spark command integration for authoritative TPS/MSPT.
- Add explicit apt bootstrap for fresh VPS builds if the server ever needs
  full reprovisioning from zero.
- Add a protocol-compatible bot load framework before claiming automated
  100-client gameplay simulation.
- Add alert rules after baseline Prometheus data exists for a few normal play
  sessions.
