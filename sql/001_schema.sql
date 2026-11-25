-- Structure only. Feature rows are loaded from SQL or GeoPackages, or created by editors.
-- Safe to run more than once.
-- GeoServer does not connect as the table owner. scripts/grant-app-role.sh creates
-- a separate role that can read these tables and write only editor_notes.

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
