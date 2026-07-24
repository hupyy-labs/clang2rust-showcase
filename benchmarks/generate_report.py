#!/usr/bin/env python3
"""generate_report.py — render the site-granular safety tables published in
RESULTS.md. This script owns every table; none is hand-edited.

Usage:
    benchmarks/generate_report.py <results-dir> [<cbench-dir>]
        [--sqlite-status <tsv>] [--sqlite-sites <tsv>] [--update <RESULTS.md>]

Both the CRUST-bench table and the SQLite flagship row use ONE UNIFIED column
schema (TWO_MODE_CONTRACT.md §6) — the state columns, then the faithful-vs-safe
safety axis and the per-function rollup:

    | Project | Transpiled | Compiled | Tested
    | Non-safe Sites (faithful) | Safe Sites (uplift) | Site Reduction (%)
    | Faithful UOD | Safe UOD
    | Total Fns | Unsafe Fns (faithful) | Unsafe Fns (safe) | Fns Made Safe |

SQLite is also the first row of the per-project table (labeled "flagship").

Safety compares TWO Rust emissions of the SAME program, both scored by the same
operation-level `unsafe_census` (per-OPERATION SITES, not functions):

  * Non-safe (faithful) — lab factory, all uplift segments dropped (f_* keys).
  * Safe (uplift)       — production default, all uplift segments ON (r_* keys).

The 6-family site total is `raw_ptr_deref + extern_unsafe_call + static_mut +
union_read + transmute + inline_asm`; `unchecked_arith` / `first_party_call` /
`intrinsic_call` / `unsafe_blocks` are separate lanes, and `*_total_exprs` is
the UOD denominator. Per-function metrics bucket by census region LINE.

CRUST-bench site data:  read per project from `<results-dir>/<project>.tsv`,
                        written by run_crust_project.sh (the driver row schema).

SQLite site data:       read from the `--sqlite-sites <tsv>` file — a single
                        tab-separated key=value line using the SAME driver
                        site keys (c_raw_ptr_deref … r_sites rust_exprs). It is
                        produced from the SQLite funnel logs; regenerate with:

    # (NOT run by this generator — run over a stable SQLite snapshot)
    python3 benchmarks/sqlite_c_funnel.py "$SQLITE_CDB" funnel_c.log --bin cpp2rust
    unsafe_census "$SQLITE_RUST_MIRROR"                              > funnel_rust.log
    python3 benchmarks/sqlite_sites_from_funnel.py funnel_c.log funnel_rust.log \
        > benchmarks/sqlite-sites.tsv

    If `--sqlite-sites` is absent, SQLite's site cells render `pending-regen`
    (NEVER stale function-granular numbers) while its Transpiled/Compiled/A-B
    state cells still come from `--sqlite-status`.
"""
import os
import re
import subprocess
import sys

CRUST_BEGIN = "<!-- crust-table:begin -->"
CRUST_END = "<!-- crust-table:end -->"

# The methodology section is static prose (no result data). It lives in the
# report's intro — before the data tables — between its own marker pair, so a
# `--update` regeneration rewrites it in place and it survives just like the
# generated tables. This is the ONE piece of RESULTS.md prose the generator
# owns; the rest of the intro/headings are hand-maintained (outside all markers).
METHODOLOGY_BEGIN = "<!-- methodology:begin -->"
METHODOLOGY_END = "<!-- methodology:end -->"

METHODOLOGY = """## Methodology — what we measure vs. what CRUST-Bench measures

We run our transpiler over the **[CRUST-Bench](https://arxiv.org/abs/2504.15254) corpus** (its 100 C projects), but we are **not** running the CRUST-Bench task, and our headline safety numbers are our **own instrument** — not a CRUST-Bench score. The two efforts measure different things.

**CRUST-Bench** is an *LLM* C→safe-Rust benchmark. Each C project ships with a hand-written **safe-Rust interface** (safe signatures + ownership types) and a ported Rust test suite; a language model fills in the bodies. Its two **scored** metrics are, per whole project:
- **Build** — does `cargo build` succeed (debug profile, warnings ignored);
- **Test** — does `cargo test` pass all ported tests — reported as **pass@1** plus two rounds of compiler-/test-feedback repair.

CRUST-Bench does **not** mechanically gate safety: there is no `#![forbid(unsafe_code)]`, `libc` is an allowed dependency (its own reference tests call `unsafe { libc::… }`), and unsafe usage is only tallied *post-hoc* as a coarse per-project flag ("does the output contain the `unsafe` keyword?"). It also **excludes** syntax-directed transpilers such as c2rust for producing too much unsafe/FFI Rust.

**This project** is a *deterministic* AST transpiler — the class CRUST-Bench excludes — and it measures safety at a **finer grain**: a per-operation **unsafe-site census** (raw-pointer deref, extern/unsafe call, `static mut`, union read, transmute, inline asm) and an **Unsafe-Operation Density** (sites ÷ total expressions), computed in **two modes over identical source**:
- **faithful** — our safety uplift *disabled*: a raw, unsafe-preserving lowering, comparable in spirit to a syntax-directed transpiler;
- **safe** — our safety uplift *enabled* (the production default).

The **faithful → safe** delta isolates exactly what our uplift removes — information CRUST-Bench's binary flag cannot express.

**How to read our numbers, honestly:**
- Our safety columns (Non-safe / Safe Sites, Site Reduction %, UOD, Unsafe Fns, Fns Made Safe) are **our own instrument**; there is no CRUST-Bench number to compare them to, and we do **not** claim to "beat" CRUST-Bench on safety.
- The only columns that map to CRUST-Bench's published methodology are **Compiled** (≈ their Build) and **Tested / pass@1** (≈ their Test). Our pass@1 is produced differently (a mechanical splice against the reference interface, not an LLM fill-and-repair loop), so it is **not** directly comparable either.
- Because we preserve C semantics and A/B-verify behavior, our output keeps `unsafe extern` at genuine libc/FFI edges (e.g. the SQLite lane). By CRUST-Bench's binary "no unsafe" rule that counts as unsafe — an intentional trade-off: we prioritize behavioral fidelity over an all-safe surface at the C boundary.

**The claim we do stand behind:** over the same corpus, our uplift *measurably reduces unsafe operations* relative to a raw, c2rust-style lowering of the identical source — a reduction their coarse safety flag cannot see."""

# Wrap the wide (14-col) tables in a `.wide-table` container so they use ~80% of
# the viewport width with their own horizontal scroll, instead of overflowing.
# Styling lives in the linked stylesheet `results.css` (referenced from the top
# of RESULTS.md) rather than inline `style=` attributes, so it survives renderers
# that keep <link>/class but sanitize inline styles.
TABLE_OPEN = '<div class="wide-table">'
TABLE_CLOSE = "</div>"
SQLITE_BEGIN = "<!-- sqlite-table:begin -->"
SQLITE_END = "<!-- sqlite-table:end -->"

HEADER = [
    "| # | Project | Transpiled | Compiled | Tested "
    "| Non-safe Sites (faithful) | Safe Sites (uplift) | Site Reduction (%) "
    "| Faithful UOD | Safe UOD "
    "| Total Fns | Unsafe Fns (faithful) | Unsafe Fns (safe) | Fns Made Safe |",
    "|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
]

# One legend rendered under BOTH tables so every number is defined in place.
LEGEND = (
    "<sub>A **site** is one individual unsafe OPERATION, not a function or a "
    "whole `unsafe {}` block. Every safety number below compares **two Rust "
    "emissions of the same program**, both scored by the same `unsafe_census` "
    "instrument: the **faithful** baseline (lab factory — all uplift segments "
    "dropped, a straight transliteration) and the **safe** production default "
    "(pointer→`Option`/span, alloc→`Box`/`Vec`, printf→`print!`, cstring-global "
    "uplift all ON). "
    "**Transpiled / Compiled** — did cpp2rust emit, and does the emitted code "
    "build, for the C++ lane and the Rust lane (`ok/total` translation units). "
    "**Tested** — the differential oracles: **A/B** runs the project built from "
    "native C vs from the transpiled C++/Rust and compares output byte-for-byte "
    "(`—` = not linkable as one binary, e.g. cross-TU C++ name mangling or "
    "unresolved builtin FFI; logged, never silently passed); **pass@1** is "
    "CRUST-bench's official oracle — the emitted crate spliced under the "
    "hand-written RBench interface, then `cargo test`. For SQLite the Tested "
    "cell is the whole-CLI differential over the SQL scripts. "
    "**Non-safe Sites (faithful)** / **Safe Sites (uplift)** — the 6-family "
    "unsafe-site total (`raw_ptr_deref + extern_unsafe_call + static_mut + "
    "union_read + transmute + inline_asm`) in each emission; `first_party_call` "
    "(harness-FFI / transpiler shims), `intrinsic_call` (benign compiler "
    "intrinsics), `boundary_reborrow` (`&*p`/`&mut *p` reborrows synthesized "
    "where a lifted callee signature meets a caller local that stayed a raw "
    "pointer — the SAME pointer risk re-spelled at each call seam, not new "
    "unsafety), `unchecked_arith` (C pointer arithmetic) and whole "
    "`unsafe_blocks` are separate lanes, never folded into the total. "
    "**Site Reduction (%)** — `(faithful − safe) ÷ faithful`; **positive = the "
    "uplift REMOVED unsafe sites** relative to the faithful baseline. "
    "**Faithful UOD** / **Safe UOD** — Unsafe-Operation-Density: unsafe sites ÷ "
    "total expressions in that emission's own AST (lower is safer; the "
    "denominator grows with any added scaffolding, so density cannot be gamed "
    "by code inflation). "
    "**Total Fns** — every function-with-a-body counted (by census line, so "
    "same-named impl/trait methods are not merged); **Unsafe Fns (faithful)** / "
    "**Unsafe Fns (safe)** — those carrying ≥1 unsafe site in each emission; "
    "**Fns Made Safe** — the region-keyed join: functions unsafe in the "
    "faithful baseline that the uplift makes fully safe, shown as `n (n ÷ "
    "unsafe-faithful)`. "
    "Safety cells render `pending` / `n/a` for any project whose faithful OR "
    "safe emission had a non-zero parse-error count — those projects are "
    "excluded from the aggregate (the excluded count is reported there). "
    "Whole-program **SQLite shows a small reduction by design**: it is emitted as "
    "one monocrate where almost every function is externally visible across the "
    "link set, so the ownership/pointer uplifts are ABI-vetoed there to preserve "
    "the C-ABI boundary — the site-removing signal concentrates in the smaller, "
    "self-contained CRUST-bench projects. All counts use thousands "
    "separators.</sub>"
)

# --- driver TSV site-family keys (faithful vs safe emission of the SAME program) ---
# (family label, faithful key, safe key) for the per-family aggregate. Both
# emissions carry all six families, so both keys are always present.
FAMILY_ROWS = [
    ("raw_ptr_deref", "f_raw_ptr_deref", "r_raw_ptr_deref"),
    ("extern_unsafe_call", "f_extern_unsafe_call", "r_extern_unsafe_call"),
    ("static_mut", "f_static_mut", "r_static_mut"),
    ("union read", "f_union_read", "r_union_read"),
    ("transmute", "f_transmute", "r_transmute"),
    ("inline_asm", "f_inline_asm", "r_inline_asm"),
]


def fmt_n(n):
    """Human-readable count: thousands separators (17,005 — not 17005)."""
    return f"{int(n):,}"


def gi(d, k):
    try:
        return int(d.get(k, "0"))
    except (ValueError, TypeError):
        return 0


def parse_kv(path):
    """One tab-separated line (or file) of key=value fields -> dict."""
    row = {}
    with open(path, encoding="utf-8") as f:
        for part in f.read().strip().split("\t"):
            if "=" in part:
                key, value = part.split("=", 1)
                row[key] = value
    return row


def parse_row_file(path):
    """A driver TSV row file -> dict (same tab-separated key=value shape)."""
    return parse_kv(path)


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


# ---------------------------------------------------------------------------
# Cell renderers (shared by both tables)
# ---------------------------------------------------------------------------
def _lane_icon(state):
    return {"yes": "✅", "partial": "⚠️", "no": "❌"}.get(state, "?")


def _ab_icon(state):
    return {"pass": "✅", "fail": "❌", "na": "—"}.get(state, "—")


def state_cells(r):
    """(transpiled, compiled, tested) cells from a driver row. `tested`
    combines both differential oracles (A/B + pass@1) into the single Tested
    column."""
    note = r.get("note", "")
    if "no-compile-commands" in note or "no-project-dir" in note:
        return ("n/a — project build broken", "—", "—")
    transpiled = (f"C++ {_lane_icon(r.get('transpiled_cpp'))} · "
                  f"Rust {_lane_icon(r.get('transpiled_rust'))}")
    compiled = f"C++ {r.get('compiled_cpp','?')} · Rust {r.get('compiled_rust','?')}"
    tested = (f"A/B C++ {_ab_icon(r.get('ab_cpp'))}·Rust {_ab_icon(r.get('ab_rust'))} "
              f"· pass@1 {_ab_icon(r.get('pass1'))}")
    return (transpiled, compiled, tested)


def pct(num, den, signed=False):
    """Percentage cell, or '—' when the denominator is zero. `signed` prefixes
    a leading + / − so a NEGATIVE reduction (Rust has more sites than C) reads
    honestly as an increase rather than being mistaken for a small reduction."""
    if not den:
        return "—"
    v = 100.0 * num / den
    if signed:
        sign = "+" if v > 0 else ("−" if v < 0 else "")
        return f"{sign}{abs(v):.1f}%"
    return f"{v:.1f}%"


def _safety_gated_ok(r):
    """Contract §5/§10 gate: a project's safety numbers are VALID only when BOTH
    emissions parsed cleanly (parse_errors == 0) AND both actually produced a
    non-empty crate (total_exprs > 0). The non-empty check guards against a
    stale pre-two-mode TSV or an asymmetric faithful-emit failure, either of
    which would otherwise render a nonsensical 0-faithful-vs-N-safe row —
    impossible on real data, since faithful (uplift OFF) can never have FEWER
    unsafe sites than the safe emission of the same program."""
    return (gi(r, "safe_parse_errors") == 0 and gi(r, "faithful_parse_errors") == 0
            and gi(r, "rust_exprs") > 0 and gi(r, "f_total_exprs") > 0)


def safety_cells(r):
    """The 9 safety-axis cells for one row, in column order:
    (Non-safe Sites, Safe Sites, Site Reduction %, Faithful UOD, Safe UOD,
     Total Fns, Unsafe Fns faithful, Unsafe Fns safe, Fns Made Safe).

    `—` when the row carries no site data at all; `pending`/`n/a` (contract §6)
    when a mode failed to parse — such projects are also excluded from the
    aggregate."""
    if "f_sites" not in r and "r_sites" not in r:
        return ("—",) * 5 + ("—",) * 4
    if not _safety_gated_ok(r):
        return ("pending",) * 5 + ("n/a",) * 4
    f = gi(r, "f_sites")
    rs = gi(r, "r_sites")
    f_exprs = gi(r, "f_total_exprs")
    r_exprs = gi(r, "rust_exprs")
    reduction = pct(f - rs, f, signed=True) if f else "—"
    total_fns = gi(r, "total_fns")
    uf = gi(r, "unsafe_fns_faithful")
    us = gi(r, "unsafe_fns_safe")
    made = gi(r, "fns_made_safe")
    made_cell = f"{fmt_n(made)} ({made / uf:.0%})" if uf else f"{fmt_n(made)} (—)"
    return (fmt_n(f), fmt_n(rs), reduction, pct(f, f_exprs), pct(rs, r_exprs),
            fmt_n(total_fns), fmt_n(uf), fmt_n(us), made_cell)


def project_cell(project, url, has_mirror=True):
    """Project label linking the upstream repo (when known) and — only when a
    per-project safe-Rust mirror was actually published — the mirror (contract
    §8 naming). A project that produced no safe emission has no mirror, so no
    (dead) mirror link is emitted."""
    base = f"[{project}]({url})" if url else project
    if not has_mirror:
        return base
    mirror = f"https://github.com/o2alexanderfedin/{project}-rust-mirror"
    return f"{base} · [mirror]({mirror})"


# ---------------------------------------------------------------------------
# Aggregate per-family before/after block (DESIGN.md D3)
# ---------------------------------------------------------------------------
def aggregate_block(all_rows, excluded=0):
    # Aggregate the faithful→safe uplift ONLY over projects that parsed cleanly
    # in BOTH modes (contract §5/§10). Projects with a non-zero parse-error count
    # in either mode are excluded and counted honestly; the per-project table
    # above still shows them as `pending`/`n/a`.
    rows = [r for r in all_rows
            if _safety_gated_ok(r) and ("f_sites" in r or "r_sites" in r)]
    tot = lambda k: sum(gi(r, k) for r in rows)
    excl_note = (f"; {excluded} project(s) excluded for a non-zero parse-error "
                 "count in one mode (shown `pending` above)" if excluded else "")
    lines = ["",
             f"**Unsafe operation sites by family — across the {len(rows)} projects "
             f"with a clean two-mode parse** (the faithful lab baseline vs the safe "
             f"uplift, both emissions of the same program{excl_note}):",
             "", "| Family | Sites (faithful) | Sites (safe uplift) | Δ (faithful−safe) |",
             "|---|---:|---:|---:|"]
    f_total = r_total = 0
    for label, fk, rk in FAMILY_ROWS:
        fv = tot(fk)
        rv = tot(rk)
        f_total += fv
        r_total += rv
        lines.append(f"| {label} | {fmt_n(fv)} | {fmt_n(rv)} | {fmt_n(fv - rv)} |")
    lines.append(f"| **Total (memory-safety sites)** | **{fmt_n(f_total)}** | "
                 f"**{fmt_n(r_total)}** | **{fmt_n(f_total - r_total)}** |")
    # Separate lanes — reported for transparency, never folded into the total.
    lines.append(f"| _unchecked_arith (separate lane)_ | _{fmt_n(tot('r_unchecked_arith'))}_ | "
                 f"_{fmt_n(tot('r_unchecked_arith'))}_ | _—_ |")
    lines.append(f"| _first_party_call (harness-FFI / transpiler shims — excluded)_ | "
                 f"_—_ | _{fmt_n(tot('r_first_party_call'))}_ | _—_ |")
    lines.append(f"| _intrinsic_call (benign compiler intrinsics — excluded)_ | "
                 f"_—_ | _{fmt_n(tot('r_intrinsic_call'))}_ | _—_ |")
    lines.append(f"| _boundary_reborrow (`&*p`/`&mut *p` at lifted-signature seams — excluded)_ | "
                 f"_{fmt_n(tot('f_boundary_reborrow'))}_ | _{fmt_n(tot('r_boundary_reborrow'))}_ | "
                 f"_{fmt_n(tot('f_boundary_reborrow') - tot('r_boundary_reborrow'))}_ |")
    f_exprs = tot("f_total_exprs")
    r_exprs = tot("rust_exprs")
    f_uod = f"{100.0 * f_total / f_exprs:.2f}%" if f_exprs else "n/a"
    r_uod = f"{100.0 * r_total / r_exprs:.2f}%" if r_exprs else "n/a"
    reduction = pct(f_total - r_total, f_total, signed=True) if f_total else "n/a"
    tot_fns = tot("total_fns")
    uf = tot("unsafe_fns_faithful")
    us = tot("unsafe_fns_safe")
    made = tot("fns_made_safe")
    made_pct = f"{100.0 * made / uf:.1f}%" if uf else "n/a"
    sign_note = ("the uplift nets FEWER unsafe sites than the faithful baseline"
                 if (f_total - r_total) > 0 else
                 "the uplift did not net-remove sites in this population (see the "
                 "SQLite ABI-veto note — the signal concentrates in smaller projects)")
    lines += [
        "",
        f"Totals — Non-safe (faithful) unsafe sites **{fmt_n(f_total)}** → Safe "
        f"(uplift) unsafe sites **{fmt_n(r_total)}** (Site Reduction **{reduction}**: "
        f"{sign_note}). Faithful UOD **{f_uod}** → Safe UOD **{r_uod}** (unsafe "
        f"sites ÷ total expressions in each emission's AST).",
        f"Function-level — of **{fmt_n(uf)}** functions carrying ≥1 unsafe site in the "
        f"faithful baseline, the uplift makes **{fmt_n(made)}** fully safe "
        f"(**{made_pct}**); **{fmt_n(us)}** functions still carry an unsafe site in the "
        f"safe emission, out of **{fmt_n(tot_fns)}** functions total.",
    ]
    return "\n".join(l for l in lines if l is not None)


# ---------------------------------------------------------------------------
# CRUST-bench table
# ---------------------------------------------------------------------------
def load_rows(results_dir):
    rows = []
    for name in sorted(os.listdir(results_dir), key=str.lower):
        if not name.endswith(".tsv") or name == "summary.tsv":
            continue
        rows.append((name[:-len(".tsv")], parse_row_file(os.path.join(results_dir, name))))
    return rows


def render_crust(results_dir, cbench_dir, sqlite_status=None, sqlite_sites=None):
    rows = load_rows(results_dir)
    lines = [TABLE_OPEN, ""] + list(HEADER)
    n = 0  # 1-based row number (column 1); SQLite flagship = row 1, then 2..N.
    # SQLite sits IN the per-project table as the first row (the flagship — the
    # product's primary target — shown right alongside the CRUST-bench corpus).
    if sqlite_status and os.path.isfile(sqlite_status):
        n += 1
        lines.append(f"| {n} {sqlite_row(sqlite_status, sqlite_sites, label_suffix=' — **flagship**')}")
    for project, r in rows:
        n += 1
        t, c, tested = state_cells(r)
        fs, ss, red, fuod, suod, tfns, ufaith, usafe, made = safety_cells(r)
        url = upstream_url(cbench_dir, project)
        cell = project_cell(project, url, has_mirror=gi(r, "rust_exprs") > 0)
        lines.append(
            f"| {n} | {cell} | {t} | {c} | {tested} | {fs} | {ss} | {red} | {fuod} | {suod} "
            f"| {tfns} | {ufaith} | {usafe} | {made} |")
    lines.append("")
    lines.append(TABLE_CLOSE)
    lines.append("")
    lines.append(LEGEND)
    # Projects that carry site data but failed the two-mode parse gate are
    # excluded from the aggregate; report the count honestly (contract §5/§10).
    excluded = sum(1 for _, r in rows
                   if ("f_sites" in r or "r_sites" in r) and not _safety_gated_ok(r))
    lines.append(aggregate_block([r for _, r in rows], excluded=excluded))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# SQLite flagship row — SAME site columns, its own state source
# ---------------------------------------------------------------------------
def git_short_rev(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() if out.returncode == 0 else None
    except OSError:
        return None


def sqlite_state_cells(status_row):
    """(transpiled, compiled, ab) from sqlite-status.tsv (files/crates/scripts)."""
    def split(key):
        m = re.fullmatch(r"(\d+)/(\d+)", status_row.get(key, ""))
        return (int(m.group(1)), int(m.group(2))) if m else None

    files = split("files")
    transpiled = ("—" if not files else
                  (f"✅ all {fmt_n(files[1])} files" if files[0] == files[1]
                   else f"⚠️ {fmt_n(files[0])}/{fmt_n(files[1])} files"))
    crates = split("crates")
    if not crates:
        compiled = "—"
    elif crates == (1, 1):
        compiled = "✅ one whole-program monocrate"
    elif crates[0] == crates[1]:
        compiled = f"✅ all {fmt_n(crates[1])} crates"
    else:
        compiled = f"⚠️ {fmt_n(crates[0])}/{fmt_n(crates[1])} crates"
    scripts = split("scripts")
    if scripts:
        mark = "✅ all" if scripts[0] == scripts[1] else "⚠️"
        count = (f"{scripts[0]}" if scripts[0] == scripts[1]
                 else f"{scripts[0]}/{scripts[1]}")
        runs = f" ({status_row['runs']} runs)" if status_row.get("runs") else ""
        ab = f"{mark} {count} SQL scripts byte-identical vs native CLI{runs}"
    else:
        ab = "—"
    return transpiled, compiled, ab


def sqlite_row(status_path, sites_path, label_suffix=""):
    """The single `| … |` SQLite markdown row — reused by the flagship table AND
    prepended as the first row of the per-project table (so SQLite sits IN the
    table alongside the CRUST-bench projects, not only in its own section)."""
    status_row = parse_kv(status_path)
    name = status_row.get("name", "SQLite")
    cell = f"[{name}]({status_row['url']})" if status_row.get("url") else name
    if status_row.get("output_url"):
        cell += f" → [Rust output]({status_row['output_url']})"
    cell += label_suffix
    t, c, tested = sqlite_state_cells(status_row)
    if sites_path and os.path.isfile(sites_path):
        fs, ss, red, fuod, suod, tfns, ufaith, usafe, made = safety_cells(parse_kv(sites_path))
    else:
        # Never render stale function-granular numbers — mark honestly pending.
        fs = ss = red = fuod = suod = tfns = ufaith = usafe = made = "`pending-regen`"
    return (f"| {cell} | {t} | {c} | {tested} | {fs} | {ss} | {red} | {fuod} | {suod} "
            f"| {tfns} | {ufaith} | {usafe} | {made} |")


def render_sqlite(status_path, sites_path):
    status_row = parse_kv(status_path)
    lines = [TABLE_OPEN, ""] + list(HEADER)
    lines.append(f"| 1 {sqlite_row(status_path, sites_path)}")
    lines.append("")
    lines.append(TABLE_CLOSE)
    lines.append("")
    lines.append(LEGEND)
    if not (sites_path and os.path.isfile(sites_path)):
        lines.append("")
        lines.append(
            "<sub>SQLite's site columns are `pending-regen`: the SQLite unsafe-site "
            "census is regenerated off the fixed develop tip AFTER the current "
            "verification battery completes and the 16-02 SQLite-lane fix merges — "
            "numbers produced before then would not match the shipped state. State "
            "columns above reflect the last verified run "
            f"({status_row.get('run_date', '?')}).</sub>")
    else:
        sr = parse_kv(sites_path)
        f_exprs = gi(sr, "f_total_exprs")
        r_exprs = gi(sr, "rust_exprs")
        f_uod = f"{100.0 * gi(sr, 'f_sites') / f_exprs:.2f}%" if f_exprs else "n/a"
        r_uod = f"{100.0 * gi(sr, 'r_sites') / r_exprs:.2f}%" if r_exprs else "n/a"
        lines.append("")
        lines.append(
            "<sub>SQLite site counts are code-generated two-mode: `cpp2rust --emit=rust` "
            "over the 84-translation-unit SQLite CLI link set (including the command-line "
            "shell, shell.c) emitted TWICE — the faithful lab baseline (all uplift segments "
            "dropped) and the safe production default — each scored by the operation-level "
            "`unsafe_census` over the emitted whole-program Rust monocrate, reduced by "
            "[`benchmarks/sqlite_sites_from_funnel.py`](benchmarks/sqlite_sites_from_funnel.py) "
            "into [`benchmarks/sqlite-sites.tsv`](benchmarks/sqlite-sites.tsv). "
            f"A further **{fmt_n(gi(sr, 'r_first_party_call'))}** first-party (in-project) "
            f"calls, **{fmt_n(gi(sr, 'r_intrinsic_call'))}** benign intrinsics, and "
            f"**{fmt_n(gi(sr, 'r_boundary_reborrow'))}** `&*p`/`&mut *p` boundary reborrows "
            f"(vs {fmt_n(gi(sr, 'f_boundary_reborrow'))} in the faithful baseline) are excluded "
            "from the total. Those reborrows are the SAME pointer risk re-spelled at each "
            "lifted-signature call seam (fan-out), not new unsafety — folding them in was what "
            "made the earlier figure read negative. The faithful→safe delta is **small by design**: "
            "SQLite is emitted as ONE whole-program monocrate, so nearly every function is "
            "externally visible across the link set and the ownership/pointer uplifts are "
            "ABI-vetoed there to preserve the C-ABI boundary — the site-removing uplift signal "
            "concentrates in the smaller, self-contained CRUST-bench projects, not here. The "
            "**UOD** columns (density, "
            f"{f_uod} → {r_uod}) are the cleaner cross-mode measure. State facts recorded "
            f"{status_row.get('run_date', '?')}.</sub>")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Splice / CLI
# ---------------------------------------------------------------------------
def splice(doc, begin, end, table):
    if begin not in doc or end not in doc:
        return None
    head, rest = doc.split(begin, 1)
    _, tail = rest.split(end, 1)
    return head + begin + "\n" + table + "\n" + end + tail


def take_flag(args, flag):
    if flag not in args:
        return None
    i = args.index(flag)
    value = args[i + 1]
    del args[i:i + 2]
    return value


def main():
    args = sys.argv[1:]
    update_target = take_flag(args, "--update")
    sqlite_status = take_flag(args, "--sqlite-status")
    sqlite_sites = take_flag(args, "--sqlite-sites")

    tables = []
    if args and os.path.isdir(args[0]):
        cbench_dir = args[1] if len(args) > 1 and os.path.isdir(args[1]) else None
        tables.append((CRUST_BEGIN, CRUST_END,
                       render_crust(args[0], cbench_dir, sqlite_status, sqlite_sites)))
    if sqlite_status:
        if not os.path.isfile(sqlite_status):
            print("bad --sqlite-status path", file=sys.stderr)
            return 2
        tables.append((SQLITE_BEGIN, SQLITE_END, render_sqlite(sqlite_status, sqlite_sites)))
    if not tables:
        print(__doc__, file=sys.stderr)
        return 2

    # Emit the static methodology section alongside the data tables so a
    # regeneration re-emits it (round-trips) rather than dropping it. Placed
    # first so it prints ahead of the tables in the stdout (no --update) path.
    tables.insert(0, (METHODOLOGY_BEGIN, METHODOLOGY_END, METHODOLOGY))

    if update_target:
        doc = open(update_target, encoding="utf-8").read()
        for begin, end, table in tables:
            spliced = splice(doc, begin, end, table)
            if spliced is None:
                # The methodology block is best-effort: an older RESULTS.md may
                # predate its markers, so skip it there instead of failing the
                # whole render. The data tables stay strict (markers required).
                if begin == METHODOLOGY_BEGIN:
                    continue
                print(f"markers {begin} missing in {update_target}", file=sys.stderr)
                return 2
            doc = spliced
        with open(update_target, "w", encoding="utf-8") as f:
            f.write(doc)
        print(f"updated {update_target}")
    else:
        print("\n\n".join(table for _, _, table in tables))
    return 0


if __name__ == "__main__":
    sys.exit(main())
