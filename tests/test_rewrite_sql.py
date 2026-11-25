#!/usr/bin/env python3
"""Loader rewrite checks. No database required."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from rewrite_sql import ensure_if_not_exists, rewrite  # noqa: E402


FIXTURE = ROOT / "tests" / "fixtures" / "jax_demo_sample.sql"


class RewriteSqlTest(unittest.TestCase):
    def test_fixture_moves_to_public_and_keeps_lowercase_columns(self) -> None:
        sql = rewrite(FIXTURE.read_text(encoding="utf-8"))
        self.assertNotIn("jax_demo.", sql.lower())
        self.assertNotIn("schema jax_demo", sql.lower())
        self.assertNotIn('"jax_demo"', sql.lower())
        self.assertIn("CREATE TABLE IF NOT EXISTS public.fixture_parcels", sql)
        self.assertIn("CREATE TABLE IF NOT EXISTS public.fixture_mirta", sql)
        self.assertIn("re text", sql)
        self.assertIn("sitename text", sql)
        self.assertNotIn("IF NOT EXISTS IF NOT EXISTS", sql)
        self.assertIn("DROP TABLE IF EXISTS public.fixture_parcels CASCADE;", sql)
        self.assertIn("DROP TABLE IF EXISTS public.fixture_mirta CASCADE;", sql)
        self.assertIn("DROP TABLE IF EXISTS public.fixture_roads CASCADE;", sql)
        self.assertIn("'keep jax_demo in this note'", sql)
        self.assertIn("1\tO'Brien St\n", sql)
        self.assertIn("2\tkeep jax_demo in this name\n", sql)
        self.assertIn('COPY "public"."fixture_roads" ("id", "fullname") FROM stdin;', sql)
        self.assertIn(
            'CREATE INDEX IF NOT EXISTS fixture_roads_fullname_idx\n'
            '    ON "public"."fixture_roads" (fullname);',
            sql,
        )
        self.assertIn(
            'SELECT setval(pg_get_serial_sequence(\'"public"."fixture_roads"\', \'id\'), MAX("id")) '
            'FROM "public"."fixture_roads";',
            sql,
        )
        self.assertIn(
            'ALTER TABLE "public"."fixture_roads" ADD CONSTRAINT fixture_roads_fullname_present',
            sql,
        )
        self.assertIn('COMMENT ON TABLE "public"."fixture_roads" IS \'road names\';', sql)

    def test_existing_if_not_exists_is_not_doubled(self) -> None:
        raw = "CREATE TABLE IF NOT EXISTS jax_demo.roads (id integer);\n"
        once = rewrite(raw)
        twice = rewrite(once)
        self.assertEqual(once.lower().count("if not exists"), 1)
        self.assertEqual(twice.lower().count("if not exists"), 1)
        self.assertNotIn("IF NOT EXISTS IF NOT EXISTS", twice)

    def test_repairs_a_doubled_if_not_exists(self) -> None:
        raw = "CREATE SCHEMA IF NOT EXISTS IF NOT EXISTS jax_demo;\n"
        sql = ensure_if_not_exists(raw)
        self.assertEqual(sql.lower().count("if not exists"), 1)

    def test_adds_if_not_exists_when_the_dump_omits_it(self) -> None:
        raw = (
            'CREATE SCHEMA "jax_demo";\n'
            'CREATE TABLE "jax_demo"."roads" (id integer, fullname varchar);\n'
            'CREATE INDEX "roads_gix" ON "jax_demo"."roads" USING GIST ("geom");\n'
        )
        sql = rewrite(raw)
        self.assertIn('CREATE SCHEMA IF NOT EXISTS "public";', sql)
        self.assertIn('CREATE TABLE IF NOT EXISTS "public"."roads"', sql)
        self.assertIn('CREATE INDEX IF NOT EXISTS "roads_gix" ON "public"."roads"', sql)
        self.assertNotIn("jax_demo", sql.lower())

    def test_ogr2ogr_geometry_helper_uses_public(self) -> None:
        raw = (
            "SELECT AddGeometryColumn('jax_demo','roads','geom',26917,'MULTILINESTRING',2);\n"
            "DELETE FROM geometry_columns WHERE f_table_schema = 'jax_demo';\n"
            "CREATE TABLE IF NOT EXISTS jax_demo.roads (id integer);\n"
        )
        sql = rewrite(raw)
        self.assertIn("AddGeometryColumn('public','roads','geom',26917,'MULTILINESTRING',2);", sql)
        self.assertIn("f_table_schema = 'public'", sql)
        self.assertNotIn("jax_demo", sql.lower())

    def test_search_path_and_set_config_follow_the_schema(self) -> None:
        raw = (
            "SET search_path = jax_demo, pg_catalog;\n"
            "SELECT pg_catalog.set_config('search_path', 'jax_demo, public', false);\n"
            "CREATE TABLE IF NOT EXISTS roads (id integer);\n"
        )
        sql = rewrite(raw)
        self.assertIn("SET search_path = public, pg_catalog;", sql)
        self.assertIn("set_config('search_path', 'public, public', false);", sql)
        self.assertNotIn("jax_demo", sql.lower())

    def test_copy_from_stdin_is_verbatim_and_following_sql_is_rewritten(self) -> None:
        raw = (
            'CREATE TABLE "jax_demo"."roads" (id integer, fullname varchar);\n'
            'COPY "jax_demo"."roads" ("id", "fullname") FROM STDIN;\n'
            "1\tO'Brien St\n"
            "2\tkeep jax_demo in this name\n"
            '3\tCREATE INDEX "roads_gix" ON "jax_demo"."roads"\n'
            "4\tSELECT setval('jax_demo.roads_id_seq', 1, true);\n"
            "\\.\n"
            "SELECT setval(pg_get_serial_sequence('\"jax_demo\".\"roads\"', 'id'), MAX(\"id\")) "
            'FROM "jax_demo"."roads";\n'
            "SELECT pg_catalog.setval('jax_demo.roads_id_seq', 3, true);\n"
            'CREATE INDEX "roads_geom_geom_idx" ON "jax_demo"."roads" USING GIST ("geom");\n'
            'ALTER TABLE "jax_demo"."roads" ADD CONSTRAINT roads_pkey PRIMARY KEY (id);\n'
            "COMMENT ON TABLE \"jax_demo\".\"roads\" IS 'county roads';\n"
            "SELECT AddGeometryColumn('jax_demo','roads','geom',26917,'MULTILINESTRING',2);\n"
        )
        sql = rewrite(raw)
        self.assertIn("1\tO'Brien St\n", sql)
        self.assertIn("2\tkeep jax_demo in this name\n", sql)
        self.assertIn('3\tCREATE INDEX "roads_gix" ON "jax_demo"."roads"\n', sql)
        self.assertIn("4\tSELECT setval('jax_demo.roads_id_seq', 1, true);\n", sql)
        self.assertIn("\\.\n", sql)
        self.assertIn('COPY "public"."roads" ("id", "fullname") FROM STDIN;', sql)
        self.assertIn(
            "SELECT setval(pg_get_serial_sequence('\"public\".\"roads\"', 'id'), MAX(\"id\")) "
            'FROM "public"."roads";',
            sql,
        )
        self.assertIn("SELECT pg_catalog.setval('public.roads_id_seq', 3, true);", sql)
        self.assertIn(
            'CREATE INDEX IF NOT EXISTS "roads_geom_geom_idx" ON "public"."roads" USING GIST ("geom");',
            sql,
        )
        self.assertIn('ALTER TABLE "public"."roads" ADD CONSTRAINT roads_pkey PRIMARY KEY (id);', sql)
        self.assertIn("COMMENT ON TABLE \"public\".\"roads\" IS 'county roads';", sql)
        self.assertIn("AddGeometryColumn('public','roads','geom',26917,'MULTILINESTRING',2);", sql)
        outside = sql
        for literal in (
            "2\tkeep jax_demo in this name\n",
            '3\tCREATE INDEX "roads_gix" ON "jax_demo"."roads"\n',
            "4\tSELECT setval('jax_demo.roads_id_seq', 1, true);\n",
        ):
            outside = outside.replace(literal, "")
        self.assertNotIn("jax_demo", outside.lower())
        again = rewrite(sql)
        self.assertEqual(again.count("-- geoknight-load: prepare"), 1)
        self.assertIn("1\tO'Brien St\n", again)
        self.assertIn('3\tCREATE INDEX "roads_gix" ON "jax_demo"."roads"\n', again)
        self.assertIn(
            'CREATE INDEX IF NOT EXISTS "roads_geom_geom_idx" ON "public"."roads" USING GIST ("geom");',
            again,
        )

    def test_multiline_copy_with_options_and_an_embedded_backslash_dot(self) -> None:
        raw = (
            'COPY "jax_demo"."roads" (\n'
            '    "id",\n'
            '    "fullname"\n'
            ") FROM STDIN WITH (FORMAT text, ENCODING UTF8);\n"
            "1\tO'Brien \\. St\n"
            "\\.\n"
            'CREATE INDEX "roads_gix" ON "jax_demo"."roads" USING GIST ("geom");\n'
        )
        sql = rewrite(raw)
        self.assertIn('COPY "public"."roads" (', sql)
        self.assertIn("1\tO'Brien \\. St\n", sql)
        self.assertIn(
            'CREATE INDEX IF NOT EXISTS "roads_gix" ON "public"."roads" USING GIST ("geom");',
            sql,
        )
        self.assertNotIn("jax_demo", sql.lower())

    def test_copy_data_is_not_treated_as_sql(self) -> None:
        raw = (
            "COPY jax_demo.roads (fullname) FROM stdin;\n"
            "CREATE TABLE jax_demo.not_a_table (id integer);\n"
            "\\.\n"
            "CREATE TABLE jax_demo.roads (id integer);\n"
        )
        sql = rewrite(raw)
        self.assertIn("CREATE TABLE jax_demo.not_a_table (id integer);\n", sql)
        self.assertNotIn("not_a_table", sql.replace("CREATE TABLE jax_demo.not_a_table (id integer);", "").lower())
        self.assertIn("DROP TABLE IF EXISTS public.roads CASCADE;", sql)
        self.assertIn("CREATE TABLE IF NOT EXISTS public.roads (id integer);", sql)
        self.assertEqual(sql.lower().count("if not exists"), 1)

    def test_copy_from_a_file_comment_or_function_is_still_sql(self) -> None:
        raw = (
            "-- COPY jax_demo.roads FROM stdin;\n"
            "CREATE TABLE IF NOT EXISTS jax_demo.roads (id integer, note text);\n"
            "INSERT INTO jax_demo.roads VALUES (1, 'COPY t FROM stdin; O''Brien');\n"
            "CREATE FUNCTION jax_demo.noop() RETURNS void AS $$\n"
            "COPY jax_demo.roads FROM stdin;\n"
            "$$ LANGUAGE sql;\n"
            "COPY jax_demo.roads FROM 'roads.sql';\n"
            "CREATE INDEX roads_idx ON jax_demo.roads (id);\n"
        )
        sql = rewrite(raw)
        self.assertIn("CREATE INDEX IF NOT EXISTS roads_idx ON public.roads (id);", sql)
        self.assertIn("'COPY t FROM stdin; O''Brien'", sql)
        self.assertIn("COPY jax_demo.roads FROM stdin;\n", sql)
        self.assertIn("CREATE FUNCTION public.noop()", sql)
        self.assertIn("COPY public.roads FROM 'roads.sql';", sql)
        self.assertIn("-- COPY public.roads FROM stdin;", sql)

    def test_two_copy_blocks_share_one_prepare_block(self) -> None:
        raw = (
            "CREATE TABLE jax_demo.a (id integer, name text);\n"
            "COPY jax_demo.a (id, name) FROM stdin;\n"
            "1\tO'Brien\n"
            "\\.\n"
            "CREATE TABLE jax_demo.b (id integer, name text);\n"
            "COPY jax_demo.b (id, name) FROM stdin;\n"
            "2\tjax_demo\n"
            "\\.\n"
            "CREATE INDEX a_idx ON jax_demo.a (id);\n"
            "CREATE INDEX b_idx ON jax_demo.b (id);\n"
        )
        sql = rewrite(raw)
        self.assertIn("1\tO'Brien\n", sql)
        self.assertIn("2\tjax_demo\n", sql)
        self.assertIn("CREATE INDEX IF NOT EXISTS a_idx ON public.a (id);", sql)
        self.assertIn("CREATE INDEX IF NOT EXISTS b_idx ON public.b (id);", sql)
        self.assertEqual(sql.count("-- geoknight-load: prepare"), 1)
        self.assertEqual(sql.count("DROP TABLE IF EXISTS public.a CASCADE;"), 1)
        self.assertEqual(sql.count("DROP TABLE IF EXISTS public.b CASCADE;"), 1)

    def test_second_rewrite_does_not_stack_drop_blocks(self) -> None:
        sql = rewrite(FIXTURE.read_text(encoding="utf-8"))
        again = rewrite(sql)
        self.assertEqual(again.count("-- geoknight-load: prepare"), 1)
        self.assertEqual(sql.count("DROP TABLE IF EXISTS public.fixture_parcels"), 1)
        self.assertEqual(again.count("DROP TABLE IF EXISTS public.fixture_parcels"), 1)


if __name__ == "__main__":
    unittest.main()
