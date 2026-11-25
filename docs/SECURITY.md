# Security decisions, in plain words

This is a demonstration server. It shows the controls a public map service should have. It is not a substitute for your agency's own security review.

## Passwords are not in the repository

`.env.example` contains the names of the settings and obvious placeholders such as `change-me-geoserver-password`. The real file is `.env`, which Git is told to ignore. `make env` can fill it with random passwords on your machine. The start scripts refuse to run while a placeholder, the old `geoserver` password, or a very short password is still in place.

The database, GeoServer, Grafana, and Keycloak each have their own password.

## The well-known GeoServer admin account is replaced

GeoServer ships with the login `admin` / `geoserver`. This stack will not start with that pair. On first start, a small script writes the username and password from `.env`. The stock GeoServer Docker script would rebuild the user list on every restart and delete the analyst and editor. The script in this repository only refreshes the admin password after the other accounts exist.

There is also a master password. It locks the security configuration itself. It is separate from the admin login, and the setup script changes it away from `geoserver`.

## Five kinds of people

| Person | What they can do |
| --- | --- |
| Public visitor, not signed in | Read roads, tracts, imagery, elevation, and hillshade. |
| Viewer | The same public layers, after signing in. Not the parcels or installations. |
| Analyst | Public layers plus parcels and MIRTA polygons. |
| Editor | Everything an analyst can read, plus adding, updating, and deleting editor notes. Writes to every other layer are refused. |
| Admin | The GeoServer administration pages, from an approved network. |

A request for a restricted layer with no sign-in gets **401**. A signed-in person who is not allowed gets **403**. The server is in "challenge" mode, so it does not pretend the layer is missing. That is what produces the failures the dashboard counts.

The parcel table is keyed by `re`. Owner names are not in the data. MIRTA features are polygons. The installation name column is `sitename`.

The editor's write rule is `restricted.editor_notes` only. `public` layers and the other `restricted` layers are read-only for that account. WFS transactions are still limited to the editor and the administrator, and the layer rule is what stops an editor from changing parcels or roads.

## GeoServer does not connect as the database owner

PostGIS is loaded by the database owner (`POSTGRES_USER`). GeoServer uses a second login, `GEOSERVER_DB_USER`. That role can read the map tables. It can insert, update, and delete `restricted.editor_notes` and use that table's id sequence. It cannot write the other tables, and it cannot create objects in `public` or `restricted`. `scripts/grant-app-role.sh` applies this, and both `make load-data` and `make configure` run it. A stolen GeoServer password still cannot rewrite the parcel table.

## The admin website is not for the whole internet

Nginx allows the GeoServer web interface, the REST configuration API, the tile-cache admin, and Grafana only from approved addresses. By default those are loopback, the Docker gateway (so a browser on the same computer works), and private networks. Containers that simulate visitors sit on a network that is refused, so their attempts show up as 403.

Set `ADMIN_ALLOW_CIDRS` in `.env` to your office or home address, written as a single address with `/32`, before you put this on a public virtual machine. Do not leave the broad private ranges in place if the machine itself is on a shared private network you do not trust.

## HTTPS

Port 80 only redirects to HTTPS, aside from the Let's Encrypt check path.

The TLS settings allow TLS 1.2 and TLS 1.3 and use modern cipher suites. Responses include HSTS, nosniff, a frame restriction, a referrer policy, and a content security policy. The content security policy still allows inline scripts because GeoServer's own preview page uses them.

`TLS_MODE` in `.env` is `local` or `letsencrypt`. `make up` writes a self-signed certificate when `certs/server.crt` is missing, and it refreshes a local certificate that does not list `DNS:nginx` when `TLS_MODE=local`. It does not replace a certificate that is already present when `TLS_MODE=letsencrypt`, and it does not replace a Let's Encrypt certificate in either mode.

On a laptop, `scripts/tls-local.sh` makes a local certificate authority. Trust `certs/ca.crt` if you want the browser warning to go away. On the Ubuntu VM, `scripts/tls-certbot.sh` requests a real certificate and copies it to the same files Nginx already uses, so the Compose file does not change. `scripts/tls-renew.sh` runs Certbot again, copies `fullchain.pem` and `privkey.pem` with `scripts/tls-deploy-hook.sh`, and reloads Nginx. `sudo sh scripts/bootstrap-vm.sh --enable-cert-renew` installs a systemd timer for that script. `--with-cron` installs the cron example instead.

`make verify` and `make simulate` trust `certs/ca.crt` when `TLS_MODE=local`. When `TLS_MODE=letsencrypt` they use the system certificate store and the public host name on the certificate. `VERIFY_CA` points either command at a CA file of your choosing.

## The database is not on the public internet

PostGIS listens on the Docker network and on `127.0.0.1` of the host, so the load script can reach it. It is not published on the public address. GeoServer is the same: `127.0.0.1:8080` for setup scripts, and the public goes through Nginx.

## Java and add-ons

The November 2026 Java issue known as Java4Shell is in the Java runtime's fast Base64 decoder, not in GeoServer itself. The container sets `JAVA_TOOL_OPTIONS=-XX:-UseBASE64Intrinsics`, which is the workaround the GeoServer project published for the official image.

The image is GeoServer 3.0.2, the current stable release, which includes the October 2026 security fixes. This demo does not install the WPS, printing, JDBC user-store, GeoFence, or community style add-ons that those advisories called out. Core WMS, WFS, WMTS, and WCS are enough.

## Firewall and fail2ban, on the VM only

`scripts/harden-vm.sh` is not part of `make up`. On the Ubuntu machine, run it yourself with `sudo sh scripts/harden-vm.sh --yes`. It allows SSH, HTTP, and HTTPS, then turns the firewall on, and it installs a fail2ban jail for repeated 401 and 403 responses on the admin paths.

Docker's userland proxy can hide the visitor's real IP, which would make fail2ban see everyone as the Docker gateway. The script explains that and can set `userland-proxy` to false if you pass `--restart-docker` from a console you can recover.

## Keycloak is off

An optional Compose profile named `oidc` can start Keycloak on `127.0.0.1:8081`. Nothing starts it unless you ask. Turning on GeoServer OpenID Connect also means installing the OAuth2 OpenID Connect extension and filling in the Keycloak client. Leave that off until you have a reason. The accounts in `.env` are the ones this demo uses.

## What this demo does not do

It does not claim to be an accredited county system. It does not ship the parcel, imagery, or elevation files. It does not put secrets in Git. A public repository with no open-source license still needs those secrets to stay off the internet, which is why `.gitignore` covers `.env`, keys, Let's Encrypt directories, GeoPackages, rasters, SQL dumps, database volumes, and logs.
