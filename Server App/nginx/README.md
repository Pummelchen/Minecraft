# Pummelchen nginx

This directory contains the nginx-facing files for the live Pummelchen server website.

- `sites-available/pummelchen-swift.conf` is the nginx virtual host used on the VPS.
- `site/public/` is the tracked website source currently served from `/opt/pummelchen-swift/runtime/site/public`.
- `site/public/downloads/current-release.json` and `current-release.txt` are small release pointers kept with the website.

Generated release payloads are intentionally not tracked here. DMGs, MRPACKs, release ZIPs, copied mod files, and full release directories are produced by the Swift server app and live under the VPS runtime downloads directory.
