#!/usr/bin/env python3
"""generate_report.py — render the two-mode safety table published in RESULTS.md.

The measurement: every project is transpiled TWICE from the same source —
once WITHOUT safety uplifting ("before", the faithful emission) and once WITH
it ("after", the production default) — and BOTH Rust outputs are measured by
cargo-geiger v0.13.0 (crates.io). The table's Unsafe columns are geiger's
Expressions category (individual unsafe operations inside unsafe code).

Inputs:
  * per-project driver rows  <results-dir>/<project>.tsv  (run_crust_project.sh;
    one tab-separated key=value line carrying g_* (after/safe) and gf_*
    (before/faithful) geiger keys + state cells). The per-mode measurements of
    record are the sibling raw files <results-dir>/<project>/geiger-safe.json
    and geiger-faithful.json — mode-named, never a shared path.
  * SQLite flagship          --sqlite-status <tsv> (state cells) +
    --sqlite-geiger-faithful <json> / --sqlite-geiger-safe <json>
    (raw cargo-geiger JSON, one file per mode).

Pipeline (pure functions, in order): load_results -> derive_metrics ->
render_table -> splice. Tested by test_generate_report.py (stdlib unittest).

Usage:
    generate_report.py <results-dir> [<cbench-dir>]
        [--sqlite-status <tsv>]
        [--sqlite-geiger-faithful <json>] [--sqlite-geiger-safe <json>]
        [--update <RESULTS.md>]

Without --update the rendered table is printed to stdout; with it, the table
is spliced between the crust-table markers in the target file (idempotent).
"""
import json
import os
import re
import sys

TABLE_BEGIN = "<!-- crust-table:begin -->"
TABLE_END = "<!-- crust-table:end -->"

TABLE_OPEN = '<div class="wide-table">'
TABLE_CLOSE = "</div>"

HEADER_ROW = ("| # | Project | Transpiled | Built | Tests "
              "| Unsafe (before) | Unsafe (after) | Change |")
SEPARATOR_ROW = "|---|---|---|---|---|---:|---:|---:|"

NA_BUILD = "n/a (build)"
PENDING = "pending"

LEGEND = (
    "<sub>Measured by **cargo-geiger v0.13.0** (crates.io). Each project is "
    "transpiled twice from the same source — once **without** safety uplifting "
    "(*before*) and once **with** it (*after*) — and both Rust outputs are "
    "measured by cargo-geiger. "
    "**Transpiled** — the transpiler emitted output (C++ lane · Rust lane). "
    "**Built** — the emitted code compiles (`ok/total` translation units or "
    "crates). "
    "**Tests** — the differential oracles: **A/B** compares the native-C "
    "binary's output byte-for-byte with the transpiled C++/Rust binary "
    "(`—` = not linkable as one binary); **pass@1** is CRUST-bench's official "
    "oracle (the emitted crate spliced under the hand-written RBench "
    "interface, then `cargo test`). For SQLite, Tests is the whole-CLI "
    "differential over the SQL scripts. "
    "**Unsafe (before) / Unsafe (after)** — cargo-geiger's Expressions count "
    "in each emission. "
    "**Change** — `(before − after) ÷ before`, signed: positive = the uplift "
    "removed unsafe expressions, negative = worse. "
    "cargo-geiger's five categories (all stored per mode in the raw per-mode "
    "JSON files; the table shows Expressions): "
    "**Functions** — unsafe function definitions vs safe; "
    "**Expressions** — individual unsafe operations (e.g. raw-pointer "
    "dereferences) inside unsafe code; "
    "**Impls** — unsafe trait implementations; "
    "**Traits** — unsafe trait declarations; "
    "**Methods** — unsafe methods in impls. "
    "Crate safety tiers, as cargo-geiger reports them: "
    "🔒 no unsafe usage found and the crate declares `#![forbid(unsafe_code)]`; "
    "❓ no unsafe usage found, forbid not declared; "
    "☢️ unsafe usage found. "
    "Emitted crates do not declare `forbid(unsafe_code)`, so a fully-safe "
    "result reads ❓ under geiger's own rules. "
    f"`{NA_BUILD}` — that mode did not compile, so geiger cannot measure it; "
    f"`{PENDING}` — not yet measured. Projects without a clean both-mode "
    "measurement are excluded from the aggregate (count disclosed)."
    "</sub>"
)


# ---------------------------------------------------------------------------
# load
# ---------------------------------------------------------------------------
def parse_kv(path):
    """One tab-separated line of key=value fields -> dict."""
    row = {}
    with open(path, encoding="utf-8") as f:
        for part in f.read().strip().split("\t"):
            if "=" in part:
                key, value = part.split("=", 1)
                row[key] = value
    return row


def load_results(results_dir):
    """All per-project driver rows, sorted by project name."""
    rows = []
    for name in sorted(os.listdir(results_dir), key=str.lower):
        if not name.endswith(".tsv") or name == "summary.tsv":
            continue
        rows.append((name[: -len(".tsv")],
                     parse_kv(os.path.join(results_dir, name))))
    return rows


def geiger_unsafe_expressions(json_path):
    """Unsafe-expression count from a raw cargo-geiger JSON file (one mode).

    Accepts a single geiger output object or a list of them (multi-crate
    projects store one raw geiger result per emitted crate). Returns None
    when the file is absent/unreadable — the "not measured" record.
    """
    try:
        with open(json_path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    results = data if isinstance(data, list) else [data]
    total = 0
    for result in results:
        try:
            total += result["packages"][0]["unsafety"]["used"]["exprs"]["unsafe_"]
        except (KeyError, IndexError, TypeError):
            return None
    return total


# ---------------------------------------------------------------------------
# derive
# ---------------------------------------------------------------------------
def gi(row, key):
    try:
        return int(row.get(key, "0"))
    except (ValueError, TypeError):
        return 0


def derive_metrics(row):
    """Before/after unsafe-expression metrics for one driver row.

    before = the faithful (no-uplift) emission's geiger count (gf_* keys);
    after  = the uplifted emission's (g_* keys). A mode counts as measured
    only when its ok flag is 1 (geiger scored a compiling crate).
    """
    measured_before = row.get("gf_ok") == "1"
    measured_after = row.get("g_ok") == "1"
    return {
        "before": gi(row, "gf_exprs_unsafe") if measured_before else None,
        "after": gi(row, "g_exprs_unsafe") if measured_after else None,
        "attempted": "gf_ok" in row or "g_ok" in row,
    }


def change_cell(before, after):
    """Signed percent (before − after) ÷ before; negative means worse."""
    if before is None or after is None:
        return "—"
    if before == 0:
        return "—"
    value = 100.0 * (before - after) / before
    sign = "+" if value > 0 else ("−" if value < 0 else "")
    return f"{sign}{abs(value):.1f}%"


def fmt_n(n):
    """Thousands-separated count (17,005 — not 17005)."""
    return f"{int(n):,}"


def unsafe_cell(count, attempted):
    if count is not None:
        return fmt_n(count)
    return NA_BUILD if attempted else "—"


# ---------------------------------------------------------------------------
# render — shared cells
# ---------------------------------------------------------------------------
def _lane_icon(state):
    return {"yes": "✅", "partial": "⚠️", "no": "❌"}.get(state, "?")


def _ab_icon(state):
    return {"pass": "✅", "fail": "❌", "na": "—"}.get(state, "—")


def state_cells(row):
    """(transpiled, built, tests) cells from a driver row."""
    note = row.get("note", "")
    if "no-compile-commands" in note or "no-project-dir" in note:
        return ("n/a — project build broken", "—", "—")
    transpiled = (f"C++ {_lane_icon(row.get('transpiled_cpp'))} · "
                  f"Rust {_lane_icon(row.get('transpiled_rust'))}")
    built = (f"C++ {row.get('compiled_cpp', '?')} · "
             f"Rust {row.get('compiled_rust', '?')}")
    tests = (f"A/B C++ {_ab_icon(row.get('ab_cpp'))}·"
             f"Rust {_ab_icon(row.get('ab_rust'))} "
             f"· pass@1 {_ab_icon(row.get('pass1'))}")
    return (transpiled, built, tests)


def upstream_url(cbench_dir, project):
    if not cbench_dir:
        return None
    cfg = os.path.join(cbench_dir, project, ".git", "config")
    try:
        with open(cfg, encoding="utf-8") as f:
            m = re.search(r"^\s*url = (\S+)$", f.read(), re.M)
            return m.group(1) if m else None
    except OSError:
        return None


def project_cell(project, url, has_mirror):
    """Project label linking upstream and — when a safe-Rust mirror was
    published (the safe emission measured clean) — the mirror repo."""
    base = f"[{project}]({url})" if url else project
    if not has_mirror:
        return base
    mirror = f"https://github.com/o2alexanderfedin/{project}-rust-mirror"
    return f"{base} · [mirror]({mirror})"


# ---------------------------------------------------------------------------
# render — SQLite flagship row
# ---------------------------------------------------------------------------
def sqlite_state_cells(status_row):
    """(transpiled, built, tests) from sqlite-status.tsv (files/crates/scripts)."""
    def split(key):
        m = re.fullmatch(r"(\d+)/(\d+)", status_row.get(key, ""))
        return (int(m.group(1)), int(m.group(2))) if m else None

    files = split("files")
    transpiled = ("—" if not files else
                  (f"✅ all {fmt_n(files[1])} files" if files[0] == files[1]
                   else f"⚠️ {fmt_n(files[0])}/{fmt_n(files[1])} files"))
    crates = split("crates")
    if not crates:
        built = "—"
    elif crates == (1, 1):
        built = "✅ one whole-program monocrate"
    elif crates[0] == crates[1]:
        built = f"✅ all {fmt_n(crates[1])} crates"
    else:
        built = f"⚠️ {fmt_n(crates[0])}/{fmt_n(crates[1])} crates"
    scripts = split("scripts")
    if scripts:
        mark = "✅ all" if scripts[0] == scripts[1] else "⚠️"
        count = (f"{scripts[0]}" if scripts[0] == scripts[1]
                 else f"{scripts[0]}/{scripts[1]}")
        runs = f" ({status_row['runs']} runs)" if status_row.get("runs") else ""
        tests = f"{mark} {count} SQL scripts byte-identical vs native CLI{runs}"
    else:
        tests = "—"
    return transpiled, built, tests


def sqlite_row(status_path, faithful_json, safe_json):
    """The flagship row's cells (project, transpiled, built, tests, before,
    after, change). Geiger cells read the two mode-named raw JSON files;
    a missing file renders `pending` (not yet measured)."""
    status_row = parse_kv(status_path)
    name = status_row.get("name", "SQLite")
    cell = f"[{name}]({status_row['url']})" if status_row.get("url") else name
    if status_row.get("output_url"):
        cell += f" → [Rust output]({status_row['output_url']})"
    cell += " — **flagship**"
    transpiled, built, tests = sqlite_state_cells(status_row)
    before = geiger_unsafe_expressions(faithful_json) if faithful_json else None
    after = geiger_unsafe_expressions(safe_json) if safe_json else None
    before_cell = fmt_n(before) if before is not None else PENDING
    after_cell = fmt_n(after) if after is not None else PENDING
    return (cell, transpiled, built, tests,
            before_cell, after_cell, change_cell(before, after))


# ---------------------------------------------------------------------------
# render — the one table
# ---------------------------------------------------------------------------
def aggregate_line(rows):
    """One-line aggregate over the both-mode-measured projects, with the
    excluded count disclosed."""
    measured = [(m["before"], m["after"]) for _, _, m in rows
                if m["before"] is not None and m["after"] is not None]
    excluded = sum(1 for _, _, m in rows
                   if m["attempted"]
                   and (m["before"] is None or m["after"] is None))
    if not measured:
        return (f"**Aggregate:** no project measured in both modes yet; "
                f"{excluded} excluded ({NA_BUILD}).")
    before = sum(b for b, _ in measured)
    after = sum(a for _, a in measured)
    return (f"**Aggregate over the {len(measured)} both-mode-measured "
            f"project(s):** before {fmt_n(before)} → after {fmt_n(after)} "
            f"unsafe expressions (Change {change_cell(before, after)}); "
            f"{excluded} project(s) excluded ({NA_BUILD}).")


def render_table(results_dir, cbench_dir=None, sqlite_status=None,
                 sqlite_geiger_faithful=None, sqlite_geiger_safe=None):
    loaded = load_results(results_dir) if results_dir else []
    rows = [(project, row, derive_metrics(row)) for project, row in loaded]

    lines = [TABLE_OPEN, "", HEADER_ROW, SEPARATOR_ROW]
    n = 0
    if sqlite_status and os.path.isfile(sqlite_status):
        n += 1
        cells = sqlite_row(sqlite_status, sqlite_geiger_faithful,
                           sqlite_geiger_safe)
        lines.append(f"| {n} | " + " | ".join(cells) + " |")
    for project, row, metrics in rows:
        n += 1
        transpiled, built, tests = state_cells(row)
        before = unsafe_cell(metrics["before"], metrics["attempted"])
        after = unsafe_cell(metrics["after"], metrics["attempted"])
        change = change_cell(metrics["before"], metrics["after"])
        cell = project_cell(project, upstream_url(cbench_dir, project),
                            has_mirror=(metrics["after"] is not None))
        lines.append(f"| {n} | {cell} | {transpiled} | {built} | {tests} "
                     f"| {before} | {after} | {change} |")
    lines += ["", TABLE_CLOSE, "", LEGEND, "", aggregate_line(rows)]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# splice
# ---------------------------------------------------------------------------
def splice(doc, table):
    """Replace the marker-delimited table region in `doc`; None when the
    markers are missing. Idempotent: splicing the same table twice yields
    the identical document."""
    if TABLE_BEGIN not in doc or TABLE_END not in doc:
        return None
    head, rest = doc.split(TABLE_BEGIN, 1)
    _, tail = rest.split(TABLE_END, 1)
    return head + TABLE_BEGIN + "\n" + table + "\n" + TABLE_END + tail


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def take_flag(args, flag):
    if flag not in args:
        return None
    i = args.index(flag)
    value = args[i + 1]
    del args[i:i + 2]
    return value


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    update_target = take_flag(args, "--update")
    sqlite_status = take_flag(args, "--sqlite-status")
    sqlite_geiger_faithful = take_flag(args, "--sqlite-geiger-faithful")
    sqlite_geiger_safe = take_flag(args, "--sqlite-geiger-safe")

    results_dir = args[0] if args and os.path.isdir(args[0]) else None
    cbench_dir = (args[1] if len(args) > 1 and os.path.isdir(args[1])
                  else None)
    if not results_dir and not sqlite_status:
        print(__doc__, file=sys.stderr)
        return 2

    table = render_table(results_dir, cbench_dir, sqlite_status,
                         sqlite_geiger_faithful, sqlite_geiger_safe)

    if update_target:
        with open(update_target, encoding="utf-8") as f:
            doc = f.read()
        spliced = splice(doc, table)
        if spliced is None:
            print(f"markers {TABLE_BEGIN} missing in {update_target}",
                  file=sys.stderr)
            return 2
        with open(update_target, "w", encoding="utf-8") as f:
            f.write(spliced)
        print(f"updated {update_target}")
    else:
        print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
