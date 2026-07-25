#!/usr/bin/env bash
#
# run_all.sh — the AI-free, zero-to-hero entry for the two-mode safety showcase
# (TWO_MODE_CONTRACT.md §9). It runs the WHOLE pipeline as a plain, ordered,
# idempotent script chain — NO AI / subagents at runtime — from building the two
# instruments to (optionally) publishing the 100 per-project mirrors and pushing
# the showcase.
#
# Stages (each resumable / idempotent):
#   1. build cpp2rust (ninja) + verify cargo-geiger v0.13.0 is installed
#      (the scorer of record; the in-house unsafe_census is retired).
#   2. ensure the showcase repo is on `main`; note dataset cache state
#      (the actual fetch is idempotent inside run_crust_bench.sh, stage 3).
#   3. two-mode CRUST sweep over all 100 projects (delegates to
#      run_crust_bench.sh -> run_crust_project.sh, which self-contains BOTH the
#      SAFE and FAITHFUL emits + geiger-scores each) + SQLite two-mode (§7):
#      emit SAFE + FAITHFUL over the 84-TU CLI link set, geiger-score both
#      INLINE, store the raw per-mode JSONs at
#      benchmarks/sqlite-geiger-{safe,faithful}.json (one file per mode).
#   4. reduce — the per-project TSVs already carry the g_*/gf_* geiger keys.
#   5. render — generate_report.py --update RESULTS.md (+ SQLite status/JSONs).
#   6. publish the 100 per-project mirrors as showcase submodules
#      (crust_mirror_publish.sh) — GATED behind --publish (default DRY-RUN).
#   7. commit the showcase (RESULTS.md + .gitmodules + mirror pointer bumps) and
#      push to both orgs — GATED behind --publish (default DRY-RUN).
#
# Flags:
#   --only "p1 p2"   Restrict to a space-separated project subset.
#   --subset N       Restrict to the first N projects (alphabetical). Ignored
#                    when --only is given.
#   --jobs N         Parallel projects for the sweep (default 4).
#   --publish        Actually create/push mirrors AND commit+push the showcase.
#                    DEFAULT OFF: a bare run is a safe DRY-RUN (builds mirror
#                    trees locally, prints what WOULD be pushed, touches nothing
#                    remote and makes no commit).
#   --no-sqlite      Skip the SQLite two-mode stage (CRUST corpus only).
#   -h, --help       Show this help and exit.
#
# A bare `run_all.sh` is therefore SAFE: full local build + sweep + report +
# dry-run publish, with zero remote side effects. Verification runs use
# `--subset N` and no `--publish`.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths — absolute, derived from this script's location. `~/Projects` is a
# symlink onto the same checkout, so SCRIPT_DIR-relative resolution is stable.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWCASE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CPP2RUST_REPO="$(cd "$SCRIPT_DIR/../../cpp-to-rust" && pwd)"
CPP_BUILD_DIR="$CPP2RUST_REPO/cpp/build"
CPP2RUST_BIN="$CPP_BUILD_DIR/bin/cpp2rust"
GEIGER_SCORE_SH="$CPP2RUST_REPO/bench/metrics/geiger_score.sh"

RUN_CRUST_BENCH="$SCRIPT_DIR/run_crust_bench.sh"
GENERATE_REPORT="$SCRIPT_DIR/generate_report.py"
MIRROR_PUBLISH="$SCRIPT_DIR/crust_mirror_publish.sh"

RESULTS_MD="${RESULTS_MD:-$SHOWCASE_ROOT/RESULTS.md}"
SQLITE_STATUS_TSV="${SQLITE_STATUS_TSV:-$SCRIPT_DIR/sqlite-status.tsv}"
# Per-mode geiger measurements of record — MODE-NAMED files, one per mode,
# never a shared path (so one mode's run can never overwrite the other's).
SQLITE_GEIGER_FAITHFUL="${SQLITE_GEIGER_FAITHFUL:-$SCRIPT_DIR/sqlite-geiger-faithful.json}"
SQLITE_GEIGER_SAFE="${SQLITE_GEIGER_SAFE:-$SCRIPT_DIR/sqlite-geiger-safe.json}"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clang2rust/crust-bench"
DATASET_DIR="$CACHE_DIR/dataset"
CBENCH_DIR="$DATASET_DIR/CBench"
RESULTS_DIR="$CACHE_DIR/results"

SQLITE_CDB="${SQLITE_CDB:-$HOME/Projects/.cache/sqlite-bench/compile_commands.json}"

# ALL script scratch lives under the project's own ./temp/ (never /tmp or the
# external cache) and is removed on exit (trap below). Shared with
# crust_mirror_publish.sh via MIRROR_TEMP so one cleanup covers every stage.
TEMP_DIR="$SHOWCASE_ROOT/temp"
export MIRROR_TEMP="$TEMP_DIR"
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT
SQLITE_WORK="$TEMP_DIR/sqlite2mode"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
ONLY=""
SUBSET=""
JOBS=4
PUBLISH=0
NO_SQLITE=0

usage() {
  sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --only)    ONLY="${2:?--only needs a value}"; shift 2 ;;
    --subset)  SUBSET="${2:?--subset needs a value}"; shift 2 ;;
    --jobs)    JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    --no-sqlite) NO_SQLITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unrecognized argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

MODE="DRY-RUN (no remote side effects)"; [ "$PUBLISH" -eq 1 ] && MODE="PUBLISH (mirrors + showcase pushed)"

banner() { printf '\n\033[1m========== %s ==========\033[0m\n' "$*" >&2; }
log()    { printf '[run_all] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Resolve the project set (honours --only / --subset) from the CBench cache.
# Falls back to nothing if the dataset is not yet fetched (stage 3 fetches it,
# so --subset/--only are the reliable selectors; a full run needs no list here).
# ---------------------------------------------------------------------------
project_list() {
  if [ -n "$ONLY" ]; then
    printf '%s\n' $ONLY
    return 0
  fi
  [ -d "$CBENCH_DIR" ] || return 0
  local all; all="$(cd "$CBENCH_DIR" && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done | sort)"
  if [ -n "$SUBSET" ]; then
    printf '%s\n' "$all" | head -n "$SUBSET"
  else
    printf '%s\n' "$all"
  fi
}

# ---------------------------------------------------------------------------
# Stage 1 — build the two instruments (idempotent; ninja/cargo no-op if fresh).
# ---------------------------------------------------------------------------
stage_build() {
  banner "STAGE 1/7  build cpp2rust + verify cargo-geiger"
  if [ -d "$CPP_BUILD_DIR" ]; then
    log "ninja cpp2rust  ($CPP_BUILD_DIR)"
    ( cd "$CPP_BUILD_DIR" && ninja cpp2rust )
  else
    log "warning: $CPP_BUILD_DIR missing — expecting a prebuilt $CPP2RUST_BIN"
  fi
  [ -x "$CPP2RUST_BIN" ] || { echo "error: cpp2rust not built: $CPP2RUST_BIN" >&2; exit 1; }
  [ -f "$GEIGER_SCORE_SH" ] || { echo "error: geiger_score.sh not found: $GEIGER_SCORE_SH" >&2; exit 1; }
  local gv; gv="$(cargo geiger --version 2>/dev/null | awk '{print $2}')"
  if [ "$gv" != "0.13.0" ]; then
    echo "error: cargo-geiger 0.13.0 required (found: '${gv:-not installed}')." >&2
    echo "       Install with:  cargo install cargo-geiger --locked" >&2
    exit 1
  fi
  log "cpp2rust:     $CPP2RUST_BIN"
  log "cargo-geiger: $gv (scorer of record; runner: $GEIGER_SCORE_SH)"
}

# ---------------------------------------------------------------------------
# Stage 2 — showcase on main; report dataset cache state (fetch is idempotent
# inside run_crust_bench.sh during the sweep).
# ---------------------------------------------------------------------------
stage_prepare() {
  banner "STAGE 2/7  ensure showcase on main + dataset state"
  local cur; cur="$(git -C "$SHOWCASE_ROOT" branch --show-current 2>/dev/null || echo '?')"
  if [ "$cur" != "main" ]; then
    log "showcase on '$cur' — checking out main"
    git -C "$SHOWCASE_ROOT" checkout main
  else
    log "showcase already on main"
  fi
  if [ -d "$CBENCH_DIR" ]; then
    log "dataset cached at $DATASET_DIR ($(ls "$CBENCH_DIR" | wc -l | tr -d ' ') projects) — fetch will skip"
  else
    log "dataset not cached — run_crust_bench.sh will fetch it in stage 3"
  fi
}

# ---------------------------------------------------------------------------
# Stage 3a — CRUST two-mode sweep (delegates to run_crust_bench.sh).
# ---------------------------------------------------------------------------
stage_sweep() {
  banner "STAGE 3/7  two-mode CRUST sweep (-P${JOBS})"
  local args=(--transpiler "$CPP2RUST_BIN" --geiger "$GEIGER_SCORE_SH" --jobs "$JOBS")
  local sel; sel="$(project_list | tr '\n' ' ')"
  if [ -n "$ONLY" ] || [ -n "$SUBSET" ]; then
    [ -n "$sel" ] || { log "no projects selected — skipping sweep"; return 0; }
    args+=(--only "$sel")
    log "sweep subset: $sel"
  else
    log "sweep: all projects"
  fi
  bash "$RUN_CRUST_BENCH" "${args[@]}"
}

# A large --cdb emit can intermittently hit the arena-UAF heisenbug
# (SIGBUS/SIGSEGV / exit 138/135); a re-run clears it (arena-keepalive
# @336bfd23). Retry up to 3 times; the caller decides fatality.
# Usage: emit_retry <out_dir> <cmd...>
emit_retry() {
  local out="$1"; shift
  local attempt rc=0
  for attempt in 1 2 3 4 5; do
    rm -rf "$out"; mkdir -p "$out"
    # `cmd && return 0; rc=$?` — NOT `if cmd; then return 0; fi; rc=$?`, whose
    # $? is the (false→0) if-statement status, masking the real failure code.
    "$@" && return 0
    rc=$?
    log "  emit exit=$rc (arena heisenbug?) — retry $attempt/5"
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Stage 3b — SQLite two-mode (§7): emit SAFE + FAITHFUL, geiger-score both.
# ---------------------------------------------------------------------------
stage_sqlite() {
  banner "STAGE 3/7  SQLite two-mode (§7)"
  if [ "$NO_SQLITE" -eq 1 ]; then log "--no-sqlite — skipping"; return 0; fi
  if [ ! -f "$SQLITE_CDB" ]; then
    log "warning: SQLite CDB not found at $SQLITE_CDB — skipping SQLite row (non-fatal)"
    return 0
  fi
  # The full 281-TU whole-program emit fails DETERMINISTICALLY (arena heisenbug);
  # the GREEN scope — matching the flagship "84 files" monocrate and its cli_ab —
  # is the 84-TU CLI link set. Filter the master CDB to those stems the SAME way
  # build_transpiled_monocrate.sh does (source core_link_set.sh, keep the 80 src
  # + 3 generated + shell TUs) before emitting either mode.
  local link_set="$CPP2RUST_REPO/bench/sqlite-c17/cli_oracle/core_link_set.sh"
  if [ ! -f "$link_set" ]; then
    log "warning: core_link_set.sh not found ($link_set) — skipping SQLite row (non-fatal)"; return 0
  fi
  # shellcheck source=/dev/null
  . "$link_set"
  mkdir -p "$SQLITE_WORK"
  local cdb84="$SQLITE_WORK/compile_commands.84.json"
  if ! python3 - "$SQLITE_CDB" "$cdb84" "$LIB_SRC_STEMS $GEN_STEMS $SHELL_STEM" <<'PY'; then
import json, os, sys
master, out, stems = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
db = json.load(open(master))
keep = [e for e in db
        if e["file"].endswith(".c") and os.path.basename(e["file"])[:-2] in stems]
seen = {os.path.basename(e["file"])[:-2] for e in keep}
missing = sorted(stems - seen)
if len(keep) != len(stems) or missing:
    sys.stderr.write("  84-TU CDB filter mismatch: kept %d want %d missing=%s\n"
                     % (len(keep), len(stems), missing))
    sys.exit(1)
json.dump(keep, open(out, "w"))
print("  filtered %d/%d TUs -> 84-TU link set" % (len(keep), len(db)))
PY
    log "warning: SQLite 84-TU CDB filter failed — skipping SQLite row (non-fatal)"; return 0
  fi

  local safe_out="$SQLITE_WORK/safe" faithful_out="$SQLITE_WORK/faithful"

  log "emit SAFE (uplift) over the 84-TU link set"
  if ! emit_retry "$safe_out" \
      env -u C2R_LAB_FACTORY -u C2R_LAB_DROP_POINTER -u C2R_LAB_DROP_ALLOC \
      -u C2R_LAB_DROP_PRINTF -u C2R_LAB_DROP_CSTRING_GLOBAL \
      "$CPP2RUST_BIN" --cdb "$cdb84" --emit=rust --out-dir "$safe_out"; then
    log "warning: SQLite SAFE emit failed after retries — skipping SQLite row (non-fatal)"; return 0
  fi

  log "emit FAITHFUL (all uplift dropped)"
  if ! emit_retry "$faithful_out" \
      env C2R_LAB_FACTORY=1 C2R_LAB_DROP_POINTER=1 C2R_LAB_DROP_ALLOC=1 \
      C2R_LAB_DROP_PRINTF=1 C2R_LAB_DROP_CSTRING_GLOBAL=1 \
      "$CPP2RUST_BIN" --cdb "$cdb84" --emit=rust --out-dir "$faithful_out"; then
    log "warning: SQLite FAITHFUL emit failed after retries — skipping SQLite row (non-fatal)"; return 0
  fi

  # geiger-score both emissions INLINE (the temp dirs are wiped on exit) and
  # store each mode's RAW geiger JSON in its own mode-named benchmarks/ file.
  log "geiger-score SAFE -> $SQLITE_GEIGER_SAFE"
  GEIGER_SCRATCH="$TEMP_DIR/geiger" bash "$GEIGER_SCORE_SH" "$safe_out" safe "$SQLITE_GEIGER_SAFE"     || { log "warning: SQLite SAFE geiger scoring failed — skipping SQLite row (non-fatal)"; return 0; }
  log "geiger-score FAITHFUL -> $SQLITE_GEIGER_FAITHFUL"
  GEIGER_SCRATCH="$TEMP_DIR/geiger" bash "$GEIGER_SCORE_SH" "$faithful_out" faithful "$SQLITE_GEIGER_FAITHFUL"     || { log "warning: SQLite FAITHFUL geiger scoring failed — skipping SQLite row (non-fatal)"; return 0; }
}

# ---------------------------------------------------------------------------
# Stage 5 — render the published report (authoritative, after SQLite regen).
# ---------------------------------------------------------------------------
stage_report() {
  banner "STAGE 5/7  render RESULTS.md"
  [ -f "$RESULTS_MD" ] || { log "warning: $RESULTS_MD missing — skipping render"; return 0; }
  local args=("$RESULTS_DIR")
  [ -d "$CBENCH_DIR" ] && args+=("$CBENCH_DIR")
  [ -f "$SQLITE_STATUS_TSV" ] && args+=(--sqlite-status "$SQLITE_STATUS_TSV")
  [ -f "$SQLITE_GEIGER_FAITHFUL" ] && args+=(--sqlite-geiger-faithful "$SQLITE_GEIGER_FAITHFUL")
  [ -f "$SQLITE_GEIGER_SAFE" ] && args+=(--sqlite-geiger-safe "$SQLITE_GEIGER_SAFE")
  args+=(--update "$RESULTS_MD")
  python3 "$GENERATE_REPORT" "${args[@]}"
  log "RESULTS.md updated"
}

# ---------------------------------------------------------------------------
# Stage 6 — publish per-project mirrors (dry-run unless --publish).
# ---------------------------------------------------------------------------
stage_mirrors() {
  banner "STAGE 6/7  publish mirrors [$MODE]"
  [ -x "$MIRROR_PUBLISH" ] || { log "warning: $MIRROR_PUBLISH missing — skipping mirrors"; return 0; }
  local ver; ver="$(git -C "$CPP2RUST_REPO" describe --tags --always 2>/dev/null || echo unknown)"
  local pflag=(); [ "$PUBLISH" -eq 1 ] && pflag=(--publish)
  local n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local safe_out="$RESULTS_DIR/$p/rust"
    local cbench="$CBENCH_DIR/$p"
    log "mirror: $p  (safe-out=$safe_out)"
    bash "$MIRROR_PUBLISH" --project "$p" --safe-out "$safe_out" \
         --cbench "$cbench" --version "$ver" "${pflag[@]}" || true
    n=$((n + 1))
  done < <(project_list)
  log "mirror stage done ($n project(s), version=$ver)"
}

# ---------------------------------------------------------------------------
# Stage 7 — commit + push the showcase (dry-run unless --publish).
# ---------------------------------------------------------------------------
stage_commit() {
  banner "STAGE 7/7  commit + push showcase [$MODE]"
  if [ "$PUBLISH" -ne 1 ]; then
    log "DRY-RUN — would: git add RESULTS.md .gitmodules mirrors/ && commit && push origin HEAD:main"
    git -C "$SHOWCASE_ROOT" status --short RESULTS.md .gitmodules mirrors 2>/dev/null | sed 's/^/[run_all]   /' >&2 || true
    return 0
  fi
  git -C "$SHOWCASE_ROOT" add RESULTS.md .gitmodules mirrors 2>/dev/null || true
  if git -C "$SHOWCASE_ROOT" diff --cached --quiet; then
    log "no showcase changes to commit"
    return 0
  fi
  git -C "$SHOWCASE_ROOT" commit -m "showcase: refresh two-mode report + mirror pointers" \
    || { log "commit failed — non-fatal"; return 0; }
  log "push origin HEAD:main (origin fans out to both orgs)"
  git -C "$SHOWCASE_ROOT" push origin HEAD:main
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  banner "run_all.sh — two-mode safety showcase [$MODE]"
  log "showcase:  $SHOWCASE_ROOT"
  log "cpp2rust:  $CPP2RUST_REPO"
  log "jobs=$JOBS  only='${ONLY}'  subset='${SUBSET}'  no_sqlite=$NO_SQLITE  publish=$PUBLISH"

  stage_build
  stage_prepare
  stage_sweep
  stage_sqlite
  stage_report
  stage_mirrors
  stage_commit

  banner "DONE [$MODE]"
  log "RESULTS.md:      $RESULTS_MD"
  log "sqlite geiger:   $SQLITE_GEIGER_FAITHFUL + $SQLITE_GEIGER_SAFE"
  log "per-project TSV: $RESULTS_DIR"
  [ "$PUBLISH" -eq 1 ] || log "this was a DRY-RUN — re-run with --publish to push mirrors + showcase"
}

main "$@"
