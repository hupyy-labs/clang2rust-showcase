#!/usr/bin/env bash
#
# run_crust_project.sh <project> — run ONE CRUST-bench C project through the
# same 6-stage differential process as SQLite, plus the two test oracles and
# the per-operation unsafe-SITE census, and emit a single honest funnel row.
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
#   stage4  C -> Rust    (cpp2rust --emit=rust)
#   stage5  build Rust   (rustc --crate-type=lib --emit=obj, per crate)
#   stage6  A/B          native-C binary vs transpiled-Rust binary (best-effort)
#   pass@1  CRUST-bench official: splice emitted crate under the RBench
#           interface -> `cargo test` (best-effort)
#   sites   C-initial unsafe sites (cpp2rust --emit=funnel-ingest) vs
#           Rust-resulting unsafe sites (extended unsafe_census), per family.
#
# The native-vs-transpiled A/B links the emitted per-TU objects into one
# binary. For multi-TU projects this frequently fails (cross-TU C++ name
# mangling; unresolved compiler-builtin FFI on the Rust side) — those are
# recorded as `na(<reason>)`, honestly, NOT as a pass or a silent drop.
#
# Output: one tab-separated key=value line to `<results>/<project>.tsv`, and a
# full log to `<results>/<project>/driver.log`. The row's schema is consumed
# by generate_report.py (site-granular columns).
#
# Env (all have defaults; the orchestrator sets the first three):
#   TRANSPILER          cpp2rust binary   (freshly built in the worktree)
#   UNSAFE_CENSUS_BIN   unsafe_census binary (extended, operation-level)
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
UNSAFE_CENSUS_BIN="${UNSAFE_CENSUS_BIN:-${SCRIPT_DIR}/../../cpp-to-rust/rust/target/release/unsafe_census}"

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
ROW[c_raw_ptr_deref]=0; ROW[c_static_mut]=0; ROW[c_union_member]=0; ROW[c_unchecked_arith]=0
ROW[c_sites]=0; ROW[c_total_exprs]=0
ROW[r_raw_ptr_deref]=0; ROW[r_extern_unsafe_call]=0; ROW[r_first_party_call]=0; ROW[r_intrinsic_call]=0; ROW[r_boundary_reborrow]=0; ROW[r_static_mut]=0; ROW[r_union_read]=0
ROW[r_transmute]=0; ROW[r_inline_asm]=0; ROW[r_unchecked_arith]=0; ROW[r_unsafe_blocks]=0
ROW[r_sites]=0; ROW[rust_exprs]=0
ROW[note]=""
# --- two-mode faithful (non-safe) emission: NEW f_* site keys (contract §1/§3) ---
ROW[f_raw_ptr_deref]=0; ROW[f_extern_unsafe_call]=0; ROW[f_boundary_reborrow]=0; ROW[f_static_mut]=0; ROW[f_union_read]=0
ROW[f_transmute]=0; ROW[f_inline_asm]=0; ROW[f_sites]=0; ROW[f_total_exprs]=0
# --- per-function metrics (contract §4) ---
ROW[total_fns]=0; ROW[unsafe_fns_safe]=0; ROW[unsafe_fns_faithful]=0; ROW[fns_made_safe]=0
# --- both-mode parse gate + best-effort faithful build (contract §5/§10) ---
ROW[safe_parse_errors]=0; ROW[faithful_parse_errors]=0
ROW[compiled_rust_faithful]="n/a"

emit_row() {
  local out="" k
  for k in project tus transpiled_cpp cpp_crates compiled_cpp transpiled_rust rust_crates \
           compiled_rust ab_cpp ab_rust pass1 ab_note pass1_note \
           c_raw_ptr_deref c_static_mut c_union_member c_unchecked_arith c_sites c_total_exprs \
           r_raw_ptr_deref r_extern_unsafe_call r_first_party_call r_intrinsic_call r_boundary_reborrow r_static_mut r_union_read r_transmute \
           r_inline_asm r_unchecked_arith r_unsafe_blocks r_sites rust_exprs note \
           f_raw_ptr_deref f_extern_unsafe_call f_boundary_reborrow f_static_mut f_union_read f_transmute f_inline_asm \
           f_sites f_total_exprs \
           total_fns unsafe_fns_safe unsafe_fns_faithful fns_made_safe \
           safe_parse_errors faithful_parse_errors compiled_rust_faithful; do
    out+="${k}=${ROW[$k]}"$'\t'
  done
  printf '%s\n' "${out%$'\t'}" >"$TSV"
  log "row: $(cat "$TSV")"
}

sum_key() { # sum_key <logfile> <key> -> total across all matching lines
  grep -hoE "$2=[0-9]+" "$1" 2>/dev/null | awk -F= '{s+=$2} END{print s+0}'
}

# region_metrics <safe_census> <faithful_census> -> "total_fns unsafe_safe unsafe_faithful made_safe"
# Per-function safety (contract §4): the 6-family site_total is bucketed by census
# region LINE (never by distinct region string — same-named methods must count
# separately); `fns_made_safe` is the region-key JOIN (faithful>0 AND safe==0).
region_metrics() {
  python3 - "$1" "$2" <<'PY'
import sys
FAMS = ("raw_ptr_deref", "extern_unsafe_call", "static_mut",
        "union_read", "transmute", "inline_asm")
def load(path):
    lines = []
    try:
        with open(path, encoding="utf-8") as f:
            for ln in f:
                if "region=" not in ln:
                    continue
                kv = dict(p.split("=", 1) for p in ln.split() if "=" in p)
                site = sum(int(kv.get(k, 0)) for k in FAMS)
                lines.append((kv.get("region", ""), site))
    except OSError:
        pass
    return lines
safe = load(sys.argv[1])
faith = load(sys.argv[2])
total_fns = len(safe)                                   # bucket by LINE
unsafe_safe = sum(1 for _, s in safe if s > 0)
unsafe_faith = sum(1 for _, s in faith if s > 0)
safe_d = {r: s for r, s in safe}                        # region-key join
faith_d = {r: s for r, s in faith}
made = sum(1 for r, s in faith_d.items() if s > 0 and safe_d.get(r, 0) == 0)
print(total_fns, unsafe_safe, unsafe_faith, made)
PY
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

# --- sites: C-initial unsafe operation census (pre-lowering Clang AST) ---
FUNNEL_C="${OUT}/funnel_c.log"
run_bounded "$TRANSPILE_TIMEOUT" "$TRANSPILER" --cdb "$CDB" --emit=funnel-ingest >"$FUNNEL_C" 2>>"$LOG"
ROW[c_raw_ptr_deref]="$(sum_key "$FUNNEL_C" raw_ptr_deref)"
ROW[c_static_mut]="$(sum_key "$FUNNEL_C" static_mut)"
ROW[c_union_member]="$(sum_key "$FUNNEL_C" union_member)"
ROW[c_unchecked_arith]="$(sum_key "$FUNNEL_C" unchecked_arith)"
ROW[c_total_exprs]="$(sum_key "$FUNNEL_C" total_exprs)"
# "unsafe sites" total EXCLUDES the separate unchecked_arith (pointer-arith) lane.
ROW[c_sites]=$(( ROW[c_raw_ptr_deref] + ROW[c_static_mut] + ROW[c_union_member] ))
log "C sites=${ROW[c_sites]} (deref=${ROW[c_raw_ptr_deref]} static=${ROW[c_static_mut]} union=${ROW[c_union_member]} arith=${ROW[c_unchecked_arith]})"

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

# --- sites: Rust-resulting unsafe operation census (extended unsafe_census) ---
FUNNEL_R="${OUT}/funnel_rust.log"
"$UNSAFE_CENSUS_BIN" "$RUST_OUT" >"$FUNNEL_R" 2>>"$LOG"
ROW[r_raw_ptr_deref]="$(sum_key "$FUNNEL_R" raw_ptr_deref)"
ROW[r_extern_unsafe_call]="$(sum_key "$FUNNEL_R" extern_unsafe_call)"
ROW[r_first_party_call]="$(sum_key "$FUNNEL_R" first_party_call)"
ROW[r_intrinsic_call]="$(sum_key "$FUNNEL_R" intrinsic_call)"
ROW[r_boundary_reborrow]="$(sum_key "$FUNNEL_R" boundary_reborrow)"
ROW[r_static_mut]="$(sum_key "$FUNNEL_R" static_mut)"
ROW[r_union_read]="$(sum_key "$FUNNEL_R" union_read)"
ROW[r_transmute]="$(sum_key "$FUNNEL_R" transmute)"
ROW[r_inline_asm]="$(sum_key "$FUNNEL_R" inline_asm)"
ROW[r_unchecked_arith]="$(sum_key "$FUNNEL_R" unchecked_arith)"
ROW[r_unsafe_blocks]="$(sum_key "$FUNNEL_R" unsafe_blocks)"
ROW[rust_exprs]="$(sum_key "$FUNNEL_R" total_exprs)"
ROW[r_sites]=$(( ROW[r_raw_ptr_deref] + ROW[r_extern_unsafe_call] + ROW[r_static_mut] \
               + ROW[r_union_read] + ROW[r_transmute] + ROW[r_inline_asm] ))
ROW[safe_parse_errors]="$(sum_key "$FUNNEL_R" parse_errors)"
log "Rust sites=${ROW[r_sites]} exprs=${ROW[rust_exprs]} parse_errors=${ROW[safe_parse_errors]}"

# --- stage4b: C -> Rust — FAITHFUL (lab factory, all uplift segments dropped) ---
# Contract §1: SAME casing (do NOT set C2R_RUSTIC_CASING=0) so region keys join
# 1:1 with the safe census. f_* keys are the 6-family site census of THIS crate.
FAITHFUL_OUT="${OUT}/rust_faithful"
rm -rf "$FAITHFUL_OUT"; mkdir -p "$FAITHFUL_OUT"
run_bounded "$TRANSPILE_TIMEOUT" env C2R_LAB_FACTORY=1 C2R_LAB_DROP_POINTER=1 \
    C2R_LAB_DROP_ALLOC=1 C2R_LAB_DROP_PRINTF=1 C2R_LAB_DROP_CSTRING_GLOBAL=1 \
    "$TRANSPILER" --cdb "$CDB" --out-dir "$FAITHFUL_OUT" --emit=rust >>"$LOG" 2>&1

FUNNEL_F="${OUT}/funnel_rust_faithful.log"
"$UNSAFE_CENSUS_BIN" "$FAITHFUL_OUT" >"$FUNNEL_F" 2>>"$LOG"
ROW[f_raw_ptr_deref]="$(sum_key "$FUNNEL_F" raw_ptr_deref)"
ROW[f_extern_unsafe_call]="$(sum_key "$FUNNEL_F" extern_unsafe_call)"
ROW[f_boundary_reborrow]="$(sum_key "$FUNNEL_F" boundary_reborrow)"
ROW[f_static_mut]="$(sum_key "$FUNNEL_F" static_mut)"
ROW[f_union_read]="$(sum_key "$FUNNEL_F" union_read)"
ROW[f_transmute]="$(sum_key "$FUNNEL_F" transmute)"
ROW[f_inline_asm]="$(sum_key "$FUNNEL_F" inline_asm)"
ROW[f_total_exprs]="$(sum_key "$FUNNEL_F" total_exprs)"
ROW[f_sites]=$(( ROW[f_raw_ptr_deref] + ROW[f_extern_unsafe_call] + ROW[f_static_mut] \
               + ROW[f_union_read] + ROW[f_transmute] + ROW[f_inline_asm] ))
ROW[faithful_parse_errors]="$(sum_key "$FUNNEL_F" parse_errors)"
log "Faithful sites=${ROW[f_sites]} exprs=${ROW[f_total_exprs]} parse_errors=${ROW[faithful_parse_errors]}"

# --- per-function metrics (contract §4): line-bucketed counts + region-key join ---
read -r _tf _usafe _ufaith _made < <(region_metrics "$FUNNEL_R" "$FUNNEL_F")
ROW[total_fns]="${_tf:-0}"
ROW[unsafe_fns_safe]="${_usafe:-0}"
ROW[unsafe_fns_faithful]="${_ufaith:-0}"
ROW[fns_made_safe]="${_made:-0}"
log "fns: total=${ROW[total_fns]} unsafe_safe=${ROW[unsafe_fns_safe]} unsafe_faithful=${ROW[unsafe_fns_faithful]} made_safe=${ROW[fns_made_safe]}"

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
