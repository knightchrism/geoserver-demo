"""Visitor simulation for the GeoKnight GIS map server.

Personas
  public     anonymous viewer of roads, imagery, elevation, and repeated tiles
  analyst    signed-in reader of parcels and installation polygons
  editor     signed-in editor inserting and deleting a note with WFS-T
  intruder   anonymous or bad-password calls that should be refused

The intruder treats HTTP 401 and 403 as a successful outcome. Those responses
are what the dashboard counts as authentication failures.
"""

from __future__ import annotations

import os
import random
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from locust import HttpUser, between, events, task

METRICS = {"public": 0, "analyst": 0, "editor": 0, "intruder": 0}
METRICS_LOCK = threading.Lock()


def _load_extent() -> dict[str, str]:
    values: dict[str, str] = {}
    for path in (Path("/config/extent.env"), Path("/data/extent.env")):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


EXTENT = _load_extent()
BBOX_26917 = ",".join(
    [
        EXTENT.get("MIN_X", "429240"),
        EXTENT.get("MIN_Y", "3341670"),
        EXTENT.get("MAX_X", "438990"),
        EXTENT.get("MAX_Y", "3358380"),
    ]
)
# Web-mercator tiles over the Jacksonville AOI (downtown through NAS Jacksonville).
TILES = [
    (12, 1118, 1686),
    (13, 2237, 3372),
    (13, 2236, 3372),
    (13, 2237, 3371),
    (13, 2238, 3370),
    (14, 4474, 6744),
    (14, 4475, 6742),
]


def _render_metrics() -> bytes:
    lines = [
        "# HELP locust_users Simulated visitors currently running",
        "# TYPE locust_users gauge",
    ]
    with METRICS_LOCK:
        snapshot = dict(METRICS)
    for persona, value in snapshot.items():
        lines.append(f'locust_users{{persona="{persona}"}} {value}')
    lines.append("")
    return "\n".join(lines).encode()


class _MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/metrics"):
            body = _render_metrics()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        return


@events.test_start.add_listener
def _start_metrics(environment, **kwargs) -> None:
    server = ThreadingHTTPServer(("0.0.0.0", 9646), _MetricsHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def _ca_verify():
    """Trust VERIFY_CA, the system store on a public certificate, or the local CA."""
    override = os.environ.get("LOCUST_CA_FILE", "").strip()
    if override:
        return override
    if os.environ.get("TLS_MODE", "local").strip() == "letsencrypt":
        system = "/etc/ssl/certs/ca-certificates.crt"
        if os.path.isfile(system):
            return system
        return True
    local = "/certs/ca.crt"
    if os.path.isfile(local):
        return local
    return True


def _bump(persona: str, delta: int) -> None:
    with METRICS_LOCK:
        METRICS[persona] = max(0, METRICS.get(persona, 0) + delta)


class BasePersona(HttpUser):
    abstract = True
    wait_time = between(0.4, 1.6)
    persona = "public"

    def on_start(self) -> None:
        self.client.verify = _ca_verify()
        _bump(self.persona, 1)

    def on_stop(self) -> None:
        _bump(self.persona, -1)


def _wms(layers: str, transparent: str = "true") -> dict[str, str]:
    return {
        "service": "WMS",
        "version": "1.1.1",
        "request": "GetMap",
        "layers": layers,
        "styles": "",
        "srs": "EPSG:26917",
        "bbox": BBOX_26917,
        "width": "512",
        "height": "512",
        "format": "image/png",
        "transparent": transparent,
    }


class PublicViewer(BasePersona):
    weight = 8
    persona = "public"

    @task(4)
    def roads(self) -> None:
        self.client.get("/geoserver/public/wms", params=_wms("public:roads"), name="WMS roads")

    @task(2)
    def imagery(self) -> None:
        self.client.get("/geoserver/public/wms", params=_wms("public:naip", "false"), name="WMS naip")

    @task(2)
    def elevation(self) -> None:
        self.client.get("/geoserver/public/wms", params=_wms("public:dem", "false"), name="WMS dem")

    @task(1)
    def hillshade(self) -> None:
        self.client.get(
            "/geoserver/public/wms", params=_wms("public:hillshade", "false"), name="WMS hillshade"
        )

    @task(1)
    def capabilities(self) -> None:
        self.client.get(
            "/geoserver/ows",
            params={"service": "WMS", "version": "1.3.0", "request": "GetCapabilities"},
            name="WMS capabilities",
        )

    @task(1)
    def roads_wfs(self) -> None:
        self.client.get(
            "/geoserver/public/wfs",
            params={
                "service": "WFS",
                "version": "2.0.0",
                "request": "GetFeature",
                "typeNames": "public:roads",
                "count": "5",
            },
            name="WFS roads",
        )

    @task(6)
    def tiles(self) -> None:
        zoom, column, row = random.choice(TILES)
        # Ask for the same few tiles over and over so the cache can report hits.
        self.client.get(
            "/geoserver/gwc/service/wmts",
            params={
                "SERVICE": "WMTS",
                "REQUEST": "GetTile",
                "VERSION": "1.0.0",
                "LAYER": "public:roads",
                "STYLE": "",
                "TILEMATRIXSET": "EPSG:900913",
                "TILEMATRIX": f"EPSG:900913:{zoom}",
                "TILEROW": str(row),
                "TILECOL": str(column),
                "FORMAT": "image/png",
            },
            name="WMTS roads",
        )


class Analyst(BasePersona):
    weight = 3
    persona = "analyst"

    def on_start(self) -> None:
        super().on_start()
        self.client.auth = (os.environ["ANALYST_USER"], os.environ["ANALYST_PASSWORD"])

    @task(3)
    def parcels(self) -> None:
        self.client.get(
            "/geoserver/restricted/wfs",
            params={
                "service": "WFS",
                "version": "2.0.0",
                "request": "GetFeature",
                "typeNames": "restricted:parcels",
                "count": "10",
            },
            name="WFS parcels",
        )

    @task(2)
    def installations(self) -> None:
        self.client.get(
            "/geoserver/restricted/wms",
            params=_wms("restricted:mirta"),
            name="WMS mirta",
        )

    @task(1)
    def parcel_map(self) -> None:
        self.client.get(
            "/geoserver/restricted/wms",
            params=_wms("restricted:parcels"),
            name="WMS parcels",
        )

    @task(1)
    def coverage(self) -> None:
        self.client.get(
            "/geoserver/ows",
            params={"service": "WCS", "version": "2.0.1", "request": "GetCapabilities"},
            name="WCS capabilities",
        )


class Editor(BasePersona):
    weight = 1
    persona = "editor"

    def on_start(self) -> None:
        super().on_start()
        self.client.auth = (os.environ["EDITOR_USER"], os.environ["EDITOR_PASSWORD"])

    @task
    def transaction(self) -> None:
        east = 436900 + random.randint(0, 400)
        north = 3355200 + random.randint(0, 400)
        insert = f"""<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0"
  xmlns:wfs="http://www.opengis.net/wfs"
  xmlns:gml="http://www.opengis.net/gml"
  xmlns:restricted="https://geoknight.gis/restricted">
  <wfs:Insert>
    <restricted:editor_notes>
      <restricted:note>field check</restricted:note>
      <restricted:created_by>editor</restricted:created_by>
      <restricted:geom>
        <gml:Point srsName="http://www.opengis.net/gml/srs/epsg.xml#26917">
          <gml:pos>{east} {north}</gml:pos>
        </gml:Point>
      </restricted:geom>
    </restricted:editor_notes>
  </wfs:Insert>
</wfs:Transaction>
"""
        with self.client.post(
            "/geoserver/restricted/wfs",
            data=insert,
            headers={"Content-Type": "text/xml"},
            name="WFS-T insert",
            catch_response=True,
        ) as response:
            text = response.text or ""
            if response.status_code != 200 or "Exception" in text:
                response.failure(f"insert failed {response.status_code}")
                return
            response.success()
            fid = _first_fid(text)
        if not fid:
            return
        delete = f"""<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0" xmlns:wfs="http://www.opengis.net/wfs">
  <wfs:Delete typeName="restricted:editor_notes">
    <ogc:Filter xmlns:ogc="http://www.opengis.net/ogc">
      <ogc:FeatureId fid="{fid}"/>
    </ogc:Filter>
  </wfs:Delete>
</wfs:Transaction>
"""
        self.client.post(
            "/geoserver/restricted/wfs",
            data=delete,
            headers={"Content-Type": "text/xml"},
            name="WFS-T delete",
        )


class Intruder(BasePersona):
    weight = 2
    persona = "intruder"

    @task(3)
    def protected_layer(self) -> None:
        with self.client.get(
            "/geoserver/restricted/wfs",
            params={
                "service": "WFS",
                "version": "2.0.0",
                "request": "GetFeature",
                "typeNames": "restricted:parcels",
                "count": "1",
            },
            name="intruder parcels",
            catch_response=True,
        ) as response:
            _expect_denied(response)

    @task(2)
    def bad_password(self) -> None:
        self.client.auth = ("analyst", "not-the-password")
        with self.client.get(
            "/geoserver/restricted/wms",
            params=_wms("restricted:mirta"),
            name="intruder bad password",
            catch_response=True,
        ) as response:
            _expect_denied(response)
        self.client.auth = None

    @task(2)
    def admin_page(self) -> None:
        with self.client.get(
            "/geoserver/web/",
            name="intruder admin ui",
            catch_response=True,
            allow_redirects=False,
        ) as response:
            _expect_denied(response)

    @task(1)
    def rest_api(self) -> None:
        with self.client.get(
            "/geoserver/rest/workspaces",
            name="intruder rest",
            catch_response=True,
        ) as response:
            _expect_denied(response)


def _expect_denied(response) -> None:
    if response.status_code in (401, 403):
        response.success()
        return
    text = (response.text or "")[:180]
    response.failure(f"expected 401 or 403, got {response.status_code} {text}")


def _first_fid(text: str) -> str:
    marker = 'fid="'
    start = text.find(marker)
    if start < 0:
        return ""
    start += len(marker)
    end = text.find('"', start)
    if end < 0:
        return ""
    return text[start:end]
