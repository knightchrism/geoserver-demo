#!/bin/sh
# Load the tiny jax_demo fixture through the same rewriter make load-data uses.
# Requires the PostGIS container from `make up`.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/../scripts/lib/common.sh"
need_env

fixture="$ROOT/tests/fixtures/jax_demo_sample.sql"
if [ ! -f "$fixture" ]; then
    die "Missing $fixture"
fi

if ! dc exec -T postgis pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    die "PostGIS is not ready. Run: make up"
fi

echo "[geoknight] applying the schema extension the fixture geometry needs"
dc exec -T postgis psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    < "$ROOT/sql/001_schema.sql" >/dev/null

load_fixture() {
    rewritten="$(mktemp)"
    python3 "$ROOT/scripts/rewrite_sql.py" "$fixture" > "$rewritten"
    dc exec -T postgis psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$rewritten"
    rm -f "$rewritten"
}

echo "[geoknight] loading the jax_demo fixture"
load_fixture
echo "[geoknight] loading the jax_demo fixture again"
load_fixture

dc exec -T postgis psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
SELECT
    CASE
        WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'jax_demo')
        THEN 'jax_demo schema was created'
        ELSE 'ok-schema'
    END;
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'fixture_parcels'
ORDER BY column_name;
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'fixture_mirta'
ORDER BY column_name;
SELECT count(*) AS parcel_rows FROM public.fixture_parcels;
SELECT count(*) AS mirta_rows FROM public.fixture_mirta;
SELECT sitename FROM public.fixture_mirta ORDER BY id;
SELECT id, fullname FROM public.fixture_roads ORDER BY id;
SELECT indexname FROM pg_indexes
WHERE schemaname = 'public' AND tablename = 'fixture_roads'
ORDER BY indexname;
SQL

schema_note="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT count(*) FROM pg_namespace WHERE nspname = 'jax_demo'")"
schema_note="$(printf '%s' "$schema_note" | tr -d '[:space:]')"
if [ "$schema_note" != "0" ]; then
    die "Expected the loader to fold jax_demo into public."
fi

parcel_cols="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'fixture_parcels'")"
parcel_cols="$(printf '%s' "$parcel_cols" | tr -d '[:space:]')"
case "$parcel_cols" in
    *re*) ;;
    *) die "fixture_parcels is missing the lowercase re column (got ${parcel_cols})." ;;
esac

mirta_cols="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'fixture_mirta'")"
mirta_cols="$(printf '%s' "$mirta_cols" | tr -d '[:space:]')"
case "$mirta_cols" in
    *sitename*) ;;
    *) die "fixture_mirta is missing the lowercase sitename column (got ${mirta_cols})." ;;
esac

counts="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT (SELECT count(*) FROM public.fixture_parcels) || ',' || (SELECT count(*) FROM public.fixture_mirta) || ',' || (SELECT count(*) FROM public.fixture_roads)")"
counts="$(printf '%s' "$counts" | tr -d '[:space:]')"
if [ "$counts" != "1,2,2" ]; then
    die "Second load was not idempotent (counts ${counts}, expected 1,2,2)."
fi

obrien="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT count(*) FROM public.fixture_roads WHERE fullname = 'O''Brien St'")"
obrien="$(printf '%s' "$obrien" | tr -d '[:space:]')"
if [ "$obrien" != "1" ]; then
    die "COPY data lost the apostrophe in O'Brien St (count ${obrien})."
fi

kept="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT count(*) FROM public.fixture_roads WHERE fullname = 'keep jax_demo in this name'")"
kept="$(printf '%s' "$kept" | tr -d '[:space:]')"
if [ "$kept" != "1" ]; then
    die "COPY data rewrote the jax_demo value (count ${kept})."
fi

index_count="$(dc exec -T postgis psql -q -tA -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'fixture_roads' AND indexname = 'fixture_roads_fullname_idx'")"
index_count="$(printf '%s' "$index_count" | tr -d '[:space:]')"
if [ "$index_count" != "1" ]; then
    die "CREATE INDEX after the COPY block was not created on public.fixture_roads (count ${index_count})."
fi

echo "[geoknight] fixture load passed (public schema, lowercase columns, O'Brien St, preserved jax_demo text, index after COPY, second load kept 1 parcel, 2 sites, and 2 roads)"
