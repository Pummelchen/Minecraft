# Minecraft Automatic Server/Client Mod Updater

This is an automatic Minecraft Server/Client Mod updater which uses OpenAI Codex as the AI interface to accept human instructions, for example: "Add mod Biomes O' Plenty".

What happens next is that the mod will be searched on the major websites, downloaded, and put into a validation test chain to ensure the new mod is compatible with the other 300+ mods. Once the tests pass, including headless MC client tests, the mod will be automatically distributed into the live MC server and all clients connected to this project.

For now, the MC server has to be on Debian 13 and all clients should be on macOS 26 with Apple M1-M5 chips.

For more details please check the git wiki.

## Repository Layout

```text
Client App
Server App
Live Backup
```

- `Client App`: macOS Swift client app and sync helper.
- `Server App`: Debian Swift server app, shared Swift package, DuckDB schemas, and project docs.
- `Live Backup`: current live DuckDB backup copied from the VPS.
