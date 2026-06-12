# SQLite to DuckDB Parity Audit

Audit date: 2026-06-13

Source SQLite: `/var/minecraft_mods/data/minecraft_mods.sqlite`

Target DuckDB: `/var/minecraft_mods/data/pummelchen.duckdb`

Git commit audited: `c755097`

## Result

The live DuckDB file was rebuilt from the live SQLite database with:

```bash
swift run --package-path swift/PummelchenSwift pummelchen-duckdb phase1-build \
  --duckdb /var/minecraft_mods/data/pummelchen.duckdb \
  --sqlite /var/minecraft_mods/data/minecraft_mods.sqlite \
  --project-root /var/minecraft_mods
```

DuckDB imported all 38 SQLite tables into `raw.*`. A bidirectional `EXCEPT` audit found zero row differences for every raw table.

The normalized `core.*` layer is intentionally narrower than SQLite. It currently promotes the release, mod, test, acceptance, headless-client, client-status, and world-reset surfaces needed by the Swift migration phases. Other SQLite tables are preserved exactly in `raw.*` and should be promoted later only when Swift services start owning those workflows.

## Built-In Phase Check

`pummelchen-duckdb phase1-check` passed:

- `pack_releases`: 28 rows
- `release_artifacts`: 280 rows
- `release_events`: 190 rows
- `mods`: 518 rows
- `mod_files`: 362 rows
- `mod_server_files`: 995 rows
- `test_runs`: 680 rows
- `mod_acceptance_blocks`: 123 rows
- `mod_acceptance_releases`: 3 rows
- `headless_client_runs`: 0 rows
- `client_update_status`: 8 rows
- reporting fields: OK
- current release parity: `release_20260612_V17_bsl-shader-config`
- tested updates parity: 733 rows

## Raw SQLite Parity

Every SQLite table exists in DuckDB `raw.*` with matching row counts and zero bidirectional row differences.

| Table | SQLite Rows | DuckDB Raw Rows | SQLite Minus Raw | Raw Minus SQLite |
|---|---:|---:|---:|---:|
| backup_snapshots | 33 | 33 | 0 | 0 |
| client_installer_events | 0 | 0 | 0 | 0 |
| client_installer_sessions | 0 | 0 | 0 | 0 |
| client_log_uploads | 0 | 0 | 0 | 0 |
| client_update_status | 8 | 8 | 0 | 0 |
| client_update_status_events | 321 | 321 | 0 | 0 |
| codex_fixed_mods | 0 | 0 | 0 | 0 |
| headless_client_runs | 0 | 0 | 0 | 0 |
| imports | 40 | 40 | 0 | 0 |
| load_lab_runs | 0 | 0 | 0 | 0 |
| load_lab_samples | 0 | 0 | 0 | 0 |
| mod_acceptance_block_client_runs | 0 | 0 | 0 | 0 |
| mod_acceptance_blocks | 123 | 123 | 0 | 0 |
| mod_acceptance_items | 97 | 97 | 0 | 0 |
| mod_acceptance_releases | 3 | 3 | 0 | 0 |
| mod_acceptance_runs | 99 | 99 | 0 | 0 |
| mod_files | 362 | 362 | 0 | 0 |
| mod_metadata | 502 | 502 | 0 | 0 |
| mod_notes | 517 | 517 | 0 | 0 |
| mod_performance_profiles | 1 | 1 | 0 | 0 |
| mod_risk_scores | 977 | 977 | 0 | 0 |
| mod_server_files | 995 | 995 | 0 | 0 |
| mods | 518 | 518 | 0 | 0 |
| pack_releases | 28 | 28 | 0 | 0 |
| performance_runs | 2 | 2 | 0 | 0 |
| profiling_queue | 529 | 529 | 0 | 0 |
| release_artifacts | 280 | 280 | 0 | 0 |
| release_events | 190 | 190 | 0 | 0 |
| schema_info | 2 | 2 | 0 | 0 |
| schema_migrations | 7 | 7 | 0 | 0 |
| server_instances | 2 | 2 | 0 | 0 |
| sheet_rows | 320 | 320 | 0 | 0 |
| source_urls | 564 | 564 | 0 | 0 |
| test_runs | 680 | 680 | 0 | 0 |
| update_events | 190 | 190 | 0 | 0 |
| update_runs | 34 | 34 | 0 | 0 |
| url_batch_items | 226 | 226 | 0 | 0 |
| url_batches | 15 | 15 | 0 | 0 |

## Normalized Core Layer

| Core Table | Rows | Status |
|---|---:|---|
| core.client_update_status | 8 | Promoted |
| core.headless_client_runs | 0 | Promoted |
| core.mod_acceptance_blocks | 123 | Promoted |
| core.mod_acceptance_releases | 3 | Promoted |
| core.mod_files | 362 | Promoted |
| core.mod_server_files | 995 | Promoted |
| core.mods | 518 | Promoted |
| core.pack_releases | 28 | Promoted |
| core.release_artifacts | 280 | Promoted |
| core.release_events | 190 | Promoted |
| core.schema_migrations | 1 | DuckDB migration ledger |
| core.test_runs | 680 | Promoted |
| core.update_events | 190 | Promoted |
| core.world_reset_history | 0 | New Swift-owned table |

## Reporting Views

| View | Rows |
|---|---:|
| reporting.v_client_sync_status | 8 |
| reporting.v_custom_datapack_status | 0 |
| reporting.v_failed_mods_table | 78 |
| reporting.v_release_health_latest | 1 |
| reporting.v_tested_updates_table | 733 |
| reporting.v_world_reset_history | 0 |

## Gaps To Track

- DuckDB did not exist on the VPS before this audit. It now exists at `/var/minecraft_mods/data/pummelchen.duckdb`.
- `raw.*` has complete SQLite parity, but several operational SQLite tables are not yet normalized into `core.*`, including installer events, client log uploads, mod metadata/notes/risk scores, profiling, load lab, import batches, and backup snapshots.
- That raw-only state is acceptable for the current Swift phases because the active Swift server/client code reads the normalized release/mod/test/client-status surfaces and reporting views. Before retiring Python/SQLite, each raw-only workflow needs either a `core.*` promotion or an explicit decision that the data remains archive-only.
- DuckDB lock behavior was observed during parallel audit reads. Production jobs should keep the planned single-writer/service-owner pattern and avoid multiple DuckDB CLI processes against the same file at the same time.

## Sign-Off

SQLite content is fully present in DuckDB `raw.*`.

The normalized DuckDB layer is complete for the current Swift migration phases, but not yet complete enough to decommission SQLite/Python for every legacy operational workflow.
