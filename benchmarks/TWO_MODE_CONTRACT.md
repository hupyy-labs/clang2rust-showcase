# Two-mode (before vs after) cargo-geiger safety report — BUILD CONTRACT

Single source of truth for the zero-to-hero report pipeline. Every script component obeys the
schema/invocations/naming below EXACTLY so the pieces interlock. The runtime pipeline is a plain
script chain — **no AI/subagents at runtime**.

## 0. Axis (READ FIRST)

The report compares **two Rust emissions of the same program**, both scored by
**cargo-geiger v0.13.0** (crates.io, the community-standard unsafe-usage detector):

- **AFTER (safe / uplift)** = production default, NO lab env vars. All uplift segments ON
  (pointer→Option/span, alloc→Box/Vec, printf→`print!`, cstring-global). `g_*` TSV keys.
- **BEFORE (faithful / no uplift)** = lab factory with all uplift segments dropped. `gf_*` TSV keys.

Change = `(before − after) / before`, signed. POSITIVE = the uplift removed unsafe expressions;
negative means worse.

**RETIRED (USER, 2026-07-25):** the in-house `unsafe_census` scorer, its per-operation "site"
counts, UOD, the per-function metrics (total_fns / unsafe_fns / fns_made_safe), and ALL C-side
statistics (the `--emit=funnel-ingest` input census) are retired from the measurement surface.
No measurement script runs them; no report renders them. Geiger numbers are NOT comparable to
the retired site counts.

## 1. Two emissions — SAME casing

Per project, from its `compile_commands.json` (`$CDB`), emit `--emit=rust` TWICE:

```sh
# AFTER (safe / production default) — leave rustic casing at its default (ON)
env -u C2R_LAB_FACTORY -u C2R_LAB_DROP_POINTER -u C2R_LAB_DROP_ALLOC \
    -u C2R_LAB_DROP_PRINTF -u C2R_LAB_DROP_CSTRING_GLOBAL \
    "$CPP2RUST" --cdb "$CDB" --emit=rust --out-dir "$SAFE_OUT"

# BEFORE (faithful) — drop all 4 uplift segments; DO NOT set C2R_RUSTIC_CASING=0
env C2R_LAB_FACTORY=1 C2R_LAB_DROP_POINTER=1 C2R_LAB_DROP_ALLOC=1 \
    C2R_LAB_DROP_PRINTF=1 C2R_LAB_DROP_CSTRING_GLOBAL=1 \
    "$CPP2RUST" --cdb "$CDB" --emit=rust --out-dir "$FAITHFUL_OUT"
```

RULE: **do NOT set `C2R_RUSTIC_CASING=0` in the faithful arm** — both modes stay
byte-comparable apart from the uplift itself (casing contributes 0 unsafe expressions).

## 2. Scoring — the shared geiger runner (invocation contract)

The ONLY scorer entry point is the parent repo's `bench/metrics/geiger_score.sh`
(`<crate-dir> [<mode-label>] [<json-out>]`), which owns the pinned invocation contract:

- **cargo-geiger v0.13.0 exactly** — version-gated; fails loudly with install instructions
  (`cargo install cargo-geiger --locked`).
- Runs on a **SCRATCH COPY** of the crate (geiger writes Cargo.lock + target/ and cargo-cleans
  the package each run — never score the original dir).
- Scratch Cargo.toml shaping: every `[[bin]]` section STRIPPED + `autobins = false` appended
  (the emitted `[[bin]] path="src/lib.rs"` target fails `fn main()->i32` and empties geiger's
  output) + an empty `[workspace]` table (isolation from any enclosing workspace).
- Explicit `RUSTC=<rustup path>` env on every geiger/cargo invocation (env beats a broken
  `~/.cargo/config.toml build.rustc`); **NIGHTLY rustc iff the crate root carries
  `#![feature(`** (e.g. the SQLite monocrate's `c_variadic`) — the geiger binary itself stays
  stable-built.
- `cargo geiger --offline --output-format Json --manifest-path <ABSOLUTE path>` — geiger
  rejects relative manifest paths and virtual-workspace roots (always per-crate).
- Failure mode: a non-compiling crate = exit 1 + empty stdout → scored `ok=0
  reason=build_failed`; downstream renders `n/a (build)` and excludes the project from
  aggregates (count disclosed). Never a silent zero.

## 3. Unit of measurement

The measured unit is **geiger unsafe expressions** (`unsafety.used.exprs.unsafe_`): individual
unsafe operations (e.g. raw-pointer dereferences) inside unsafe code. All FIVE geiger
categories are STORED per mode (functions, expressions, impls, traits, methods — each
safe/unsafe_ — plus `forbids_unsafe`); the table renders Expressions. NOT comparable to the
retired census "site" counts.

## 4. Per-mode storage separation (hard rule)

Each mode's raw geiger JSON (the measurement of record) lands in its OWN mode-named file that
the other mode's run CANNOT touch:

- per CRUST project: `<results>/<project>/geiger-safe.json` + `geiger-faithful.json`
  (a single raw geiger object for one crate; a JSON array of raw objects for multi-crate
  projects);
- SQLite: `benchmarks/sqlite-geiger-safe.json` + `benchmarks/sqlite-geiger-faithful.json`
  (copied out of the wiped temp dir before exit).

No script may ever write both modes to one path; no shared filename is written twice. The
report READS the two files; it never merges storage. A missing file IS the "not measured"
record (written only on `ok=1`).

## 5. Per-project TSV keys (`run_crust_project.sh::emit_row` fixed order)

```
project tus transpiled_cpp cpp_crates compiled_cpp transpiled_rust rust_crates
compiled_rust compiled_rust_faithful ab_cpp ab_rust pass1 ab_note pass1_note note
g_ok  g_fns_safe  g_fns_unsafe  g_exprs_safe  g_exprs_unsafe
      g_impls_safe g_impls_unsafe g_traits_safe g_traits_unsafe
      g_methods_safe g_methods_unsafe g_forbids_unsafe
gf_ok gf_fns_safe gf_fns_unsafe gf_exprs_safe gf_exprs_unsafe
      gf_impls_safe gf_impls_unsafe gf_traits_safe gf_traits_unsafe
      gf_methods_safe gf_methods_unsafe gf_forbids_unsafe
```

`g_ok`/`gf_ok` = 1 iff ≥1 crate emitted AND every crate geiger-scored clean in that mode.
A project's safety numbers are VALID only when `g_ok==1 && gf_ok==1`; otherwise the report
renders `n/a (build)` for the unmeasurable mode and the aggregate excludes the project
(exclusion count reported honestly).

## 6. Report (`generate_report.py`) — the one table

Header row (pinned by USER — exact titles):

```
| # | Project | Transpiled | Built | Tests | Unsafe (before) | Unsafe (after) | Change |
```

- `#` = 1-based row number; SQLite flagship = row 1, then projects 2..N.
- Transpiled = emit succeeded; Built = the Rust builds; Tests = differential A/B (+ pass@1).
- Unsafe (before) = `gf_exprs_unsafe`; Unsafe (after) = `g_exprs_unsafe`;
  Change = signed `(before − after) ÷ before`.
- Validity gating per §5; excluded count disclosed in the aggregate line.
- LEGEND speaks geiger's native taxonomy: the five categories (Functions / Expressions /
  Impls / Traits / Methods) and the three crate-safety tiers (🔒 forbid + no unsafe;
  ❓ no unsafe, no forbid; ☢️ unsafe found), plus the note that emitted crates do not declare
  `forbid(unsafe_code)`, so a fully-safe result reads ❓ under geiger's own rules. No emoji
  columns in the table — tiers live in the legend only.
- The generator is a pure-function pipeline (load_results → derive_metrics → render_table →
  splice) and is TESTED by `test_generate_report.py` (stdlib unittest; includes legend-drift
  guards). Rendered between the `<!-- crust-table:begin/end -->` markers in RESULTS.md
  (idempotent splice).

## 7. SQLite two-mode

SQLite's scope is the verified **84-TU CLI link set** (filtered from the 281-TU master CDB the
same way `build_transpiled_monocrate.sh` does). Emit both modes over it (§1 env toggles),
geiger-score both INLINE in `run_all.sh` stage 3b (the temp dirs are wiped on exit), and store
the raw per-mode JSONs at `benchmarks/sqlite-geiger-{safe,faithful}.json` (§4).
`sqlite-status.tsv` keeps the state cells. Expect a near-zero Change (documented: the
ownership/pointer uplifts are ABI-vetoed on the whole-program monocrate to preserve the C-ABI
boundary — the uplift signal concentrates in the smaller CRUST projects).

## 8. Per-project mirrors — PUBLIC + LICENSED + SUBMODULES OF THE SHOWCASE REPO

Unchanged: publish ALL 100 as PUBLIC repos (`o2alexanderfedin/<project>-rust-mirror`), each
carrying the upstream license; each a git SUBMODULE of the showcase repo at
`mirrors/<project>-rust/`. Content = the **AFTER (safe)** emitted crate, only when its safe
emission geiger-scored clean (`g_ok==1`). Script: `crust_mirror_publish.sh` (dry-run without
`--publish`).

## 9. Zero-to-hero entry `run_all.sh` (AI-free)

Ordered stages, each resumable/idempotent:
1. build `cpp2rust` (ninja) + VERIFY `cargo-geiger` v0.13.0 is installed (fail loudly with the
   install command; the retired `unsafe_census` build step is gone).
2. ensure showcase on `main`; dataset fetch is idempotent inside run_crust_bench.sh.
3. two-mode sweep over all 100 projects (`run_crust_bench.sh --geiger <geiger_score.sh>` →
   `run_crust_project.sh`) + SQLite two-mode (§7).
4. reduce — the per-project TSVs already carry the `g_*`/`gf_*` keys.
5. `generate_report.py <results> <cbench> --sqlite-status ... --sqlite-geiger-faithful ...
   --sqlite-geiger-safe ... --update RESULTS.md`.
6. publish 100 mirrors (§8) — gated behind `--publish` (default DRY-RUN/off).
7. commit + push the showcase — gated behind `--publish`.
Flags: `--only "p1 p2"`, `--subset N`, `--jobs N`, `--publish`, `--no-sqlite`.

## 10. Failure honesty (LOCKED project rule)

Faithful mode shifts translation burden onto the raw-form coverage, so some projects that
compile in safe mode may fail to emit/build in faithful mode. NEVER silently pass. Gate on the
per-mode `ok` flags (§5); render `n/a (build)` for the unmeasurable mode; exclude the project
from aggregates and show the count. Any newly-relied-on number must be reproducible by
re-running the script.
