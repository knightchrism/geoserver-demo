#!/usr/bin/env python3
"""Build the Jacksonville demonstration data, or download public sources.

The repository does not contain the data. This script writes the data-folder
layout under ./data: vector/gpkg, vector/sql dumps in the jax_demo schema,
imagery, elevation, AOI GeoJSON, and the elevation styles. --synthetic writes
a small stand-in that covers the same Jacksonville extent as the full extract.
Column names are lowercase, matching the county package (re, sitename).

  python3 scripts/fetch_data.py --synthetic
  python3 scripts/fetch_data.py --download tiger,dem,naip

--synthetic always works offline. It builds a downtown window in EPSG:26917
with a road grid, parcel grid, sample installation polygons, a small elevation
model, a hillshade, and a stand-in aerial image.

--download uses:
  * U.S. Census TIGER/Line roads for Duval County (FIPS 12031)
  * USGS 3DEP elevation via The National Map ImageServer
  * NAIP imagery via the Planetary Computer STAC API

Parcels and installation polygons stay synthetic unless you already placed a
GeoPackage at the expected path. Those extracts are not a single small public
file, and the installation polygons in this demo are not an authoritative MIRTA
copy.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from osgeo import gdal, ogr, osr

gdal.UseExceptions()
osr.UseExceptions()

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
GPKG = DATA / "vector" / "gpkg"
SQL = DATA / "vector" / "sql"
IMAGERY = DATA / "imagery"
ELEVATION = DATA / "elevation"
DATA_STYLES = DATA / "styles"

# Jacksonville AOI: downtown through NAS Jacksonville. Keep in sync with config/extent.env.
MIN_LON, MIN_LAT = -81.736, 30.204
MAX_LON, MAX_LAT = -81.634, 30.356
MIN_X, MIN_Y = 429240.0, 3341670.0
MAX_X, MAX_Y = 438990.0, 3358380.0

TIGER_URL = "https://www2.census.gov/geo/tiger/TIGER2024/ROADS/tl_2024_12031_roads.zip"
USER_AGENT = "GeoKnightGIS-demo/1.0 (portfolio; educational)"


def log(message: str) -> None:
    print(f"[data] {message}", flush=True)


def ensure_dirs() -> None:
    for path in (GPKG, SQL, IMAGERY, ELEVATION, DATA_STYLES):
        path.mkdir(parents=True, exist_ok=True)


def srs_26917() -> osr.SpatialReference:
    srs = osr.SpatialReference()
    srs.ImportFromEPSG(26917)
    srs.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
    return srs


def write_extent(path: Path) -> None:
    path.write_text(
        "\n".join(
            [
                "MIN_LON=-81.736",
                "MIN_LAT=30.204",
                "MAX_LON=-81.634",
                "MAX_LAT=30.356",
                f"MIN_X={MIN_X:.0f}",
                f"MIN_Y={MIN_Y:.0f}",
                f"MAX_X={MAX_X:.0f}",
                f"MAX_Y={MAX_Y:.0f}",
                "CENTER_LON=-81.685",
                "CENTER_LAT=30.280",
                "",
            ]
        ),
        encoding="utf-8",
    )


def new_layer(path: Path, name: str, geom_type: int) -> tuple[ogr.DataSource, ogr.Layer]:
    if path.exists():
        path.unlink()
    driver = ogr.GetDriverByName("GPKG")
    datasource = driver.CreateDataSource(str(path))
    layer = datasource.CreateLayer(name, srs_26917(), geom_type)
    return datasource, layer


def add_string_field(layer: ogr.Layer, name: str, width: int = 80) -> None:
    field = ogr.FieldDefn(name, ogr.OFTString)
    field.SetWidth(width)
    layer.CreateField(field)


def write_roads(path: Path) -> None:
    datasource, layer = new_layer(path, "roads", ogr.wkbMultiLineString)
    for name in ("fullname", "mtfcc", "rttyp", "linearid", "source"):
        add_string_field(layer, name)
    east_west = [
        "Bay St",
        "Forsyth St",
        "Adams St",
        "Monroe St",
        "Duval St",
        "Church St",
        "Beaver St",
        "Union St",
        "State St",
        "Ashley St",
    ]
    north_south = [
        "Broad St",
        "Laura St",
        "Main St",
        "Ocean St",
        "Newnan St",
        "Market St",
        "Washington St",
        "Liberty St",
        "Hogan St",
        "Julia St",
    ]
    step = 450.0

    def add_line(x1: float, y1: float, x2: float, y2: float, fullname: str, index: int, kind: str) -> None:
        line = ogr.Geometry(ogr.wkbLineString)
        line.AddPoint(x1, y1)
        line.AddPoint(x2, y2)
        multi = ogr.Geometry(ogr.wkbMultiLineString)
        multi.AddGeometry(line)
        feature = ogr.Feature(layer.GetLayerDefn())
        feature.SetGeometry(multi)
        feature.SetField("fullname", fullname)
        feature.SetField("mtfcc", "S1400")
        feature.SetField("rttyp", "M")
        feature.SetField("linearid", f"synth-{kind}-{index:04d}")
        feature.SetField("source", "synthetic-sample")
        layer.CreateFeature(feature)
        feature = None

    y = MIN_Y + 200
    index = 0
    while y < MAX_Y - 200:
        add_line(MIN_X + 150, y, MAX_X - 150, y, east_west[index % len(east_west)], index, "h")
        y += step
        index += 1
    x = MIN_X + 200
    index = 0
    while x < MAX_X - 200:
        add_line(x, MIN_Y + 150, x, MAX_Y - 150, north_south[index % len(north_south)], index, "v")
        x += step
        index += 1
    count = layer.GetFeatureCount()
    datasource = None
    log(f"wrote {count} synthetic road features to {path.name}")


def write_parcels(path: Path) -> None:
    datasource, layer = new_layer(path, "parcels", ogr.wkbMultiPolygon)
    add_string_field(layer, "re", 32)
    add_string_field(layer, "source", 40)
    acres = ogr.FieldDefn("acres", ogr.OFTReal)
    layer.CreateField(acres)
    size = 700.0
    row = 0
    y = MIN_Y + 180
    while y + size < MAX_Y - 80:
        col = 0
        x = MIN_X + 180
        while x + size < MAX_X - 80:
            ring = ogr.Geometry(ogr.wkbLinearRing)
            ring.AddPoint(x, y)
            ring.AddPoint(x + size - 12, y)
            ring.AddPoint(x + size - 12, y + size - 12)
            ring.AddPoint(x, y + size - 12)
            ring.AddPoint(x, y)
            polygon = ogr.Geometry(ogr.wkbPolygon)
            polygon.AddGeometry(ring)
            multi = ogr.Geometry(ogr.wkbMultiPolygon)
            multi.AddGeometry(polygon)
            feature = ogr.Feature(layer.GetLayerDefn())
            feature.SetGeometry(multi)
            feature.SetField("re", f"RE-{row:04d}-{col:04d}")
            feature.SetField("acres", round(((size - 12) ** 2) / 4046.86, 2))
            feature.SetField("source", "synthetic-sample")
            layer.CreateFeature(feature)
            feature = None
            x += size
            col += 1
        y += size
        row += 1
    count = layer.GetFeatureCount()
    datasource = None
    log(f"wrote {count} synthetic parcels to {path.name}")


def write_installations(path: Path) -> None:
    datasource, layer = new_layer(path, "mirta_fl", ogr.wkbMultiPolygon)
    for name in ("sitename", "component", "state", "source_note"):
        add_string_field(layer, name, 160)
    # Small polygons spread across the window. Names say they are samples.
    sites = [
        (0.25, 0.30, "Sample Site North", "Sample component"),
        (0.62, 0.55, "Sample Site East", "Sample component"),
        (0.40, 0.72, "Sample Site River", "Sample component"),
        (0.78, 0.28, "Sample Site South", "Sample component"),
    ]
    size = 450.0
    for fx, fy, name, component in sites:
        x = MIN_X + (MAX_X - MIN_X) * fx
        y = MIN_Y + (MAX_Y - MIN_Y) * fy
        ring = ogr.Geometry(ogr.wkbLinearRing)
        ring.AddPoint(x, y)
        ring.AddPoint(x + size, y)
        ring.AddPoint(x + size, y + size)
        ring.AddPoint(x, y + size)
        ring.AddPoint(x, y)
        polygon = ogr.Geometry(ogr.wkbPolygon)
        polygon.AddGeometry(ring)
        multi = ogr.Geometry(ogr.wkbMultiPolygon)
        multi.AddGeometry(polygon)
        feature = ogr.Feature(layer.GetLayerDefn())
        feature.SetGeometry(multi)
        feature.SetField("sitename", name)
        feature.SetField("component", component)
        feature.SetField("state", "FL")
        feature.SetField(
            "source_note",
            "SYNTHETIC sample for the GeoKnight demo. Not an authoritative MIRTA extract.",
        )
        layer.CreateFeature(feature)
        feature = None
    count = layer.GetFeatureCount()
    datasource = None
    log(f"wrote {count} synthetic installation polygons to {path.name}")


def geotransform(width: int, height: int) -> tuple[float, float, float, float, float, float]:
    pixel_w = (MAX_X - MIN_X) / width
    pixel_h = (MAX_Y - MIN_Y) / height
    return (MIN_X, pixel_w, 0.0, MAX_Y, 0.0, -pixel_h)


def set_srs(dataset: gdal.Dataset) -> None:
    dataset.SetProjection(srs_26917().ExportToWkt())


def write_dem(path: Path) -> None:
    import numpy as np

    width, height = 400, 400
    temporary = path.with_suffix(".raw.tif")
    if temporary.exists():
        temporary.unlink()
    driver = gdal.GetDriverByName("GTiff")
    dataset = driver.Create(str(temporary), width, height, 1, gdal.GDT_Float32)
    dataset.SetGeoTransform(geotransform(width, height))
    set_srs(dataset)
    rows, cols = np.mgrid[0:height, 0:width]
    # Coastal ground in the real 3DEP window is about -3 m to 19 m.
    elevation = (
        -1.0
        + 12.0 * (cols / width)
        + 4.0 * np.sin(rows / 18.0)
        + 3.0 * np.cos(cols / 22.0)
    ).astype("float32")
    elevation = np.clip(elevation, -3.0, 19.0)
    elevation[:6, :] = -999999
    elevation[:, :6] = -999999
    band = dataset.GetRasterBand(1)
    band.WriteArray(elevation)
    band.SetNoDataValue(-999999)
    dataset.FlushCache()
    dataset = None
    to_cog(temporary, path)
    temporary.unlink(missing_ok=True)
    log(f"wrote synthetic DEM {path.name}")


def write_naip(path: Path) -> None:
    import numpy as np

    width, height = 400, 400
    temporary = path.with_suffix(".raw.tif")
    if temporary.exists():
        temporary.unlink()
    driver = gdal.GetDriverByName("GTiff")
    dataset = driver.Create(str(temporary), width, height, 3, gdal.GDT_Byte)
    dataset.SetGeoTransform(geotransform(width, height))
    set_srs(dataset)
    rows, cols = np.mgrid[0:height, 0:width]
    # A river-like band and a street grid so the picture reads as a city sample.
    river = np.abs(cols - (width * 0.35 + 18 * np.sin(rows / 28.0))) < 14
    streets = (cols % 36 < 2) | (rows % 36 < 2)
    red = np.full((height, width), 92, dtype="uint8")
    green = np.full((height, width), 118, dtype="uint8")
    blue = np.full((height, width), 74, dtype="uint8")
    red[river], green[river], blue[river] = 40, 78, 110
    red[streets], green[streets], blue[streets] = 168, 154, 120
    parks = (rows > height * 0.6) & (cols > width * 0.62) & ~streets
    red[parks], green[parks], blue[parks] = 62, 110, 64
    dataset.GetRasterBand(1).WriteArray(red)
    dataset.GetRasterBand(2).WriteArray(green)
    dataset.GetRasterBand(3).WriteArray(blue)
    dataset.GetRasterBand(1).SetColorInterpretation(gdal.GCI_RedBand)
    dataset.GetRasterBand(2).SetColorInterpretation(gdal.GCI_GreenBand)
    dataset.GetRasterBand(3).SetColorInterpretation(gdal.GCI_BlueBand)
    dataset.FlushCache()
    dataset = None
    to_cog(temporary, path)
    temporary.unlink(missing_ok=True)
    log(f"wrote synthetic imagery {path.name}")


def to_cog(source: Path, dest: Path) -> None:
    if dest.exists():
        dest.unlink()
    gdal.Translate(
        str(dest),
        str(source),
        format="COG",
        creationOptions=["COMPRESS=DEFLATE", "BIGTIFF=IF_SAFER"],
    )


def write_hillshade(dem: Path, dest: Path) -> None:
    temporary = dest.with_suffix(".raw.tif")
    if temporary.exists():
        temporary.unlink()
    subprocess.check_call(
        [
            "gdaldem",
            "hillshade",
            str(dem),
            str(temporary),
            "-z",
            "3",
            "-az",
            "315",
            "-alt",
            "40",
            "-of",
            "GTiff",
        ]
    )
    to_cog(temporary, dest)
    temporary.unlink(missing_ok=True)
    log(f"wrote hillshade {dest.name}")


def download(url: str, dest: Path, timeout: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    log(f"GET {url}")
    with urllib.request.urlopen(request, timeout=timeout) as response, dest.open("wb") as handle:
        shutil.copyfileobj(response, handle)


def download_tiger(dest: Path) -> None:
    zip_path = DATA / "vector" / "tl_2024_12031_roads.zip"
    download(TIGER_URL, zip_path, timeout=300)
    if dest.exists():
        dest.unlink()
    subprocess.check_call(
        [
            "ogr2ogr",
            "-f",
            "GPKG",
            str(dest),
            f"/vsizip/{zip_path}",
            "-t_srs",
            "EPSG:26917",
            "-nlt",
            "PROMOTE_TO_MULTI",
            "-nln",
            "roads",
        ]
    )
    log(f"wrote Census TIGER roads to {dest.name}")


def download_dem(dest: Path) -> None:
    query = urllib.parse.urlencode(
        {
            "bbox": f"{MIN_LON},{MIN_LAT},{MAX_LON},{MAX_LAT}",
            "bboxSR": "4326",
            "imageSR": "26917",
            "size": "400,400",
            "format": "tiff",
            "pixelType": "F32",
            "interpolation": "RSP_BilinearInterpolation",
            "f": "image",
        }
    )
    url = (
        "https://elevation.nationalmap.gov/arcgis/rest/services/"
        f"3DEPElevation/ImageServer/exportImage?{query}"
    )
    temporary = dest.with_suffix(".download.tif")
    download(url, temporary, timeout=180)
    info = gdal.Open(str(temporary))
    if info is None:
        raise RuntimeError("The National Map response was not a GeoTIFF.")
    info = None
    to_cog(temporary, dest)
    temporary.unlink(missing_ok=True)
    log(f"wrote 3DEP clip to {dest.name}")


def planetary_computer_naip(dest: Path) -> None:
    search = {
        "collections": ["naip"],
        "bbox": [MIN_LON, MIN_LAT, MAX_LON, MAX_LAT],
        "limit": 5,
        "datetime": "2021-01-01/..",
    }
    payload = json.dumps(search).encode()
    request = urllib.request.Request(
        "https://planetarycomputer.microsoft.com/api/stac/v1/search",
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        body = json.load(response)
    href = None
    for feature in body.get("features") or []:
        assets = feature.get("assets") or {}
        for key in ("image", "data", "visual"):
            asset = assets.get(key) or {}
            if asset.get("href"):
                href = asset["href"]
                break
        if href:
            break
    if not href:
        raise RuntimeError("Planetary Computer returned no NAIP image asset.")
    sign_url = (
        "https://planetarycomputer.microsoft.com/api/sas/v1/sign?href="
        + urllib.parse.quote(href, safe="")
    )
    sign_request = urllib.request.Request(sign_url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(sign_request, timeout=60) as response:
        signed = json.load(response)["href"]
    temporary = dest.with_suffix(".download.tif")
    if temporary.exists():
        temporary.unlink()
    subprocess.check_call(
        [
            "gdal_translate",
            "/vsicurl/" + signed,
            str(temporary),
            "-projwin",
            str(MIN_LON),
            str(MAX_LAT),
            str(MAX_LON),
            str(MIN_LAT),
            "-projwin_srs",
            "EPSG:4326",
            "-outsize",
            "512",
            "512",
        ]
    )
    warped = dest.with_suffix(".warp.tif")
    subprocess.check_call(
        [
            "gdalwarp",
            "-t_srs",
            "EPSG:26917",
            "-r",
            "bilinear",
            str(temporary),
            str(warped),
        ]
    )
    to_cog(warped, dest)
    temporary.unlink(missing_ok=True)
    warped.unlink(missing_ok=True)
    log(f"wrote NAIP clip to {dest.name}")


def write_tracts(path: Path) -> None:
    datasource, layer = new_layer(path, "tracts", ogr.wkbMultiPolygon)
    add_string_field(layer, "GEOID", 16)
    add_string_field(layer, "TRACTCE", 8)
    add_string_field(layer, "source", 40)
    cols, rows = 2, 2
    width = (MAX_X - MIN_X) / cols
    height = (MAX_Y - MIN_Y) / rows
    number = 1
    for row in range(rows):
        for col in range(cols):
            x0 = MIN_X + col * width
            y0 = MIN_Y + row * height
            ring = ogr.Geometry(ogr.wkbLinearRing)
            ring.AddPoint(x0, y0)
            ring.AddPoint(x0 + width, y0)
            ring.AddPoint(x0 + width, y0 + height)
            ring.AddPoint(x0, y0 + height)
            ring.AddPoint(x0, y0)
            polygon = ogr.Geometry(ogr.wkbPolygon)
            polygon.AddGeometry(ring)
            multi = ogr.Geometry(ogr.wkbMultiPolygon)
            multi.AddGeometry(polygon)
            feature = ogr.Feature(layer.GetLayerDefn())
            feature.SetGeometry(multi)
            feature.SetField("GEOID", f"1203100{number:04d}")
            feature.SetField("TRACTCE", f"{number:04d}00")
            feature.SetField("source", "synthetic-sample")
            layer.CreateFeature(feature)
            feature = None
            number += 1
    count = layer.GetFeatureCount()
    datasource = None
    log(f"wrote {count} synthetic tracts to {path.name}")


def write_aoi() -> None:
    wgs = {
        "type": "FeatureCollection",
        "name": "aoi",
        "crs": {"type": "name", "properties": {"name": "EPSG:4326"}},
        "features": [
            {
                "type": "Feature",
                "properties": {"name": "Jacksonville AOI"},
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [[
                        [MIN_LON, MIN_LAT],
                        [MAX_LON, MIN_LAT],
                        [MAX_LON, MAX_LAT],
                        [MIN_LON, MAX_LAT],
                        [MIN_LON, MIN_LAT],
                    ]],
                },
            }
        ],
    }
    projected = {
        "type": "FeatureCollection",
        "name": "aoi",
        "crs": {"type": "name", "properties": {"name": "EPSG:26917"}},
        "features": [
            {
                "type": "Feature",
                "properties": {"name": "Jacksonville AOI"},
                "geometry": {
                    "type": "Polygon",
                    "coordinates": [[
                        [MIN_X, MIN_Y],
                        [MAX_X, MIN_Y],
                        [MAX_X, MAX_Y],
                        [MIN_X, MAX_Y],
                        [MIN_X, MIN_Y],
                    ]],
                },
            }
        ],
    }
    (DATA / "aoi.geojson").write_text(json.dumps(wgs), encoding="utf-8")
    (DATA / "aoi_26917.geojson").write_text(json.dumps(projected), encoding="utf-8")
    log("wrote aoi.geojson and aoi_26917.geojson")


def dump_sql(gpkg: Path, table: str, geometry: str) -> None:
    dest = SQL / f"{table}.sql"
    if dest.exists():
        dest.unlink()
    subprocess.check_call(
        [
            "ogr2ogr",
            "-f",
            "PGDump",
            str(dest),
            str(gpkg),
            "-nln",
            table,
            "-lco",
            "SCHEMA=jax_demo",
            "-lco",
            "GEOMETRY_NAME=geom",
            "-lco",
            "FID=id",
            "-lco",
            "SPATIAL_INDEX=GIST",
            "-lco",
            "LAUNDER=YES",
            "-nlt",
            geometry,
            "-a_srs",
            "EPSG:26917",
        ]
    )
    if str(ROOT / "scripts") not in sys.path:
        sys.path.insert(0, str(ROOT / "scripts"))
    from rewrite_sql import ensure_if_not_exists

    text = dest.read_text(encoding="utf-8")
    dest.write_text(ensure_if_not_exists(text), encoding="utf-8")
    log(f"wrote SQL dump {dest.name} in schema jax_demo")


def copy_styles() -> None:
    for name in ("dem_colorramp.sld", "hillshade.sld"):
        dest = DATA_STYLES / name
        src = ROOT / "styles" / name
        if dest.exists() or not src.exists():
            continue
        shutil.copyfile(src, dest)
        log(f"copied {name} into the data folder")


def write_missing_vectors() -> None:
    roads = GPKG / "roads.gpkg"
    tracts = GPKG / "tracts.gpkg"
    parcels = GPKG / "parcels.gpkg"
    mirta = GPKG / "mirta_fl.gpkg"
    if not roads.exists() and not (SQL / "roads.sql").exists():
        write_roads(roads)
        dump_sql(roads, "roads", "PROMOTE_TO_MULTI")
    if not tracts.exists() and not (SQL / "tracts.sql").exists():
        write_tracts(tracts)
        dump_sql(tracts, "tracts", "PROMOTE_TO_MULTI")
    if not parcels.exists() and not (SQL / "parcels.sql").exists():
        write_parcels(parcels)
        dump_sql(parcels, "parcels", "PROMOTE_TO_MULTI")
    if not mirta.exists() and not (SQL / "mirta_fl.sql").exists():
        write_installations(mirta)
        dump_sql(mirta, "mirta_fl", "PROMOTE_TO_MULTI")
    for gpkg, table, geometry in (
        (roads, "roads", "PROMOTE_TO_MULTI"),
        (tracts, "tracts", "PROMOTE_TO_MULTI"),
        (parcels, "parcels", "PROMOTE_TO_MULTI"),
        (mirta, "mirta_fl", "PROMOTE_TO_MULTI"),
    ):
        if gpkg.exists() and not (SQL / f"{table}.sql").exists():
            dump_sql(gpkg, table, geometry)
    if not (DATA / "aoi.geojson").exists() or not (DATA / "aoi_26917.geojson").exists():
        write_aoi()


def write_missing_rasters() -> None:
    dem = ELEVATION / "dem_3dep_aoi_cog.tif"
    hill = ELEVATION / "hillshade_aoi_cog.tif"
    naip = IMAGERY / "naip_2025_jax_aoi_cog.tif"
    if not dem.exists():
        write_dem(dem)
    if not hill.exists() and dem.exists():
        write_hillshade(dem, hill)
    if not naip.exists():
        write_naip(naip)


def synthetic_all() -> None:
    ensure_dirs()
    write_missing_vectors()
    write_missing_rasters()
    copy_styles()
    write_extent(DATA / "extent.env")


def download_selected(names: set[str]) -> None:
    ensure_dirs()
    if "tiger" in names:
        download_tiger(GPKG / "roads.gpkg")
        dump_sql(GPKG / "roads.gpkg", "roads", "PROMOTE_TO_MULTI")
    if "dem" in names:
        download_dem(ELEVATION / "dem_3dep_aoi_cog.tif")
        write_hillshade(ELEVATION / "dem_3dep_aoi_cog.tif", ELEVATION / "hillshade_aoi_cog.tif")
    if "naip" in names:
        planetary_computer_naip(IMAGERY / "naip_2025_jax_aoi_cog.tif")
    write_missing_vectors()
    write_missing_rasters()
    copy_styles()
    write_extent(DATA / "extent.env")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch or synthesize GeoKnight demo data.")
    parser.add_argument(
        "--synthetic",
        action="store_true",
        help="Build a small offline sample for downtown Jacksonville.",
    )
    parser.add_argument(
        "--download",
        default="",
        help="Comma-separated sources: tiger, dem, naip, or all.",
    )
    args = parser.parse_args()
    if args.synthetic and args.download:
        parser.error("Choose either --synthetic or --download.")
    if not args.synthetic and not args.download:
        parser.error("Pass --synthetic or --download tiger,dem,naip")
    try:
        if args.synthetic:
            synthetic_all()
        else:
            requested = {part.strip().lower() for part in args.download.split(",") if part.strip()}
            if "all" in requested:
                requested = {"tiger", "dem", "naip"}
            unknown = requested - {"tiger", "dem", "naip"}
            if unknown:
                parser.error(f"Unknown download source: {', '.join(sorted(unknown))}")
            download_selected(requested)
    except (urllib.error.URLError, subprocess.CalledProcessError, RuntimeError, OSError) as exc:
        print(f"[data] FAILED: {exc}", file=sys.stderr)
        print("[data] Re-run with --synthetic to build the offline sample.", file=sys.stderr)
        return 1
    log("data directory is ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
