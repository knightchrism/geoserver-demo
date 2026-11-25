# GeoKnight GIS

A GeoKnight GIS demonstration of a secure online mapping server that shares map layers, aerial imagery, and elevation data. Includes user sign-in, simulated visitor traffic, a dashboard showing usage and performance, and step-by-step setup instructions.

This is a working map server for a GIS portfolio. Christopher Knight runs GeoKnight GIS. The sample window covers downtown Jacksonville and NAS Jacksonville. Public visitors can see roads, census tracts, aerial imagery, elevation, and a hillshade. Parcel polygons and installation points require a sign-in.

Copyright (c) 2026 GeoKnight GIS. All rights reserved.

This repository is public and is not open source. There is no LICENSE file. Do not copy it into another product without permission.

## What you need

- **Windows:** Docker Desktop, with the WSL2 engine turned on. Put the repository somewhere Docker can see, such as `C:\dev\geoserver-demo`.
- **Linux:** Docker Engine and the Docker Compose plugin on Ubuntu 24.04. The load step also wants GDAL (`gdal-bin`) so it can read a GeoPackage or the area-of-interest file. The SQL dumps load without GDAL.

The first start downloads a few large images. Give Docker at least 6 GB of memory. GeoServer alone wants about 1.5 GB.

## Quick start

These commands are safe to copy. Each one is explained in the sentence above it.

1. Create a private settings file. This writes passwords on your computer and does not upload them.

```bash
make env
```

2. Start the server, load map data, and publish the layers. The first time, this also builds a small stand-in dataset if the real files are not in `data/` yet.

```bash
make bootstrap
```

3. Open the site.

- Map home: <https://localhost/>
- Interactive roads preview: use the button on that page
- Dashboard: <https://localhost/grafana/> (the Grafana user and password are in `.env`)

The laptop certificate is self-signed. Your browser will warn you until you trust `certs/ca.crt`.

4. Pretend to be visitors for about two minutes, then check that the rules hold.

```bash
make simulate
make verify
```

5. Stop the server when you are done. Your loaded data is kept.

```bash
make down
```

### Windows PowerShell

From `C:\dev\geoserver-demo`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\new-env.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\windows\bootstrap.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\windows\simulate.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\windows\smoke-test.ps1
```

## Accounts

| Who | Username in `.env` | Can see |
| --- | --- | --- |
| Public visitor | no sign-in | Roads, tracts, imagery, elevation, hillshade |
| Viewer | `VIEWER_USER` | The same public layers |
| Analyst | `ANALYST_USER` | Public layers plus parcels and installations |
| Editor | `EDITOR_USER` | Analyst access, and can add or delete editor notes |
| Admin | `GEOSERVER_ADMIN_USER` | The GeoServer admin pages, from an approved network |

The old `admin` / `geoserver` login does not work. That is intentional.

## Map data

The files are not in git. `make load-data` expects this layout:

```
data/aoi.geojson
data/aoi_26917.geojson
data/vector/gpkg/{parcels,roads,mirta_fl,tracts}.gpkg
data/vector/sql/{parcels,roads,mirta_fl,tracts}.sql
data/imagery/naip_2025_jax_aoi_cog.tif
data/elevation/dem_3dep_aoi_cog.tif
data/elevation/hillshade_aoi_cog.tif
data/styles/dem_colorramp.sld
data/styles/hillshade.sld
```

The SQL files are ogr2ogr PGDump scripts in EPSG:26917 with a GiST index. If a SQL file is present, it is what gets loaded. The parcel key is `RE`. Owner names are not included. The installation name column is `SITENAME`.

The area of interest is EPSG:26917 X 429240–438990, Y 3341670–3358380 (about longitude -81.736 to -81.634, latitude 30.204 to 30.356).

The full 2025 NAIP image is about 791 MB at 0.3 m. The elevation grid is a 1 m float32 Cloud Optimized GeoTIFF with nodata `-999999` and elevations about -3 m to 19 m. The hillshade is 8-bit. The color ramp and hillshade styles are written for that range.

If those files are missing, `make load-data` builds a small sample with the same names and the same extent. To try the public download path instead (Census TIGER roads, USGS 3DEP, Planetary Computer NAIP), run `make fetch-data`. That path needs a network and GDAL, and it can take a long time.

## On an Ubuntu virtual machine

Use the same commands. Then:

- Point DNS at the machine and set `PUBLIC_HOST`, `LETSENCRYPT_DOMAIN`, and `LETSENCRYPT_EMAIL` in `.env`.
- Request a real certificate with `sh scripts/tls-certbot.sh`.
- Turn on the firewall with `sudo sh scripts/harden-vm.sh --yes` after you have read the script. It allows SSH, HTTP, and HTTPS.

Add your own IP to `ADMIN_ALLOW_CIDRS` if you will open the admin pages from somewhere other than the machine itself.

## If the containers cannot see each other

On a fresh Docker install this does not come up. If GeoServer logs say the database connection timed out, and `iptables-legacy -S` shows a `FORWARD` policy of `DROP` while Docker is using the nftables backend, the old rules are dropping traffic between containers. `sudo iptables-legacy -P FORWARD ACCEPT` clears that. Do not do this on a machine where you rely on that drop rule for something else.

## Where to read more

- [How it is wired](docs/ARCHITECTURE.md)
- [Why the security choices were made](docs/SECURITY.md)

## Commands

| Command | What it does |
| --- | --- |
| `make env` | Write `.env` once |
| `make up` | Start GeoServer, PostGIS, Nginx, and the dashboard |
| `make load-data` | Load the SQL dumps or GeoPackages |
| `make configure` | Publish layers, styles, tile cache, and accounts |
| `make bootstrap` | `up`, then `load-data`, then `configure` |
| `make simulate` | Headless Locust run, about two minutes |
| `make verify` | Check HTTPS, the access rules, and that the dashboard has traffic |
| `make down` | Stop everything, keep the data |
| `make reset` | Stop and delete the Docker volumes |

Headless Locust, if you want to call it yourself:

```bash
docker compose --profile sim up --no-deps --force-recreate locust
```

The length is `SIM_DURATION` in `.env` (default `2m`). The personas are an anonymous public viewer, a signed-in analyst, an editor doing WFS transactions, and an intruder who is supposed to be refused.
