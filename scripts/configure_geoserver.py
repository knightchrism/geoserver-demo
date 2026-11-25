#!/usr/bin/env python3
"""Publish workspaces, stores, layers, styles, tile cache, and security.

Uses only the Python standard library so it can run on Windows or Linux.
GeoServer must already be up, and PostGIS must already hold the tables.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
import xml.sax.saxutils as xml_escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAYERS_PATH = ROOT / "config" / "layers.json"
STYLES = ROOT / "styles"
SECURITY = ROOT / "geoserver" / "security"


class GeoServerError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, user: str, password: str) -> None:
        self.base = base.rstrip("/")
        self.user = user
        self.password = password

    def call(
        self,
        method: str,
        path: str,
        data: str | None = None,
        content_type: str | None = None,
        accept: str = "application/json",
    ) -> tuple[int, str]:
        url = self.base + path
        body = None if data is None else data.encode("utf-8")
        request = urllib.request.Request(url, data=body, method=method)
        token = f"{self.user}:{self.password}".encode()
        request.add_header("Authorization", "Basic " + _b64(token))
        if content_type:
            request.add_header("Content-Type", content_type)
        if accept:
            request.add_header("Accept", accept)
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return response.status, response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", "replace")

    def expect(
        self,
        method: str,
        path: str,
        data: str | None = None,
        content_type: str | None = None,
        accept: str = "application/json",
        ok: tuple[int, ...] = (200, 201),
        ignore: tuple[int, ...] = (),
    ) -> tuple[int, str]:
        status, body = self.call(method, path, data, content_type, accept)
        if status in ok or status in ignore:
            print(f"  {method} {path} -> {status}")
            return status, body
        raise GeoServerError(f"{method} {path} -> {status}\n{body[:1200]}")


def _b64(raw: bytes) -> str:
    import base64

    return base64.b64encode(raw).decode("ascii")


def esc(value: str) -> str:
    return xml_escape.escape(value, {'"': "&quot;"})


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise GeoServerError(f"Missing environment variable {name}")
    return value


def create_workspace(client: Client, name: str, uri: str) -> None:
    status, _ = client.expect(
        "POST",
        "/rest/workspaces",
        json.dumps({"workspace": {"name": name}}),
        "application/json",
        ok=(201,),
        ignore=(409,),
    )
    client.expect(
        "PUT",
        f"/rest/namespaces/{name}",
        json.dumps({"namespace": {"prefix": name, "uri": uri}}),
        "application/json",
        ok=(200,),
    )
    if status == 409:
        print(f"  workspace {name} already present")


def create_postgis_store(client: Client, workspace: str, schema: str, store: str = "postgis") -> None:
    xml = f"""<dataStore>
  <name>{esc(store)}</name>
  <enabled>true</enabled>
  <connectionParameters>
    <entry key="host">postgis</entry>
    <entry key="port">5432</entry>
    <entry key="database">{esc(env('POSTGRES_DB'))}</entry>
    <entry key="user">{esc(env('POSTGRES_USER'))}</entry>
    <entry key="passwd">{esc(env('POSTGRES_PASSWORD'))}</entry>
    <entry key="dbtype">postgis</entry>
    <entry key="schema">{esc(schema)}</entry>
    <entry key="Expose primary keys">true</entry>
    <entry key="Loose bbox">true</entry>
    <entry key="preparedStatements">false</entry>
  </connectionParameters>
</dataStore>
"""
    status, _ = client.expect(
        "POST",
        f"/rest/workspaces/{workspace}/datastores",
        xml,
        "application/xml",
        accept="application/xml",
        ok=(201,),
        ignore=(409, 500),
    )
    if status != 201:
        client.expect(
            "PUT",
            f"/rest/workspaces/{workspace}/datastores/{store}",
            xml,
            "application/xml",
            accept="application/xml",
        )


def publish_feature(client: Client, layer: dict) -> None:
    workspace = layer["workspace"]
    store = layer.get("store", "postgis")
    xml = f"""<featureType>
  <name>{esc(layer['name'])}</name>
  <nativeName>{esc(layer['table'])}</nativeName>
  <title>{esc(layer['title'])}</title>
  <abstract>{esc(layer['abstract'])}</abstract>
  <srs>EPSG:26917</srs>
  <nativeCRS>EPSG:26917</nativeCRS>
  <projectionPolicy>FORCE_DECLARED</projectionPolicy>
  <enabled>true</enabled>
</featureType>
"""
    path = f"/rest/workspaces/{workspace}/datastores/{store}/featuretypes"
    # The layer may already exist on another store. Remove it by name first.
    client.call(
        "DELETE",
        f"/rest/layers/{workspace}:{layer['name']}?recurse=true",
        accept="application/xml",
    )
    client.call("DELETE", f"{path}/{layer['name']}?recurse=true", accept="application/xml")
    status, body = client.call("POST", path, xml, "application/xml", "application/xml")
    print(f"  POST {path} -> {status}")
    if status not in (200, 201, 409):
        raise GeoServerError(f"Could not publish {workspace}:{layer['name']}\n{body[:1200]}")
    client.expect(
        "PUT",
        f"{path}/{layer['name']}?recalculate=nativebbox,latlonbbox",
        xml,
        "application/xml",
        accept="application/xml",
    )


def publish_coverage(client: Client, layer: dict) -> None:
    workspace = layer["workspace"]
    filename = layer["file"]
    host_file = ROOT / "data" / filename
    if not host_file.exists():
        raise GeoServerError(f"Missing raster {host_file}")
    store = f"""<coverageStore>
  <name>{esc(layer['name'])}</name>
  <type>GeoTIFF</type>
  <enabled>true</enabled>
  <workspace>{esc(workspace)}</workspace>
  <url>file:///opt/data/{esc(filename)}</url>
</coverageStore>
"""
    path = f"/rest/workspaces/{workspace}/coveragestores"
    client.call(
        "DELETE",
        f"{path}/{layer['name']}?recurse=true&purge=none",
        accept="application/xml",
    )
    status, body = client.call("POST", path, store, "application/xml", "application/xml")
    print(f"  POST {path} -> {status}")
    if status not in (200, 201):
        status, body = client.call(
            "PUT",
            f"{path}/{layer['name']}",
            store,
            "application/xml",
            "application/xml",
        )
        print(f"  PUT {path}/{layer['name']} -> {status}")
        if status not in (200, 201):
            raise GeoServerError(body[:1200])
    coverage = f"""<coverage>
  <name>{esc(layer['name'])}</name>
  <title>{esc(layer['title'])}</title>
  <abstract>{esc(layer['abstract'])}</abstract>
  <srs>EPSG:26917</srs>
  <enabled>true</enabled>
</coverage>
"""
    cover_path = f"{path}/{layer['name']}/coverages"
    status, body = client.call("POST", cover_path, coverage, "application/xml", "application/xml")
    print(f"  POST {cover_path} -> {status}")
    if status not in (200, 201, 409):
        raise GeoServerError(f"Could not publish coverage {layer['name']}\n{body[:1200]}")
    client.call(
        "PUT",
        f"{cover_path}/{layer['name']}?recalculate=nativebbox,latlonbbox",
        coverage,
        "application/xml",
        "application/xml",
    )


def upload_style(client: Client, workspace: str, name: str) -> None:
    data_style = ROOT / "data" / "styles" / f"{name}.sld"
    repo_style = STYLES / f"{name}.sld"
    sld_path = data_style if data_style.exists() else repo_style
    if not sld_path.exists():
        raise GeoServerError(f"Missing style {name}.sld")
    sld = sld_path.read_text(encoding="utf-8")
    path = f"/rest/workspaces/{workspace}/styles?name={name}"
    status, body = client.call(
        "POST",
        path,
        sld,
        "application/vnd.ogc.sld+xml",
        "application/xml",
    )
    print(f"  POST style {workspace}:{name} -> {status}")
    if status not in (200, 201):
        status, body = client.call(
            "PUT",
            f"/rest/workspaces/{workspace}/styles/{name}",
            sld,
            "application/vnd.ogc.sld+xml",
            "application/xml",
        )
        print(f"  PUT style {workspace}:{name} -> {status}")
        if status not in (200, 201):
            raise GeoServerError(body[:1200])


def set_default_style(client: Client, workspace: str, layer: str, style: str) -> None:
    xml = f"""<layer>
  <defaultStyle>
    <name>{esc(style)}</name>
    <workspace>{esc(workspace)}</workspace>
  </defaultStyle>
  <enabled>true</enabled>
</layer>
"""
    client.expect(
        "PUT",
        f"/rest/layers/{workspace}:{layer}",
        xml,
        "application/xml",
        accept="application/xml",
    )


def enable_tile_cache(client: Client, workspace: str, layer: str) -> None:
    xml = f"""<GeoServerLayer>
  <enabled>true</enabled>
  <name>{esc(workspace)}:{esc(layer)}</name>
  <mimeFormats>
    <string>image/png</string>
    <string>image/jpeg</string>
  </mimeFormats>
  <gridSubsets>
    <gridSubset><gridSetName>EPSG:900913</gridSetName></gridSubset>
    <gridSubset><gridSetName>EPSG:4326</gridSetName></gridSubset>
  </gridSubsets>
  <metaWidthHeight>
    <int>4</int>
    <int>4</int>
  </metaWidthHeight>
  <expireCache>0</expireCache>
  <expireClients>0</expireClients>
  <parameterFilters>
    <styleParameterFilter>
      <key>STYLES</key>
      <defaultValue></defaultValue>
    </styleParameterFilter>
  </parameterFilters>
  <gutter>0</gutter>
</GeoServerLayer>
"""
    path = f"/gwc/rest/layers/{workspace}:{layer}.xml"
    status, body = client.call("PUT", path, xml, "application/xml", "application/xml")
    print(f"  PUT {path} -> {status}")
    if status not in (200, 201):
        status, body = client.call("POST", "/gwc/rest/layers.xml", xml, "application/xml", "application/xml")
        print(f"  POST /gwc/rest/layers.xml -> {status}")
        if status not in (200, 201):
            raise GeoServerError(body[:1200])


def ensure_service(client: Client, name: str) -> None:
    status, body = client.call("GET", f"/rest/services/{name}/settings", accept="application/json")
    if status != 200:
        print(f"  warning: could not read {name} settings ({status})")
        return
    document = json.loads(body)
    node = document.get(name, document)
    changed = False
    if node.get("enabled") is False:
        node["enabled"] = True
        changed = True
    if name == "wfs" and node.get("serviceLevel") not in ("COMPLETE", "TRANSACTIONAL"):
        node["serviceLevel"] = "COMPLETE"
        changed = True
    if not changed:
        print(f"  {name} already enabled")
        return
    payload = json.dumps({name: node} if name not in document else document)
    client.expect("PUT", f"/rest/services/{name}/settings", payload, "application/json")


def existing_roles(client: Client) -> set[str]:
    status, body = client.call("GET", "/rest/security/roles.json")
    if status != 200:
        return set()
    return set(json.loads(body).get("roles") or [])


def existing_users(client: Client) -> set[str]:
    status, body = client.call("GET", "/rest/security/usergroup/users.json")
    if status != 200:
        return set()
    return {user.get("userName") for user in json.loads(body).get("users") or []}


def ensure_role(client: Client, role: str, roles: set[str]) -> None:
    if role in roles:
        print(f"  role {role} already present")
        return
    status, body = client.call("POST", f"/rest/security/roles/role/{role}", accept="application/json")
    if status in (200, 201):
        print(f"  role {role} created")
        roles.add(role)
        return
    raise GeoServerError(f"Could not create role {role}: {status} {body[:600]}")


def ensure_user(client: Client, username: str, password: str, role: str, users: set[str]) -> None:
    xml = f"""<user>
  <userName>{esc(username)}</userName>
  <password>{esc(password)}</password>
  <enabled>true</enabled>
</user>
"""
    if username in users:
        status, body = client.call(
            "PUT",
            f"/rest/security/usergroup/user/{username}",
            xml,
            "application/xml",
            "application/xml",
        )
        print(f"  PUT user {username} -> {status}")
        if status not in (200, 201):
            print(f"  keeping the existing password for {username}")
    else:
        status, body = client.call(
            "POST",
            "/rest/security/usergroup/users",
            xml,
            "application/xml",
            "application/xml",
        )
        print(f"  POST user {username} -> {status}")
        if status not in (200, 201):
            raise GeoServerError(f"Could not save user {username}: {status} {body[:800]}")
        users.add(username)
    status, body = client.call(
        "POST",
        f"/rest/security/roles/role/{role}/user/{username}",
        accept="application/xml",
    )
    if status in (200, 201) or "already" in body.lower():
        print(f"  granted {role} to {username}")
        return
    raise GeoServerError(f"Could not grant {role} to {username}: {status} {body[:800]}")


def rotate_master_password(client: Client) -> None:
    if os.environ.get("SKIP_MASTER") == "1":
        print("  master password already rotated")
        return
    new_password = env("GEOSERVER_MASTER_PASSWORD")
    xml = f"""<masterPassword>
  <oldMasterPassword>geoserver</oldMasterPassword>
  <newMasterPassword>{esc(new_password)}</newMasterPassword>
</masterPassword>
"""
    for path in ("/rest/security/masterpw", "/rest/security/masterpw.xml"):
        status, body = client.call("PUT", path, xml, "application/xml", "application/xml")
        print(f"  PUT {path} -> {status}")
        if status in (200, 201):
            return
        if status == 404:
            continue
        if status in (400, 422):
            print("  master password already rotated")
            return
        print(f"  master password response: {body[:400]}")
        return
    print("  warning: master password endpoint was not found. See docs/SECURITY.md.")


def apply_security_files(client: Client) -> None:
    for name in ("layers.properties", "services.properties"):
        text = (SECURITY / name).read_text(encoding="utf-8")
        status, body = client.call(
            "PUT",
            f"/rest/resource/security/{name}",
            text,
            "text/plain",
            "text/plain",
        )
        print(f"  PUT security file {name} -> {status}")
        if status not in (200, 201):
            print(f"  resource API said: {body[:400]}")
    rules = {
        "*.*.r": "ADMIN",
        "*.*.w": "ADMIN",
        "public.*.r": "ROLE_ANONYMOUS,ROLE_PUBLIC,ROLE_ANALYST,ROLE_EDITOR,ADMIN",
        "public.*.w": "ROLE_EDITOR,ADMIN",
        "restricted.*.r": "ROLE_ANALYST,ROLE_EDITOR,ADMIN",
        "restricted.*.w": "ROLE_EDITOR,ADMIN",
    }
    status, body = client.call(
        "PUT",
        "/rest/security/acl/layers",
        json.dumps(rules),
        "application/json",
    )
    print(f"  PUT layer rules -> {status}")
    if status not in (200, 201):
        print(body[:600])
    services = {
        "*.*": "*",
        "wfs.Transaction": "ROLE_EDITOR,ADMIN",
        "wfs.LockFeature": "ROLE_EDITOR,ADMIN",
        "wfs.GetFeatureWithLock": "ROLE_EDITOR,ADMIN",
    }
    status, body = client.call(
        "PUT",
        "/rest/security/acl/services",
        json.dumps(services),
        "application/json",
    )
    print(f"  PUT service rules -> {status}")
    if status not in (200, 201):
        print(body[:600])
    status, body = client.call("POST", "/rest/reload", accept="application/json")
    print(f"  POST /rest/reload -> {status}")


def publish_catalog(client: Client, catalog: dict) -> None:
    for workspace in catalog["workspaces"]:
        create_workspace(client, workspace["name"], workspace["uri"])
    stores = {}
    for layer in catalog["vectors"]:
        stores[(layer["workspace"], layer.get("store", "postgis"), layer["schema"])] = True
    for workspace, store, schema in stores:
        create_postgis_store(client, workspace, schema, store)
    styled = set()
    for layer in catalog["vectors"]:
        publish_feature(client, layer)
        if layer["style"] not in styled:
            upload_style(client, layer["workspace"], layer["style"])
            styled.add(layer["style"])
        set_default_style(client, layer["workspace"], layer["name"], layer["style"])
        if layer.get("tiled"):
            enable_tile_cache(client, layer["workspace"], layer["name"])
    for layer in catalog["rasters"]:
        publish_coverage(client, layer)
        upload_style(client, layer["workspace"], layer["style"])
        set_default_style(client, layer["workspace"], layer["name"], layer["style"])
        if layer.get("tiled"):
            enable_tile_cache(client, layer["workspace"], layer["name"])


def main() -> int:
    base = os.environ.get("GEOSERVER_INTERNAL_URL", "http://127.0.0.1:8080/geoserver")
    client = Client(base, env("GEOSERVER_ADMIN_USER"), env("GEOSERVER_ADMIN_PASSWORD"))
    status, body = client.call("GET", "/rest/about/version.json")
    if status != 200:
        print(f"GeoServer REST is not ready at {base} ({status}).", file=sys.stderr)
        print(body[:400], file=sys.stderr)
        return 1
    print("[configure] signed in to GeoServer")
    catalog = json.loads(LAYERS_PATH.read_text(encoding="utf-8"))
    try:
        rotate_master_password(client)
        roles = existing_roles(client)
        users = existing_users(client)
        for role in ("ROLE_PUBLIC", "ROLE_ANALYST", "ROLE_EDITOR"):
            ensure_role(client, role, roles)
        ensure_user(client, env("VIEWER_USER"), env("VIEWER_PASSWORD"), "ROLE_PUBLIC", users)
        ensure_user(client, env("ANALYST_USER"), env("ANALYST_PASSWORD"), "ROLE_ANALYST", users)
        ensure_user(client, env("EDITOR_USER"), env("EDITOR_PASSWORD"), "ROLE_EDITOR", users)
        publish_catalog(client, catalog)
        for service in ("wms", "wfs", "wcs"):
            ensure_service(client, service)
        apply_security_files(client)
    except GeoServerError as exc:
        print(f"[configure] FAILED: {exc}", file=sys.stderr)
        return 1
    print("[configure] layers, styles, tile cache, and security are in place")
    return 0


if __name__ == "__main__":
    sys.exit(main())
