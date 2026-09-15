# Minecraft

<!-- agent-harnesses:begin -->
> **One instruction file.** This is it. Codex, DeepSeek Harness, OpenCode,
> Qwen Code, Qoder and Zed read `AGENTS.md` directly, and Claude Code reads it
> through the committed `CLAUDE.md`, which contains nothing but `@AGENTS.md`.
> **Edit only this file** — do not add a second set of instructions anywhere.
>
> Do **not** add `.rules`, `.cursorrules`, `.windsurfrules`, `.clinerules`,
> `.github/copilot-instructions.md` or `AGENT.md`. Zed takes the *first match*
> from that list, **ahead of `AGENTS.md`**, so any one of them silently
> replaces this file for every Zed user.
<!-- agent-harnesses:end -->

A mod release and conflict-validation system for three NeoForge servers, **of which
only the Caddy edge is built**. Design complete, implementation not started:
`README.md` says so outright and `PLAN.md` fixes "Phase 0 is live. Phases 1–8 are
not started." What exists is the host-wide Caddy edge (`caddy/`, live on the VPS)
and Minecraft's own inner web server plus a placeholder page (`site/`). The Swift
engine that resolves mods, hashes modsets, bisects conflicts and deploys is planned
phase by phase. It is for the operator of those three roughly-300-mod servers, and
everything beyond the edge is a design decision rather than shipped behaviour.

## Layout

- `caddy/` — `Caddyfile` (the master edge, one `import projects/*.caddy`),
  `projects/minecraft.caddy`, `projects/xaios.caddy`,
  `projects/EXAMPLE.caddy.template`, `scripts/{validate,test-edge,install}.sh`,
  `systemd/caddy.service.d/override.conf`, `MIGRATION.md`, `README.md`.
- `site/` — Minecraft's own `Caddyfile` (inner server on `:8801`, `bind 127.0.0.1`,
  serving `/var/minecraft/web` and proxying `/api/*` to `127.0.0.1:8787`),
  `systemd/minecraft-caddy.service`, `web/index.html` (a placeholder).
- `PLAN.md` — the canonical phase list. `.github/traffic.json` — badge data only.
- **`engine/` does not exist.** It is specified in `PLAN.md` as a Swift package
  (`pummelchen-engine`, built `--static-swift-stdlib`) across phases 1–8.
- Deployed topology: one master Caddy on `:80`/`:443` (TLS, HTTP/3, admin socket
  `unix//var/caddy/admin.sock`) routing `minecraft.*` → `127.0.0.1:8801`,
  `roomcad.*` → `127.0.0.1:8443` (https), `xaios.*` → `127.0.0.1:8090`. The three
  Minecraft servers run on 25565–25567; conflict tests use short-lived scratch ports.

## Build, test, run

No build step for anything committed. `caddy/scripts/install.sh` installs the
configs and is **root-only**.

```bash
caddy/scripts/validate.sh     # ok: Caddyfile and 2 project fragment(s) are valid
caddy/scripts/test-edge.sh    # routing, Host preservation, isolation, deep paths
caddy/scripts/install.sh      # sudo; stages + validates, does NOT start Caddy
```

`test-edge.sh` needs the `caddy` binary (or `CADDY_BIN`), `python3` and `curl`,
binds real ports (`EDGE_PORT` 8899, `STUB_BASE` 8901), and relies on
`trap cleanup EXIT` to kill its Caddy, its two python3 stub upstreams and its
scratch dir.

**The real cutover is manual and is the documented outage risk:**
`sudo systemctl stop <incumbent> && sudo systemctl start caddy`, after
`sudo ss -tlnp '( sport = :80 or sport = :443 )'`, the UDP 443 check, and recording
every incumbent hostname (`MIGRATION.md`). Rollback:
`sudo systemctl stop caddy && sudo systemctl start <incumbent>`.

## Identity

No version constant, and that is **enforced by rule**: no Minecraft version may
appear in source, config, units, routes or the site — versions are rows in a table
(`PLAN.md`). `PLAN.md` fixes "Swift 6.3.3, strict concurrency" and GRDB/SQLite in WAL
mode, but nothing in the repository implements or checks it yet. No releases; the tag
`v1-retired` and the branch `archive/v1` both point at commit `47458eb` and hold the
retired v1 system.

## Gates

**None automatic.** No CI workflow is tracked; only GitHub's dynamic CodeQL default
setup is active. `caddy/scripts/validate.sh` and `test-edge.sh` are the whole test
surface, and **nothing runs them on push**.

## Traps

- `caddy/scripts/install.sh` refuses to run unless `id -u` is 0, and writes into
  `/var/caddy`, `/var/log/caddy` and `/etc/systemd/system/caddy.service.d`. It
  installs only this repository's fragments and never removes others', so one
  project's deploy cannot clobber another's.
- **Only the master does TLS.** `site/Caddyfile` sets `auto_https off`; a project
  Caddy without it will attempt ACME, fail to bind 80/443, and retry forever.
- **Two mistakes `test-edge.sh` exists to catch, both real and both in
  `site/Caddyfile`:** `bind 127.0.0.1` is required, because writing the site address
  as `127.0.0.1:8801` makes Caddy treat the host as a Host *matcher* and still bind
  all interfaces; and the sensitive-path `respond` must stay inside `route {…}`,
  because Caddy orders directives by its own standard order and would otherwise run
  `file_server` first and serve the `.db`, `.env` and backup files the matcher exists
  to block — silently, with a 200.
- **Every routing entry must set `header_up Host {host}`.** Without it Caddy sends
  the dial address upstream, and a project whose own config matches a specific
  hostname matches nothing and returns a bare empty 200 — success status, no body,
  nothing logged as an error. RoomCAD hit exactly this;
  `caddy/projects/minecraft.caddy` is what makes the router correct for all of them.
- **Production identifiers are the committed defaults:** the VPS IP literal
  `91.99.176.243` and the `*.91.99.176.243.nip.io` hostnames appear throughout
  `caddy/` and `README.md` as `{$VAR:default}` values, so validation and tests
  exercise production values unless overridden.
- Outage-class operations: taking 80/443 is a total outage per `MIGRATION.md`.
  `xaios.caddy` deliberately serves that hostname over plain HTTP with no redirect —
  the XAIOS devices have no real-time clock and cannot complete a TLS handshake — and
  disables the ACME HTTP challenge so issuance cannot silently fall back to HTTP-01.
- **`caddy/projects/` here is an assembly point, not the deployed state.** RoomCAD's
  entry is deliberately *absent* because a copy here drifted within a day, and
  `xaios.caddy` is here only because that project has no repository yet.
- `trusted_proxies` is deliberately **absent** from the master `caddy/Caddyfile` (it
  is the outermost hop, so the client address Caddy sees is the truth, and trusting a
  forwarded header there would let a client claim any address) and present in
  `site/Caddyfile` as `trusted_proxies static private_ranges`. The master states
  `protocols h1 h2 h3` explicitly — **HTTP/3 is QUIC on UDP, so opening TCP 443 does
  not open it.**
- Certificate rate limits are the unresolved scaling risk: Let's Encrypt allows 50
  certificates per registered domain per week, comfortable only if `nip.io` is on the
  Public Suffix List (`MIGRATION.md` says to verify that before a dozen projects
  depend on it). It also warns against `on_demand_tls` without an `ask` endpoint.
- `git checkout v1-retired` needs a **full** clone — `git tag -l` is empty in a
  `--depth 1` clone while `git ls-remote --tags` shows the tag.
- `site/web/index.html` is a placeholder, `/api/*` proxies to `127.0.0.1:8787` where
  no engine runs yet, and `site/Caddyfile` carries a TODO to add a CSP when the real
  site replaces it.
- `PLAN.md` requires that the phase completing it updates it **in the same commit**,
  and adds two constraints the future engine must satisfy: no Minecraft version in
  source, config, units, routes or the site (enforced by a test from Phase 1), and
  migrations run from scratch in the test suite on every run. **The planner must stay
  pure** — no network, no side effects, no clock reads.

<!-- release-rules:begin -->
## Releasing

**Read [`RELEASE.md`](RELEASE.md) before cutting a release.** It carries the
generic rules every Pummelchen repository follows, plus this repository's own
section. Do not improvise a release.

The non-negotiables:

- **Apple Silicon only** — build native `arm64` (M1–M6). Never `--arch x86_64`,
  never `ARCHS=arm64 x86_64`, and never `lipo -create`, which is how a universal
  binary gets made.
- **Assert it** — `lipo -archs <binary>` must report exactly `arm64`. A build that
  silently produced a fat binary is a release defect, not a build option.
- **Every release carries the artifacts.** A tag alone is not a release.
- **Identity is single-sourced and enforced** — never bump one declaration of the
  version or build number on its own; the build or CI must fail on a mismatch.
- **Dry run first**; publish only on an explicit flag.
- **Never fetch a model, dataset or dependency to make a gate pass.** A check that
  cannot run is reported *not checked*, and the release notes must name it.
<!-- release-rules:end -->
