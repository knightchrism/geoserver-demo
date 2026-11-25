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
        self.assertIn("'keep jax_demo in this note'", sql)

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

    def test_second_rewrite_does_not_stack_drop_blocks(self) -> None:
        sql = rewrite(FIXTURE.read_text(encoding="utf-8"))
        again = rewrite(sql)
        self.assertEqual(again.count("-- geoknight-load: prepare"), 1)
        self.assertEqual(sql.count("DROP TABLE IF EXISTS public.fixture_parcels"), 1)
        self.assertEqual(again.count("DROP TABLE IF EXISTS public.fixture_parcels"), 1)


if __name__ == "__main__":
    unittest.main()
