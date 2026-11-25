# Data directory

This folder is empty in git. The county extract, imagery, and elevation are large and stay on the machine that prepares them.

`make load-data` reads this exact layout. A SQL dump is used when it is present. The GeoPackage is the fallback. If the folder is still empty, the command builds a small sample in these same paths so the server can be tried without the full extract.

```
data/
  aoi.geojson                         WGS84 outline of the area of interest
  aoi_26917.geojson                   same outline in EPSG:26917
  vector/gpkg/parcels.gpkg            parcel key column: re (owner names are not included)
  vector/gpkg/roads.gpkg
  vector/gpkg/mirta_fl.gpkg           polygons, site name column: sitename
  vector/gpkg/tracts.gpkg
  vector/sql/parcels.sql              pg_dump style, schema jax_demo, EPSG:26917, GiST index
  vector/sql/roads.sql
  vector/sql/mirta_fl.sql             polygons
  vector/sql/tracts.sql
  imagery/naip_2025_jax_aoi_cog.tif   2025 NAIP, 0.3 m RGB, JPEG COG
  elevation/dem_3dep_aoi_cog.tif      3DEP, 1 m float32, nodata -999999, about -3 m to 19 m
  elevation/hillshade_aoi_cog.tif     8-bit hillshade
  styles/dem_colorramp.sld            color ramp for that elevation range
  styles/hillshade.sld
```

The area of interest is EPSG:26917 X 429240–438990, Y 3341670–3358380 (about longitude -81.736 to -81.634, latitude 30.204 to 30.356). That window covers downtown Jacksonville and NAS Jacksonville.

The full NAIP file is about 791 MB. The sample built on a machine without that file is a small image with the same name and the same extent, so the server configuration does not change.
