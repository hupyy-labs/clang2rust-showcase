#!/usr/bin/env bash
#
# run_crust_bench.sh — score clang2rust against ALL 100 CRUST-bench projects,
# running each through the SAME 6-stage differential process as SQLite plus
# the two test oracles and the two-mode cargo-geiger safety measurement.
#
# CRUST-bench (https://github.com/anirudhkhatry/CRUST-bench) is a published
# benchmark of 100 C repositories, each paired with a hand-written safe-Rust
# interface and test suite (see benchmarks/CRUST-bench.md for the methodology).
#
# This script is now a thin ORCHESTRATOR: it fetches the dataset into an
# external, git-ignored cache, then fans `run_crust_project.sh` out over every
# project at moderate parallelism, and finally aggregates a summary + renders
# the published report. All the real per-project work (compile_commands
# synthesis, the 6 stages, A/B, pass@1, two-mode geiger scoring) lives in the
# project-agnostic driver `run_crust_project.sh` (DESIGN.md D1).
#
# Usage:
#   run_crust_bench.sh [--transpiler <path>] [--geiger <path>] [--cache <dir>]
#                      [--jobs N] [--only "p1 p2 …"] [--dry-run]
#
#   --transpiler <path>  cpp2rust binary. Default: the worktree/main build.
#   --geiger <path>      bench/metrics/geiger_score.sh (the shared cargo-geiger
#                        runner in the parent repo).
#   --cache <dir>        External, git-ignored dataset+results cache.
#                        Default: $XDG_CACHE_HOME/clang2rust/crust-bench.
#   --jobs N             Parallel projects (default 4 — MODERATE, leaves CPU
#                        headroom for other work; do NOT raise blindly).
#   --only "…"           Space-separated project subset (pilot runs).
#   --dry-run            Print the plan and exit.
#
# Requirements: cpp2rust (built), cargo-geiger v0.13.0, cargo/rustc,
# clang++/clang (C++26 + libc++), curl+unzip (fetch), and `bear` for
# Makefile-only projects.
#
# Outputs (under the --cache dir, alongside the dataset):
#   results/<project>.tsv   Per-project honest driver row (g_*/gf_* geiger keys).
#   results/<project>/geiger-{safe,faithful}.json  Per-mode raw geiger JSON
#                           (the measurements of record; one file per mode).
#   results/summary.tsv     Aggregate across all projects.
#   results/REPORT.md       Rendered two-mode report (cache-local copy).
#
# Also, at the end of a sweep, the PUBLISHED showcase report is kept in sync:
# generate_report.py is invoked with --update RESULTS.md + --sqlite-status +
# the two SQLite per-mode geiger JSONs so the canonical benchmarks/../RESULTS.md
# does not drift from results/REPORT.md (TWO_MODE_CONTRACT.md §5/§9.5). The
# per-project driver self-contains BOTH emits (safe + faithful, contract §1),
# so no two-mode env toggles are threaded through this orchestrator — it only
# fans the driver out.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSPILER="${TRANSPILER:-${SCRIPT_DIR}/../../cpp-to-rust/cpp/build/bin/cpp2rust}"
GEIGER_SCORE="${GEIGER_SCORE:-${SCRIPT_DIR}/../../cpp-to-rust/bench/metrics/geiger_score.sh}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clang2rust/crust-bench"
JOBS=4
ONLY=""
DRY_RUN=0

CRUST_BENCH_REPO="https://github.com/anirudhkhatry/CRUST-bench"
CRUST_BENCH_DATASET_ZIP_PATH="datasets"

usage() { sed -n '2,/^set -uo pipefail/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --transpiler) TRANSPILER="$2"; shift 2 ;;
    --geiger) GEIGER_SCORE="$2"; shift 2 ;;
    --cache) CACHE_DIR="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unrecognized argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

DATASET_DIR="${CACHE_DIR}/dataset"
CBENCH_DIR="${DATASET_DIR}/CBench"
RBENCH_DIR="${DATASET_DIR}/RBench"
RESULTS_DIR="${CACHE_DIR}/results"
SUMMARY_TSV="${RESULTS_DIR}/summary.tsv"

# Published showcase report + SQLite status TSV + per-mode geiger JSONs
# (kept in sync post-sweep).
RESULTS_MD="${RESULTS_MD:-${SCRIPT_DIR}/../RESULTS.md}"
SQLITE_STATUS_TSV="${SQLITE_STATUS_TSV:-${SCRIPT_DIR}/sqlite-status.tsv}"
SQLITE_GEIGER_FAITHFUL="${SQLITE_GEIGER_FAITHFUL:-${SCRIPT_DIR}/sqlite-geiger-faithful.json}"
SQLITE_GEIGER_SAFE="${SQLITE_GEIGER_SAFE:-${SCRIPT_DIR}/sqlite-geiger-safe.json}"

log() { printf '[run_crust_bench] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Fetch the dataset into the external cache (never into this repo — GPL-3.0).
# ---------------------------------------------------------------------------
fetch_dataset() {
  if [ -d "$CBENCH_DIR" ] && [ -d "$RBENCH_DIR" ]; then
    log "dataset already present at $DATASET_DIR — skipping fetch"
    return 0
  fi
  log "fetching CRUST-bench into external cache: $CACHE_DIR"
  mkdir -p "$CACHE_DIR"
  local archive="${CACHE_DIR}/crust-bench.zip"
  curl -fL "${CRUST_BENCH_REPO}/archive/refs/heads/main.zip" -o "$archive"
  local extract_dir="${CACHE_DIR}/_extract"
  rm -rf "$extract_dir"; mkdir -p "$extract_dir"
  unzip -q "$archive" -d "$extract_dir"
  local repo_root
  repo_root="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  local dataset_zip
  dataset_zip="$(find "${repo_root}/${CRUST_BENCH_DATASET_ZIP_PATH}" -iname '*.zip' 2>/dev/null | head -n1)"
  mkdir -p "$DATASET_DIR"
  if [ -n "$dataset_zip" ]; then
    unzip -q "$dataset_zip" -d "$DATASET_DIR"
  else
    log "warning: no dataset zip found — copying repo dataset dirs directly"
    cp -R "${repo_root}/CBench" "$CBENCH_DIR" 2>/dev/null || true
    cp -R "${repo_root}/RBench" "$RBENCH_DIR" 2>/dev/null || true
  fi
  rm -rf "$extract_dir" "$archive"
}

# ---------------------------------------------------------------------------
# Aggregate the per-project driver rows into an honest funnel (DESIGN.md D5).
# ---------------------------------------------------------------------------
write_summary() {
  python3 - "$RESULTS_DIR" > "$SUMMARY_TSV" <<'PY'
import os, sys
results = sys.argv[1]
rows = []
for f in sorted(os.listdir(results)):
    if not f.endswith(".tsv") or f == "summary.tsv":
        continue
    d = {}
    for part in open(os.path.join(results, f)).read().strip().split("\t"):
        if "=" in part:
            k, v = part.split("=", 1); d[k] = v
    rows.append(d)

def gi(d, k):
    try: return int(d.get(k, "0"))
    except ValueError: return 0
def ratio_full(d, k):
    v = d.get(k, "0/0")
    try: a, b = v.split("/"); return int(b) > 0 and a == b
    except Exception: return False

N = len(rows)
def count(pred): return sum(1 for r in rows if pred(r))

fields = ["transpiled_cpp","cpp_crates","compiled_cpp","transpiled_rust","rust_crates",
          "compiled_rust","ab_cpp","ab_rust","pass1",
          "gf_ok","gf_exprs_unsafe","g_ok","g_exprs_unsafe","note"]
print("project\t" + "\t".join(fields))
for r in rows:
    print(r.get("project","?") + "\t" + "\t".join(r.get(k,"") for k in fields))

measured = [r for r in rows if r.get("g_ok") == "1" and r.get("gf_ok") == "1"]
before = sum(gi(r, "gf_exprs_unsafe") for r in measured)
after = sum(gi(r, "g_exprs_unsafe") for r in measured)

print()
print(f"# aggregate over {N} projects")
print(f"# transpiled_cpp=yes:   {count(lambda r: r.get('transpiled_cpp')=='yes')}/{N}")
print(f"# transpiled_rust=yes:  {count(lambda r: r.get('transpiled_rust')=='yes')}/{N}")
print(f"# compiled_cpp=full:    {count(lambda r: ratio_full(r,'compiled_cpp'))}/{N}")
print(f"# compiled_rust=full:   {count(lambda r: ratio_full(r,'compiled_rust'))}/{N}")
print(f"# ab_cpp=pass:          {count(lambda r: r.get('ab_cpp')=='pass')}/{N}")
print(f"# ab_rust=pass:         {count(lambda r: r.get('ab_rust')=='pass')}/{N}")
print(f"# pass1=pass:           {count(lambda r: r.get('pass1')=='pass')}/{N}")
print(f"# geiger both-mode measured: {len(measured)}/{N}")
print(f"# geiger unsafe exprs: before(faithful)={before} after(safe)={after}")
PY
  log "summary written to $SUMMARY_TSV"
  # Render the published site-granular report (SQLite consumes its own site
  # TSV if present; otherwise renders pending-regen — see generate_report.py).
  if command -v python3 >/dev/null 2>&1; then
    python3 "${SCRIPT_DIR}/generate_report.py" "$RESULTS_DIR" "$CBENCH_DIR" \
      > "${RESULTS_DIR}/REPORT.md" 2>>"${RESULTS_DIR}/report.err" \
      && log "per-project report written to ${RESULTS_DIR}/REPORT.md"
  fi

  # Sync the PUBLISHED showcase report so it never drifts from the cache-local
  # REPORT.md (TWO_MODE_CONTRACT.md §5/§9.5). generate_report.py splices the
  # CRUST + SQLite tables between their markers in-place; the SQLite row is fed
  # the two-mode site + status TSVs when present. Non-fatal.
  if command -v python3 >/dev/null 2>&1 && [ -f "$RESULTS_MD" ]; then
    local gr_args=("$RESULTS_DIR" "$CBENCH_DIR")
    [ -f "$SQLITE_STATUS_TSV" ] && gr_args+=(--sqlite-status "$SQLITE_STATUS_TSV")
    [ -f "$SQLITE_GEIGER_FAITHFUL" ] && gr_args+=(--sqlite-geiger-faithful "$SQLITE_GEIGER_FAITHFUL")
    [ -f "$SQLITE_GEIGER_SAFE" ] && gr_args+=(--sqlite-geiger-safe "$SQLITE_GEIGER_SAFE")
    gr_args+=(--update "$RESULTS_MD")
    if python3 "${SCRIPT_DIR}/generate_report.py" "${gr_args[@]}" \
         >>"${RESULTS_DIR}/report.err" 2>&1; then
      log "published report synced -> $RESULTS_MD"
    else
      log "warning: RESULTS.md sync failed (see ${RESULTS_DIR}/report.err) — non-fatal"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "transpiler:  $TRANSPILER"
  log "geiger:      $GEIGER_SCORE"
  log "cache dir:   $CACHE_DIR"
  log "jobs:        $JOBS"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry run — planned steps:"
    log "  1. fetch CRUST-bench (GPL-3.0) into $DATASET_DIR"
    log "  2. run_crust_project.sh over every project at -P${JOBS}"
    log "  3. aggregate results/summary.tsv and render results/REPORT.md"
    exit 0
  fi

  [ -x "$TRANSPILER" ] || { echo "error: transpiler not executable: $TRANSPILER" >&2; exit 1; }
  [ -f "$GEIGER_SCORE" ] || { echo "error: geiger_score.sh not found: $GEIGER_SCORE" >&2; exit 1; }

  mkdir -p "$RESULTS_DIR"
  fetch_dataset
  [ -d "$CBENCH_DIR" ] || { echo "error: dataset fetch did not produce $CBENCH_DIR" >&2; exit 1; }

  # Project list (all, or the --only subset).
  local projects
  if [ -n "$ONLY" ]; then
    projects="$ONLY"
  else
    projects="$(cd "$CBENCH_DIR" && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done)"
  fi

  export TRANSPILER GEIGER_SCORE CACHE_DIR RESULTS_DIR
  log "scoring $(printf '%s\n' $projects | wc -l | tr -d ' ') projects at -P${JOBS}"
  printf '%s\n' $projects | xargs -P "$JOBS" -I {} bash "${SCRIPT_DIR}/run_crust_project.sh" {}

  write_summary
}

main "$@"
