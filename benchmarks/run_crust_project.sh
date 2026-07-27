#!/usr/bin/env bash
#
# run_crust_project.sh <project> — run ONE CRUST-bench C project through the
# same 6-stage differential process as SQLite, plus the two test oracles and
# the TWO-MODE cargo-geiger safety measurement, and emit a single honest row.
#
# This is the project-agnostic driver (DESIGN.md D1) that reuses the generic
# 6-stage bricks — it does NOT depend on any SQLite-specific glue
# (canonical_flags / amalgamation firewall / 84-TU link set). It is invoked
# once per project by the orchestrator `run_crust_bench.sh`.
#
# Stages (per DESIGN.md D5 — every stage is counted; N/A items are logged,
# never silently capped):
#   stage1  C -> C++     (cpp2rust --emit=cpp)
#   stage2  compile C++  (clang++ -std=c++26 -stdlib=libc++, per-TU object)
#   stage3  A/B          native-C binary vs transpiled-C++ binary (best-effort)
#   stage4  C -> Rust    (cpp2rust --emit=rust) — TWICE: safe (production
#           default, uplift ON) and faithful (lab factory, uplift OFF)
#   stage5  build Rust   (rustc --crate-type=lib --emit=obj, per crate)
#   stage6  A/B          native-C binary vs transpiled-Rust binary (best-effort)
#   pass@1  CRUST-bench official: splice emitted crate under the RBench
#           interface -> `cargo test` (best-effort)
#   geiger  BOTH emissions scored by cargo-geiger v0.13.0 via the shared
#           runner bench/metrics/geiger_score.sh. The per-mode RAW geiger
#           JSON (the measurement of record) is stored in MODE-NAMED files —
#           <results>/<project>/geiger-safe.json and geiger-faithful.json —
#           so one mode's run can never overwrite the other's measurement.
#           (The census-era C-side/unsafe_census scoring is RETIRED.)
#
# The native-vs-transpiled A/B links the emitted per-TU objects into one
# binary. For multi-TU projects this frequently fails (cross-TU C++ name
# mangling; unresolved compiler-builtin FFI on the Rust side) — those are
# recorded as `na(<reason>)`, honestly, NOT as a pass or a silent drop.
#
# Output: one tab-separated key=value line to `<results>/<project>.tsv`, and a
# full log to `<results>/<project>/driver.log`. The row's schema is consumed
# by generate_report.py (g_* = safe/after, gf_* = faithful/before).
#
# Env (all have defaults; the orchestrator sets the first three):
#   TRANSPILER          cpp2rust binary   (freshly built in the worktree)
#   GEIGER_SCORE        bench/metrics/geiger_score.sh (parent repo)
#   CACHE_DIR           dataset+results cache root
#   CXX / CC / RUSTC    toolchain (default: Homebrew LLVM clang++/clang; rustup)
#   *_TIMEOUT           per-step wall-clock limits (seconds)

set -uo pipefail

PROJECT="${1:?usage: run_crust_project.sh <project>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/clang2rust/crust-bench}"
DATASET_DIR="${CACHE_DIR}/dataset"
CBENCH_DIR="${DATASET_DIR}/CBench"
RBENCH_DIR="${DATASET_DIR}/RBench"
RESULTS_DIR="${RESULTS_DIR:-${CACHE_DIR}/results}"

TRANSPILER="${TRANSPILER:-${SCRIPT_DIR}/../../cpp-to-rust/cpp/build/bin/cpp2rust}"
# geiger_score.sh lives in the parent transpiler repo. Two supported layouts:
# showcase as a SIBLING checkout (../../cpp-to-rust/...) and showcase as the
# cpp-to-rust SUBMODULE (../../bench/...).
_default_geiger() {
  local c
  for c in "${SCRIPT_DIR}/../../cpp-to-rust/bench/metrics/geiger_score.sh" \
           "${SCRIPT_DIR}/../../bench/metrics/geiger_score.sh"; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
  echo "${SCRIPT_DIR}/../../cpp-to-rust/bench/metrics/geiger_score.sh"
}
GEIGER_SCORE="${GEIGER_SCORE:-$(_default_geiger)}"

pick() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; echo "$1"; }
CXX="${CXX:-$(pick /opt/homebrew/opt/llvm/bin/clang++ clang++)}"
CC="${CC:-$(pick /opt/homebrew/opt/llvm/bin/clang clang)}"
RUSTC="${RUSTC:-$(rustup which rustc 2>/dev/null || command -v rustc || echo rustc)}"
CARGO="${CARGO:-$(rustup which cargo 2>/dev/null || command -v cargo || echo cargo)}"

CDB_TIMEOUT="${CDB_TIMEOUT:-120}"
TRANSPILE_TIMEOUT="${TRANSPILE_TIMEOUT:-120}"
COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-150}"
AB_TIMEOUT="${AB_TIMEOUT:-60}"
PASS1_TIMEOUT="${PASS1_TIMEOUT:-180}"

if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
else TIMEOUT_BIN=""; fi
run_bounded() { local s="$1"; shift; if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$s" "$@"; else "$@"; fi; }

C_DIR="${CBENCH_DIR}/${PROJECT}"
R_DIR="${RBENCH_DIR}/${PROJECT}"
OUT="${RESULTS_DIR}/${PROJECT}"
CPP_OUT="${OUT}/cpp"
RUST_OUT="${OUT}/rust"
LOG="${OUT}/driver.log"
TSV="${RESULTS_DIR}/${PROJECT}.tsv"

mkdir -p "$OUT"
: > "$LOG"
log() { printf '[%s] %s\n' "$PROJECT" "$*" >>"$LOG"; }

# Host sysroot/builtin includes (macOS) so a stand-alone parse resolves
# <stdint.h> etc. — same idea as run_crust_bench.sh's harden step.
HOST_SYSROOT=""; HOST_BUILTIN_INCLUDE=""
if [ "$(uname -s)" = "Darwin" ] && command -v xcrun >/dev/null 2>&1; then
  HOST_SYSROOT="$(xcrun --show-sdk-path 2>/dev/null || true)"
  _hc="$(xcrun -f clang 2>/dev/null || true)"
  [ -n "$_hc" ] && HOST_BUILTIN_INCLUDE="$("$_hc" -print-resource-dir 2>/dev/null)/include"
fi

# ---------------------------------------------------------------------------
# TSV row accumulator (all fields default to sane "unknown" values)
# ---------------------------------------------------------------------------
declare -A ROW
ROW[project]="$PROJECT"
ROW[tus]=0
ROW[transpiled_cpp]="no"; ROW[cpp_crates]="0/0"
ROW[compiled_cpp]="0/0"
ROW[transpiled_rust]="no"; ROW[rust_crates]="0/0"
ROW[compiled_rust]="0/0"
ROW[ab_cpp]="na"; ROW[ab_rust]="na"; ROW[pass1]="na"
ROW[ab_note]=""; ROW[pass1_note]=""
ROW[note]=""
ROW[compiled_rust_faithful]="n/a"
# --- two-mode cargo-geiger keys: g_* = safe (after), gf_* = faithful (before).
# ALL FIVE geiger categories stored per mode (functions/exprs/impls/traits/
# methods, each safe/unsafe_) + forbids_unsafe + the per-mode ok gate.
for _m in g gf; do
  ROW[${_m}_ok]=0
  ROW[${_m}_fns_safe]=0;     ROW[${_m}_fns_unsafe]=0
  ROW[${_m}_exprs_safe]=0;   ROW[${_m}_exprs_unsafe]=0
  ROW[${_m}_impls_safe]=0;   ROW[${_m}_impls_unsafe]=0
  ROW[${_m}_traits_safe]=0;  ROW[${_m}_traits_unsafe]=0
  ROW[${_m}_methods_safe]=0; ROW[${_m}_methods_unsafe]=0
  ROW[${_m}_forbids_unsafe]=0
done

emit_row() {
  local out="" k
  for k in project tus transpiled_cpp cpp_crates compiled_cpp transpiled_rust rust_crates \
           compiled_rust compiled_rust_faithful ab_cpp ab_rust pass1 ab_note pass1_note note \
           g_ok g_fns_safe g_fns_unsafe g_exprs_safe g_exprs_unsafe \
           g_impls_safe g_impls_unsafe g_traits_safe g_traits_unsafe \
           g_methods_safe g_methods_unsafe g_forbids_unsafe \
           gf_ok gf_fns_safe gf_fns_unsafe gf_exprs_safe gf_exprs_unsafe \
           gf_impls_safe gf_impls_unsafe gf_traits_safe gf_traits_unsafe \
           gf_methods_safe gf_methods_unsafe gf_forbids_unsafe; do
    out+="${k}=${ROW[$k]}"$'\t'
  done
  printf '%s\n' "${out%$'\t'}" >"$TSV"
  log "row: $(cat "$TSV")"
}

# geiger_mode_into_row <mode_out_dir> <mode-label> <row-prefix> <json_dest>
# Scores EVERY emitted crate under <mode_out_dir> with the shared runner
# (bench/metrics/geiger_score.sh), sums the five geiger categories into the
# ROW keys under <row-prefix>, and stores the RAW geiger JSON (the
# measurement of record) at <json_dest> — a MODE-NAMED file (geiger-safe.json
# vs geiger-faithful.json), written only on a clean score, never shared
# between modes. <row-prefix>_ok=1 iff >=1 crate emitted AND every crate
# scored ok=1; forbids_unsafe is the AND across crates.
geiger_mode_into_row() {
  local mode_out="$1" mode="$2" p="$3" json_dest="$4"
  local -a manifests=()
  while IFS= read -r m; do [ -n "$m" ] && manifests+=("$m"); done \
    < <(find "$mode_out" -name Cargo.toml 2>/dev/null | sort)
  [ "${#manifests[@]}" -gt 0 ] || { log "geiger[$mode]: no crates emitted"; return; }

  local scratch="${OUT}/.geiger.${mode}"
  rm -rf "$scratch"; mkdir -p "$scratch"
  local ok=1 i=0 line vals
  local -a jsons=()
  local fs=0 fu=0 es=0 eu=0 is=0 iu=0 ts=0 tu=0 ms=0 mu=0 forbids=1
  for m in "${manifests[@]}"; do
    i=$((i + 1))
    local j="$scratch/crate${i}.json"
    line="$(bash "$GEIGER_SCORE" "$(dirname "$m")" "$mode" "$j" 2>>"$LOG")"
    log "geiger[$mode] $line"
    if [[ "$line" == *" ok=1 "* ]] && [ -f "$j" ]; then
      jsons+=("$j")
      vals="$(awk '{for(n=1;n<=NF;n++){split($n,kv,"=");v[kv[1]]=kv[2]}
        print v["fns_safe"],v["fns_unsafe"],v["exprs_safe"],v["exprs_unsafe"],
              v["impls_safe"],v["impls_unsafe"],v["traits_safe"],v["traits_unsafe"],
              v["methods_safe"],v["methods_unsafe"],v["forbids_unsafe"]}' <<<"$line")"
      read -r _fs _fu _es _eu _is _iu _ts _tu _ms _mu _fb <<<"$vals"
      fs=$((fs + _fs)); fu=$((fu + _fu)); es=$((es + _es)); eu=$((eu + _eu))
      is=$((is + _is)); iu=$((iu + _iu)); ts=$((ts + _ts)); tu=$((tu + _tu))
      ms=$((ms + _ms)); mu=$((mu + _mu))
      [ "$_fb" = "1" ] || forbids=0
    else
      ok=0
    fi
  done

  if [ "$ok" -eq 1 ] && [ "${#jsons[@]}" -gt 0 ]; then
    jq -s 'if length == 1 then .[0] else . end' "${jsons[@]}" > "$json_dest"
    ROW[${p}_ok]=1
    ROW[${p}_fns_safe]=$fs;     ROW[${p}_fns_unsafe]=$fu
    ROW[${p}_exprs_safe]=$es;   ROW[${p}_exprs_unsafe]=$eu
    ROW[${p}_impls_safe]=$is;   ROW[${p}_impls_unsafe]=$iu
    ROW[${p}_traits_safe]=$ts;  ROW[${p}_traits_unsafe]=$tu
    ROW[${p}_methods_safe]=$ms; ROW[${p}_methods_unsafe]=$mu
    ROW[${p}_forbids_unsafe]=$forbids
  fi
  rm -rf "$scratch"
}

# ---------------------------------------------------------------------------
# Step 0: compile_commands.json (CMake or bear+make), then harden for macOS
# ---------------------------------------------------------------------------
ensure_cdb() {
  local cdb="${C_DIR}/compile_commands.json"
  if [ -f "$cdb" ] && python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$cdb" 2>/dev/null; then
    echo "$cdb"; return 0
  fi
  if [ -f "${C_DIR}/CMakeLists.txt" ]; then
    ( cd "$C_DIR" && run_bounded "$CDB_TIMEOUT" cmake -B build \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 )
    [ -f "${C_DIR}/build/compile_commands.json" ] && cp "${C_DIR}/build/compile_commands.json" "$cdb"
  elif [ -f "${C_DIR}/Makefile" ] && command -v bear >/dev/null 2>&1; then
    ( cd "$C_DIR" && run_bounded "$CDB_TIMEOUT" bear -- make >/dev/null 2>&1 )
  fi
  if [ -f "$cdb" ] && ! python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$cdb" 2>/dev/null; then
    rm -f "$cdb"
  fi
  [ -f "$cdb" ] && echo "$cdb" || return 1
}

harden_cdb() {
  local cdb="$1"
  [ -n "$HOST_SYSROOT" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$cdb" "$HOST_SYSROOT" "$HOST_BUILTIN_INCLUDE" <<'PY'
import json, sys
cdb, sysroot, builtin = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(cdb))
except Exception:
    sys.exit(0)
extra = ["-isysroot", sysroot] + (["-isystem", builtin] if builtin else [])
for e in data:
    cmd, args = e.get("command"), e.get("arguments")
    if isinstance(cmd, str) and "-isysroot" not in cmd:
        head, _, tail = cmd.partition(" ")
        e["command"] = head + " " + " ".join(extra) + ((" " + tail) if tail else "")
    elif isinstance(args, list) and "-isysroot" not in args and args:
        e["arguments"] = [args[0]] + extra + args[1:]
json.dump(data, open(cdb, "w"), indent=2)
PY
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ ! -d "$C_DIR" ]; then
  ROW[note]="no-project-dir"; emit_row; exit 0
fi

CDB="$(ensure_cdb)"
if [ -z "${CDB:-}" ]; then
  ROW[note]="no-compile-commands"; emit_row; exit 0
fi
harden_cdb "$CDB"
ROW[tus]="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$CDB" 2>/dev/null || echo 0)"
log "cdb=$CDB tus=${ROW[tus]}"

# --- stage1: C -> C++ ---
rm -rf "$CPP_OUT"; mkdir -p "$CPP_OUT"
run_bounded "$TRANSPILE_TIMEOUT" "$TRANSPILER" --cdb "$CDB" --out-dir "$CPP_OUT" --emit=cpp >>"$LOG" 2>&1
cpp_trc=$?
mapfile -t CPP_FILES < <(find "$CPP_OUT" -name '*.cpp' 2>/dev/null)
n_cpp=${#CPP_FILES[@]}
ROW[cpp_crates]="${n_cpp}/${ROW[tus]}"
if [ "$n_cpp" -eq 0 ]; then ROW[transpiled_cpp]="no"
elif [ "$cpp_trc" -ne 0 ]; then ROW[transpiled_cpp]="partial"
else ROW[transpiled_cpp]="yes"; fi

# --- stage2: compile C++ (per-TU object) ---
n_cpp_ok=0
for f in "${CPP_FILES[@]}"; do
  d="$(dirname "$f")"
  if run_bounded "$COMPILE_TIMEOUT" "$CXX" -std=c++26 -stdlib=libc++ -O0 -w \
       -c "$f" -I "$d" -I "$CPP_OUT" -o "$f.o" >>"$LOG" 2>&1; then
    n_cpp_ok=$((n_cpp_ok + 1))
  fi
done
ROW[compiled_cpp]="${n_cpp_ok}/${n_cpp}"
log "C++ compiled ${n_cpp_ok}/${n_cpp}"

# --- stage4: C -> Rust — SAFE (uplift / production default), contract §1 ---
# Lab toggles are explicitly unset so an inherited lab env can never leak into
# the production-default emission that feeds the r_* keys.
rm -rf "$RUST_OUT"; mkdir -p "$RUST_OUT"
run_bounded "$TRANSPILE_TIMEOUT" env -u C2R_LAB_FACTORY -u C2R_LAB_DROP_POINTER \
    -u C2R_LAB_DROP_ALLOC -u C2R_LAB_DROP_PRINTF -u C2R_LAB_DROP_CSTRING_GLOBAL \
    "$TRANSPILER" --cdb "$CDB" --out-dir "$RUST_OUT" --emit=rust >>"$LOG" 2>&1
rust_trc=$?
mapfile -t RUST_MANIFESTS < <(find "$RUST_OUT" -name Cargo.toml 2>/dev/null)
n_rust=${#RUST_MANIFESTS[@]}
ROW[rust_crates]="${n_rust}/${ROW[tus]}"
if [ "$n_rust" -eq 0 ]; then ROW[transpiled_rust]="no"
elif [ "$rust_trc" -ne 0 ]; then ROW[transpiled_rust]="partial"
else ROW[transpiled_rust]="yes"; fi

# --- stage5: build Rust (per crate, library object) ---
n_rust_ok=0
for m in "${RUST_MANIFESTS[@]}"; do
  cdir="$(dirname "$m")"
  if run_bounded "$COMPILE_TIMEOUT" "$RUSTC" --edition=2021 --crate-type=lib \
       --emit=obj "$cdir/src/lib.rs" -o "$cdir/.chk.o" >>"$LOG" 2>&1; then
    n_rust_ok=$((n_rust_ok + 1))
  fi
done
ROW[compiled_rust]="${n_rust_ok}/${n_rust}"
log "Rust compiled ${n_rust_ok}/${n_rust}"

# --- geiger: score the SAFE (after) emission; raw JSON -> geiger-safe.json ---
geiger_mode_into_row "$RUST_OUT" safe g "${OUT}/geiger-safe.json"
log "geiger safe: ok=${ROW[g_ok]} exprs_unsafe=${ROW[g_exprs_unsafe]}"

# --- stage4b: C -> Rust — FAITHFUL (lab factory, all uplift segments dropped) ---
# Contract §1: SAME casing (do NOT set C2R_RUSTIC_CASING=0) — both modes stay
# byte-comparable apart from the uplift itself. gf_* keys carry this crate's
# geiger score (before / no uplift).
FAITHFUL_OUT="${OUT}/rust_faithful"
rm -rf "$FAITHFUL_OUT"; mkdir -p "$FAITHFUL_OUT"
run_bounded "$TRANSPILE_TIMEOUT" env C2R_LAB_FACTORY=1 C2R_LAB_DROP_POINTER=1 \
    C2R_LAB_DROP_ALLOC=1 C2R_LAB_DROP_PRINTF=1 C2R_LAB_DROP_CSTRING_GLOBAL=1 \
    "$TRANSPILER" --cdb "$CDB" --out-dir "$FAITHFUL_OUT" --emit=rust >>"$LOG" 2>&1

# --- geiger: score the FAITHFUL (before) emission; raw JSON -> geiger-faithful.json ---
geiger_mode_into_row "$FAITHFUL_OUT" faithful gf "${OUT}/geiger-faithful.json"
log "geiger faithful: ok=${ROW[gf_ok]} exprs_unsafe=${ROW[gf_exprs_unsafe]}"

# --- faithful build-check (best-effort; NEVER fails the project — contract §5) ---
n_f_ok=0
mapfile -t FAITHFUL_MANIFESTS < <(find "$FAITHFUL_OUT" -name Cargo.toml 2>/dev/null)
n_f=${#FAITHFUL_MANIFESTS[@]}
for m in "${FAITHFUL_MANIFESTS[@]}"; do
  cdir="$(dirname "$m")"
  if run_bounded "$COMPILE_TIMEOUT" "$RUSTC" --edition=2021 --crate-type=lib \
       --emit=obj "$cdir/src/lib.rs" -o "$cdir/.chk.o" >>"$LOG" 2>&1; then
    n_f_ok=$((n_f_ok + 1))
  fi
done
ROW[compiled_rust_faithful]="${n_f_ok}/${n_f}"
log "Faithful compiled ${n_f_ok}/${n_f}"

# ---------------------------------------------------------------------------
# stage3 + stage6: native-vs-transpiled A/B (best-effort; N/A logged)
# ---------------------------------------------------------------------------
normalize() { # strip pointers + gmalloc banner so runs are comparable
  sed -E -e 's/0x[0-9a-fA-F]+/<PTR>/g' -e '/GuardMalloc/d' -e '/malloc.*stack logging/d'
}

# Native reference binary: compile ALL project .c sources listed in the cdb
# into one binary (the test TU supplies main()). Include dirs are derived
# from the source tree. If it does not link/run, both A/B legs are N/A.
build_native() {
  local bin="${OUT}/native.bin"
  mapfile -t CS < <(python3 - "$CDB" <<'PY'
import json,os,sys
d=json.load(open(sys.argv[1]))
seen=[]
for e in d:
    f=e.get("file")
    dirc=e.get("directory",".")
    p=f if os.path.isabs(f) else os.path.join(dirc,f)
    if p not in seen: seen.append(p)
print("\n".join(seen))
PY
)
  [ "${#CS[@]}" -gt 0 ] || { echo "no-sources"; return 1; }
  # Include dirs = the unique parent dirs of every source + their `include`/`src` siblings.
  local incs=(); local seen_i=""
  for s in "${CS[@]}"; do
    local sd; sd="$(dirname "$s")"
    case " $seen_i " in *" $sd "*) ;; *) incs+=("-I" "$sd"); seen_i+=" $sd";; esac
  done
  [ -d "${C_DIR}/include" ] && incs+=("-I" "${C_DIR}/include")
  [ -d "${C_DIR}/src" ] && incs+=("-I" "${C_DIR}/src")
  incs+=("-I" "$C_DIR")
  if run_bounded "$COMPILE_TIMEOUT" "$CC" -O0 -w "${incs[@]}" "${CS[@]}" -o "$bin" >>"$LOG" 2>&1; then
    echo "$bin"; return 0
  fi
  echo "native-link-failed"; return 1
}

NATIVE_BIN=""
nb="$(build_native)" && NATIVE_BIN="$nb" || { ROW[ab_note]="native:${nb}"; log "native A/B baseline unavailable: $nb"; }

if [ -n "$NATIVE_BIN" ] && [ -x "$NATIVE_BIN" ]; then
  # Run each program from a scratch dir so any side-effect files it writes
  # (e.g. a test that dumps `foo.out`) land there, never in the caller's CWD.
  ABRUN="${OUT}/abrun"; mkdir -p "$ABRUN"
  ( cd "$ABRUN" && run_bounded "$AB_TIMEOUT" "$NATIVE_BIN" ) >"${OUT}/native.out" 2>"${OUT}/native.err"; ncode=$?
  normalize <"${OUT}/native.out" >"${OUT}/native.out.n"
  normalize <"${OUT}/native.err" >"${OUT}/native.err.n"

  # stage3: transpiled C++ binary = link all emitted .cpp objects.
  if [ "$n_cpp_ok" -eq "$n_cpp" ] && [ "$n_cpp" -gt 0 ]; then
    objs=(); for f in "${CPP_FILES[@]}"; do [ -f "$f.o" ] && objs+=("$f.o"); done
    if run_bounded "$COMPILE_TIMEOUT" "$CXX" -std=c++26 -stdlib=libc++ "${objs[@]}" \
         -o "${OUT}/transpiled_cpp.bin" >>"$LOG" 2>&1; then
      ( cd "$ABRUN" && run_bounded "$AB_TIMEOUT" "${OUT}/transpiled_cpp.bin" ) >"${OUT}/tcpp.out" 2>"${OUT}/tcpp.err"; tcode=$?
      normalize <"${OUT}/tcpp.out" >"${OUT}/tcpp.out.n"
      normalize <"${OUT}/tcpp.err" >"${OUT}/tcpp.err.n"
      if [ "$ncode" -eq "$tcode" ] && diff -q "${OUT}/native.out.n" "${OUT}/tcpp.out.n" >/dev/null \
           && diff -q "${OUT}/native.err.n" "${OUT}/tcpp.err.n" >/dev/null; then
        ROW[ab_cpp]="pass"
      else
        ROW[ab_cpp]="fail"
      fi
    else
      ROW[ab_cpp]="na"; ROW[ab_note]="${ROW[ab_note]} cpp:link-failed"
    fi
  else
    ROW[ab_cpp]="na"; ROW[ab_note]="${ROW[ab_note]} cpp:not-all-compiled"
  fi

  # stage6: transpiled Rust binary = per-crate staticlib, linked via cc.
  if [ "$n_rust_ok" -eq "$n_rust" ] && [ "$n_rust" -gt 0 ]; then
    rlibs=(); rok=1; mkdir -p "${OUT}/rustlink"
    for m in "${RUST_MANIFESTS[@]}"; do
      cdir="$(dirname "$m")"; nm="$(basename "$cdir")"
      if run_bounded "$COMPILE_TIMEOUT" "$RUSTC" --edition=2021 --crate-type=staticlib \
           -C panic=abort -C overflow-checks=off "$cdir/src/lib.rs" \
           -o "${OUT}/rustlink/lib${nm}.a" >>"$LOG" 2>&1; then
        rlibs+=("${OUT}/rustlink/lib${nm}.a")
      else rok=0; fi
    done
    if [ "$rok" -eq 1 ] && run_bounded "$COMPILE_TIMEOUT" "$CC" "${rlibs[@]}" \
         -o "${OUT}/transpiled_rust.bin" >>"$LOG" 2>&1; then
      ( cd "$ABRUN" && run_bounded "$AB_TIMEOUT" "${OUT}/transpiled_rust.bin" ) >"${OUT}/trust.out" 2>"${OUT}/trust.err"; rcode=$?
      normalize <"${OUT}/trust.out" >"${OUT}/trust.out.n"
      normalize <"${OUT}/trust.err" >"${OUT}/trust.err.n"
      if [ "$ncode" -eq "$rcode" ] && diff -q "${OUT}/native.out.n" "${OUT}/trust.out.n" >/dev/null \
           && diff -q "${OUT}/native.err.n" "${OUT}/trust.err.n" >/dev/null; then
        ROW[ab_rust]="pass"
      else
        ROW[ab_rust]="fail"
      fi
    else
      ROW[ab_rust]="na"; ROW[ab_note]="${ROW[ab_note]} rust:link-failed"
    fi
  else
    ROW[ab_rust]="na"; ROW[ab_note]="${ROW[ab_note]} rust:not-all-compiled"
  fi
fi

# ---------------------------------------------------------------------------
# pass@1: CRUST-bench official — splice emitted modules under the RBench
# interface, then `cargo test`. Best-effort; the dataset RBench crate is
# COPIED to a scratch workdir (never mutated). Interface reconciliation is
# known-hard, so a compile/link mismatch is recorded as `fail`, and an absent
# RBench crate as `na`.
# ---------------------------------------------------------------------------
if [ -d "$R_DIR" ] && [ "$n_rust" -gt 0 ]; then
  P1="${OUT}/pass1"; rm -rf "$P1"; mkdir -p "$P1"
  cp -R "$R_DIR"/. "$P1"/ 2>/dev/null
  # Splice: for each emitted crate module whose name matches an interface
  # module file, overwrite that interface stub with the emitted implementation.
  spliced=0
  if [ -d "${P1}/src/interfaces" ]; then
    for m in "${RUST_MANIFESTS[@]}"; do
      cdir="$(dirname "$m")"; nm="$(basename "$cdir")"
      if [ -f "${P1}/src/interfaces/${nm}.rs" ] && [ -f "${cdir}/src/lib.rs" ]; then
        cp "${cdir}/src/lib.rs" "${P1}/src/interfaces/${nm}.rs"; spliced=$((spliced+1))
      fi
    done
  fi
  if [ "$spliced" -gt 0 ]; then
    if run_bounded "$PASS1_TIMEOUT" env CARGO_TERM_COLOR=never \
         CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
         CARGO_TARGET_DIR="${P1}/target" "$CARGO" test \
         --manifest-path "${P1}/Cargo.toml" >>"$LOG" 2>&1; then
      ROW[pass1]="pass"
    else
      ROW[pass1]="fail"; ROW[pass1_note]="cargo-test-failed(spliced=${spliced})"
    fi
  else
    ROW[pass1]="na"; ROW[pass1_note]="no-interface-module-match"
  fi
else
  ROW[pass1]="na"; ROW[pass1_note]="no-rbench-or-no-rust"
fi

emit_row
exit 0
