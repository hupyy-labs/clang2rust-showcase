#!/usr/bin/env python3
"""test_generate_report.py — unit tests for generate_report.py (stdlib
unittest, zero dependencies). Run:  python3 benchmarks/test_generate_report.py

Covers the pipeline end-to-end on synthetic fixtures: a both-modes-valid row,
a build-failed row (renders n/a (build), excluded from the aggregate), a
zero-unsafe row, a worse-after row (signed negative Change), the SQLite pair
(two mode-named raw geiger JSON files), the pinned header row, the
geiger-native legend content, and splice idempotence.
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate_report as gr  # noqa: E402


def write_row(results_dir, stem, **kv):
    line = "\t".join(f"{k}={v}" for k, v in kv.items())
    with open(os.path.join(results_dir, f"{stem}.tsv"), "w",
              encoding="utf-8") as f:
        f.write(line + "\n")


def geiger_json(exprs_unsafe):
    """A minimal raw cargo-geiger v0.13.0 JSON result."""
    return {"packages": [{
        "package": {"id": {"name": "x", "version": "0.1.0"}},
        "unsafety": {
            "used": {
                "functions": {"safe": 1, "unsafe_": 0},
                "exprs": {"safe": 10, "unsafe_": exprs_unsafe},
                "item_impls": {"safe": 0, "unsafe_": 0},
                "item_traits": {"safe": 0, "unsafe_": 0},
                "methods": {"safe": 0, "unsafe_": 0},
            },
            "unused": {},
            "forbids_unsafe": False,
        },
    }]}


STATE = dict(transpiled_cpp="yes", transpiled_rust="yes",
             compiled_cpp="1/1", compiled_rust="1/1",
             ab_cpp="pass", ab_rust="na", pass1="na", note="")


class RenderTableTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.results = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def render(self, **kwargs):
        return gr.render_table(self.results, **kwargs)

    def find_row(self, table, project):
        for line in table.splitlines():
            if line.startswith("|") and project in line \
                    and not line.startswith("| #"):
                return line
        raise AssertionError(f"no table row for {project}:\n{table}")

    # --- pinned header schema -------------------------------------------------
    def test_header_row_is_the_pinned_schema(self):
        write_row(self.results, "alpha", project="alpha", **STATE,
                  g_ok=1, g_exprs_unsafe=40, gf_ok=1, gf_exprs_unsafe=100)
        table = self.render()
        self.assertIn(
            "| # | Project | Transpiled | Built | Tests "
            "| Unsafe (before) | Unsafe (after) | Change |", table)
        self.assertIn("|---|---|---|---|---|---:|---:|---:|", table)

    # --- both-modes-valid row ---------------------------------------------------
    def test_valid_row_renders_counts_and_signed_positive_change(self):
        write_row(self.results, "alpha", project="alpha", **STATE,
                  g_ok=1, g_exprs_unsafe=40, gf_ok=1, gf_exprs_unsafe=100)
        row = self.find_row(self.render(), "alpha")
        self.assertIn("| 100 |", row)      # Unsafe (before)
        self.assertIn("| 40 |", row)       # Unsafe (after)
        self.assertIn("| +60.0% |", row)   # Change, signed
        self.assertIn("C++ ✅ · Rust ✅", row)
        self.assertIn("C++ 1/1 · Rust 1/1", row)

    def test_worse_after_row_renders_signed_negative_change(self):
        write_row(self.results, "worse", project="worse", **STATE,
                  g_ok=1, g_exprs_unsafe=60, gf_ok=1, gf_exprs_unsafe=50)
        row = self.find_row(self.render(), "worse")
        self.assertIn("| −20.0% |", row)

    def test_thousands_separators(self):
        write_row(self.results, "big", project="big", **STATE,
                  g_ok=1, g_exprs_unsafe=436115, gf_ok=1,
                  gf_exprs_unsafe=438340)
        row = self.find_row(self.render(), "big")
        self.assertIn("| 438,340 |", row)
        self.assertIn("| 436,115 |", row)

    # --- build-failed row --------------------------------------------------------
    def test_build_failed_mode_renders_na_build_and_is_excluded(self):
        write_row(self.results, "alpha", project="alpha", **STATE,
                  g_ok=1, g_exprs_unsafe=40, gf_ok=1, gf_exprs_unsafe=100)
        write_row(self.results, "broken", project="broken", **STATE,
                  g_ok=1, g_exprs_unsafe=7, gf_ok=0, gf_exprs_unsafe=0)
        table = self.render()
        row = self.find_row(table, "broken")
        self.assertIn(f"| {gr.NA_BUILD} |", row)   # before unmeasurable
        self.assertIn("| — |", row)                # no Change without both
        # Aggregate counts ONLY alpha; broken is excluded and disclosed.
        self.assertIn("Aggregate over the 1 both-mode-measured project(s):",
                      table)
        self.assertIn("before 100 → after 40", table)
        self.assertIn(f"1 project(s) excluded ({gr.NA_BUILD})", table)

    # --- zero-unsafe row -----------------------------------------------------------
    def test_zero_unsafe_after_renders_plus_100_percent(self):
        write_row(self.results, "clean", project="clean", **STATE,
                  g_ok=1, g_exprs_unsafe=0, gf_ok=1, gf_exprs_unsafe=50)
        row = self.find_row(self.render(), "clean")
        self.assertIn("| 0 |", row)
        self.assertIn("| +100.0% |", row)

    def test_zero_unsafe_both_modes_renders_dash_change(self):
        write_row(self.results, "empty", project="empty", **STATE,
                  g_ok=1, g_exprs_unsafe=0, gf_ok=1, gf_exprs_unsafe=0)
        row = self.find_row(self.render(), "empty")
        self.assertIn("| — |", row)  # 0/0 has no defined percentage

    # --- SQLite pair (per-mode raw geiger JSON files) ---------------------------
    def test_sqlite_flagship_row_from_mode_named_json_pair(self):
        # The SQLite inputs live OUTSIDE the results dir (mode-named files;
        # never picked up as project rows).
        sqldir = os.path.join(self.results, "sqlite")
        os.makedirs(sqldir)
        status = os.path.join(sqldir, "sqlite-status.tsv")
        with open(status, "w", encoding="utf-8") as f:
            f.write("name=SQLite\turl=https://www.sqlite.org/\t"
                    "files=84/84\tcrates=1/1\tscripts=10/10\truns=3\n")
        faithful = os.path.join(sqldir, "sqlite-geiger-faithful.json")
        safe = os.path.join(sqldir, "sqlite-geiger-safe.json")
        with open(faithful, "w", encoding="utf-8") as f:
            json.dump(geiger_json(438340), f)
        with open(safe, "w", encoding="utf-8") as f:
            json.dump(geiger_json(436115), f)
        table = self.render(sqlite_status=status,
                            sqlite_geiger_faithful=faithful,
                            sqlite_geiger_safe=safe)
        row = self.find_row(table, "SQLite")
        self.assertTrue(row.startswith("| 1 |"))   # flagship = row 1
        self.assertIn("flagship", row)
        self.assertIn("| 438,340 |", row)
        self.assertIn("| 436,115 |", row)
        self.assertIn("| +0.5% |", row)
        self.assertIn("✅ all 84 files", row)
        self.assertIn("one whole-program monocrate", row)

    def test_sqlite_missing_geiger_files_render_pending(self):
        sqldir = os.path.join(self.results, "sqlite")
        os.makedirs(sqldir)
        status = os.path.join(sqldir, "sqlite-status.tsv")
        with open(status, "w", encoding="utf-8") as f:
            f.write("name=SQLite\tfiles=84/84\tcrates=1/1\tscripts=10/10\n")
        table = self.render(sqlite_status=status)
        row = self.find_row(table, "SQLite")
        self.assertIn(f"| {gr.PENDING} |", row)

    # --- multi-crate raw JSON (list) ----------------------------------------------
    def test_geiger_unsafe_expressions_sums_a_list_of_results(self):
        path = os.path.join(self.results, "multi.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump([geiger_json(3), geiger_json(4)], f)
        self.assertEqual(gr.geiger_unsafe_expressions(path), 7)

    def test_geiger_unsafe_expressions_missing_file_is_none(self):
        self.assertIsNone(gr.geiger_unsafe_expressions(
            os.path.join(self.results, "absent.json")))

    # --- legend content (drift guard) ----------------------------------------------
    def test_legend_defines_the_five_geiger_categories(self):
        self.assertIn("**Functions** — unsafe function definitions vs safe",
                      gr.LEGEND)
        self.assertIn("**Expressions** — individual unsafe operations",
                      gr.LEGEND)
        self.assertIn("**Impls** — unsafe trait implementations", gr.LEGEND)
        self.assertIn("**Traits** — unsafe trait declarations", gr.LEGEND)
        self.assertIn("**Methods** — unsafe methods in impls", gr.LEGEND)

    def test_legend_states_the_three_crate_safety_tiers(self):
        self.assertIn("🔒 no unsafe usage found and the crate declares "
                      "`#![forbid(unsafe_code)]`", gr.LEGEND)
        self.assertIn("❓ no unsafe usage found, forbid not declared",
                      gr.LEGEND)
        self.assertIn("☢️ unsafe usage found", gr.LEGEND)
        self.assertIn("cargo-geiger v0.13.0", gr.LEGEND)

    def test_rendered_table_carries_the_legend(self):
        write_row(self.results, "alpha", project="alpha", **STATE,
                  g_ok=1, g_exprs_unsafe=1, gf_ok=1, gf_exprs_unsafe=2)
        self.assertIn(gr.LEGEND, self.render())


class SpliceTest(unittest.TestCase):
    DOC = ("# Results\n\nintro prose\n\n"
           f"{gr.TABLE_BEGIN}\nOLD TABLE\n{gr.TABLE_END}\n\ntrailing prose\n")

    def test_splice_replaces_only_the_marked_region(self):
        out = gr.splice(self.DOC, "NEW TABLE")
        self.assertIn("intro prose", out)
        self.assertIn("trailing prose", out)
        self.assertIn("NEW TABLE", out)
        self.assertNotIn("OLD TABLE", out)

    def test_splice_is_idempotent(self):
        once = gr.splice(self.DOC, "NEW TABLE")
        twice = gr.splice(once, "NEW TABLE")
        self.assertEqual(once, twice)

    def test_splice_without_markers_is_none(self):
        self.assertIsNone(gr.splice("no markers here", "T"))


class ChangeCellTest(unittest.TestCase):
    def test_signed_arithmetic(self):
        self.assertEqual(gr.change_cell(100, 40), "+60.0%")
        self.assertEqual(gr.change_cell(50, 60), "−20.0%")
        self.assertEqual(gr.change_cell(50, 50), "0.0%")
        self.assertEqual(gr.change_cell(0, 0), "—")
        self.assertEqual(gr.change_cell(None, 5), "—")
        self.assertEqual(gr.change_cell(5, None), "—")


if __name__ == "__main__":
    unittest.main(verbosity=2)
