-- Tiny stand-in for the county package: pg_dump style, jax_demo schema,
-- CREATE TABLE IF NOT EXISTS already present, lowercase column names.
-- A second IF NOT EXISTS must not be added. The note keeps the word jax_demo
-- on purpose so the loader can show it does not rewrite string values.

CREATE SCHEMA IF NOT EXISTS jax_demo;

CREATE TABLE IF NOT EXISTS jax_demo.fixture_parcels (
    id integer,
    re text,
    geom geometry(MultiPolygon, 26917)
);

CREATE TABLE IF NOT EXISTS jax_demo.fixture_mirta (
    id integer,
    sitename text,
    geom geometry(MultiPolygon, 26917)
);

CREATE INDEX IF NOT EXISTS fixture_parcels_geom_gix
    ON jax_demo.fixture_parcels USING gist (geom);

CREATE INDEX IF NOT EXISTS fixture_mirta_geom_gix
    ON jax_demo.fixture_mirta USING gist (geom);

INSERT INTO jax_demo.fixture_parcels (id, re, geom) VALUES
    (1, 're-1', ST_GeomFromText('MULTIPOLYGON(((429240 3341670, 429340 3341670, 429340 3341770, 429240 3341770, 429240 3341670)))', 26917));

INSERT INTO jax_demo.fixture_mirta (id, sitename, geom) VALUES
    (1, 'sample site', ST_GeomFromText('MULTIPOLYGON(((430000 3350000, 430200 3350000, 430200 3350200, 430000 3350200, 430000 3350000)))', 26917)),
    (2, 'keep jax_demo in this note', ST_GeomFromText('MULTIPOLYGON(((431000 3351000, 431200 3351000, 431200 3351200, 431000 3351200, 431000 3351000)))', 26917));

ALTER TABLE jax_demo.fixture_parcels ADD CONSTRAINT fixture_parcels_pkey PRIMARY KEY (id);
ALTER TABLE jax_demo.fixture_mirta ADD CONSTRAINT fixture_mirta_pkey PRIMARY KEY (id);
