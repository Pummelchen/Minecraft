# Minecraft Automatic Server/Client Mod Updater

Swift/DuckDB rewrite of the Pummelchen Minecraft server and macOS client updater.

## Repository Layout

```text
Client App
Server App
Live Backup
```

- `Client App`: macOS Swift client app and sync helper.
- `Server App`: Debian Swift server app, shared Swift package, DuckDB schemas, and project docs.
- `Live Backup`: current live DuckDB backup copied from the VPS.
