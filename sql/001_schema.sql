-- Structure only. Feature rows are loaded from GeoPackages or created by editors.
-- Safe to run more than once.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS public_data;
CREATE SCHEMA IF NOT EXISTS restricted;

CREATE TABLE IF NOT EXISTS restricted.editor_notes (
    id serial PRIMARY KEY,
    note text,
    created_by text,
    created_at timestamptz DEFAULT now(),
    geom geometry(Point, 26917)
);

CREATE INDEX IF NOT EXISTS editor_notes_geom_gix
    ON restricted.editor_notes
    USING gist (geom);
