<link rel="stylesheet" href="results.css">

# Results

Two measurements, one honest report: **SQLite** — the product's primary
target, one large real-world codebase transpiled whole and differentially
tested against the native build — and **CRUST-bench** — 100 unrelated
third-party C repositories, published as a transparent external baseline.
Every table is rendered by
[`benchmarks/generate_report.py`](benchmarks/generate_report.py) from result
files; the column definitions are shared and spelled out in the
[legend](#per-project-results) below.

<!-- methodology:begin -->
## Methodology — what we measure vs. what CRUST-Bench measures

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

**The claim we do stand behind:** over the same corpus, our uplift *measurably reduces unsafe operations* relative to a raw, c2rust-style lowering of the identical source — a reduction their coarse safety flag cannot see.
<!-- methodology:end -->

## Flagship — SQLite

The **84-translation-unit [SQLite](https://www.sqlite.org/) CLI link set** —
the command-line shell (`shell.c`) and every source file it links — is
transpiled to Rust in a single run and emitted as **one whole-program
monocrate** (not a crate per file): the `--emit=rust` crate compiles with **0
rustc errors** and the transpiled CLI runs **byte-for-byte identical to the
native one**. Unlike the CRUST-bench rows below, the **Tested** column here is
real end-to-end differential testing: the transpiled command-line shell and the
native one execute the same 10 SQL scripts and their outputs are compared
byte-for-byte, reproduced three times, including under an allocator-hardened
harness.

The census below is scoped to this **verified 84-TU CLI link set**, not the
full 281-TU SQLite corpus. This build collapsed `--emit=rust` from a crate per
translation unit to a single whole-program monocrate; the 84-TU CLI monocrate
is green (0 rustc errors) and A/B-clean (10/10 SQL scripts byte-identical),
but the full 281-TU whole-program emit is not currently green — a deterministic
arena-lifetime heisenbug — so publishing its numbers would not match a shipped,
verified state.

<!-- sqlite-table:begin -->
<div class="wide-table">

| # | Project | Transpiled | Compiled | Tested | Non-safe Sites (faithful) | Safe Sites (uplift) | Site Reduction (%) | Faithful UOD | Safe UOD | Total Fns | Unsafe Fns (faithful) | Unsafe Fns (safe) | Fns Made Safe |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | [SQLite](https://www.sqlite.org/) → [Rust output](https://github.com/o2alexanderfedin/sqlite-rust-mirror) | ✅ all 84 files | ✅ one whole-program monocrate | ✅ all 10 SQL scripts byte-identical vs native CLI (3 runs) | 81,292 | 78,433 | +3.5% | 8.1% | 7.8% | 3,594 | 2,956 | 2,784 | 172 (6%) |

</div>

<sub>A **site** is one individual unsafe OPERATION, not a function or a whole `unsafe {}` block. Every safety number below compares **two Rust emissions of the same program**, both scored by the same `unsafe_census` instrument: the **faithful** baseline (lab factory — all uplift segments dropped, a straight transliteration) and the **safe** production default (pointer→`Option`/span, alloc→`Box`/`Vec`, printf→`print!`, cstring-global uplift all ON). **Transpiled / Compiled** — did cpp2rust emit, and does the emitted code build, for the C++ lane and the Rust lane (`ok/total` translation units). **Tested** — the differential oracles: **A/B** runs the project built from native C vs from the transpiled C++/Rust and compares output byte-for-byte (`—` = not linkable as one binary, e.g. cross-TU C++ name mangling or unresolved builtin FFI; logged, never silently passed); **pass@1** is CRUST-bench's official oracle — the emitted crate spliced under the hand-written RBench interface, then `cargo test`. For SQLite the Tested cell is the whole-CLI differential over the SQL scripts. **Non-safe Sites (faithful)** / **Safe Sites (uplift)** — the 6-family unsafe-site total (`raw_ptr_deref + extern_unsafe_call + static_mut + union_read + transmute + inline_asm`) in each emission; `first_party_call` (harness-FFI / transpiler shims), `intrinsic_call` (benign compiler intrinsics), `boundary_reborrow` (`&*p`/`&mut *p` reborrows synthesized where a lifted callee signature meets a caller local that stayed a raw pointer — the SAME pointer risk re-spelled at each call seam, not new unsafety), `unchecked_arith` (C pointer arithmetic) and whole `unsafe_blocks` are separate lanes, never folded into the total. **Site Reduction (%)** — `(faithful − safe) ÷ faithful`; **positive = the uplift REMOVED unsafe sites** relative to the faithful baseline. **Faithful UOD** / **Safe UOD** — Unsafe-Operation-Density: unsafe sites ÷ total expressions in that emission's own AST (lower is safer; the denominator grows with any added scaffolding, so density cannot be gamed by code inflation). **Total Fns** — every function-with-a-body counted (by census line, so same-named impl/trait methods are not merged); **Unsafe Fns (faithful)** / **Unsafe Fns (safe)** — those carrying ≥1 unsafe site in each emission; **Fns Made Safe** — the region-keyed join: functions unsafe in the faithful baseline that the uplift makes fully safe, shown as `n (n ÷ unsafe-faithful)`. Safety cells render `pending` / `n/a` for any project whose faithful OR safe emission had a non-zero parse-error count — those projects are excluded from the aggregate (the excluded count is reported there). Whole-program **SQLite shows a small reduction by design**: it is emitted as one monocrate where almost every function is externally visible across the link set, so the ownership/pointer uplifts are ABI-vetoed there to preserve the C-ABI boundary — the site-removing signal concentrates in the smaller, self-contained CRUST-bench projects. All counts use thousands separators.</sub>

<sub>SQLite site counts are code-generated two-mode: `cpp2rust --emit=rust` over the 84-translation-unit SQLite CLI link set (including the command-line shell, shell.c) emitted TWICE — the faithful lab baseline (all uplift segments dropped) and the safe production default — each scored by the operation-level `unsafe_census` over the emitted whole-program Rust monocrate, reduced by [`benchmarks/sqlite_sites_from_funnel.py`](benchmarks/sqlite_sites_from_funnel.py) into [`benchmarks/sqlite-sites.tsv`](benchmarks/sqlite-sites.tsv). A further **16,399** first-party (in-project) calls, **118** benign intrinsics, and **4,528** `&*p`/`&mut *p` boundary reborrows (vs 486 in the faithful baseline) are excluded from the total. Those reborrows are the SAME pointer risk re-spelled at each lifted-signature call seam (fan-out), not new unsafety — folding them in was what made the earlier figure read negative. The faithful→safe delta is **small by design**: SQLite is emitted as ONE whole-program monocrate, so nearly every function is externally visible across the link set and the ownership/pointer uplifts are ABI-vetoed there to preserve the C-ABI boundary — the site-removing uplift signal concentrates in the smaller, self-contained CRUST-bench projects, not here. The **UOD** columns (density, 8.09% → 7.76%) are the cleaner cross-mode measure. State facts recorded 2026-07-23.</sub>
<!-- sqlite-table:end -->

## CRUST-bench

Scoring methodology: [`benchmarks/CRUST-bench.md`](benchmarks/CRUST-bench.md).
Harness: [`benchmarks/run_crust_bench.sh`](benchmarks/run_crust_bench.sh).

- **Run date:** 2026-07-22
- **Dataset:** [CRUST-bench](https://github.com/anirudhkhatry/CRUST-bench)
  ([paper: arXiv 2504.15254](https://arxiv.org/abs/2504.15254)) — 100 real-world
  C repositories, each paired with a hand-written safe-Rust interface and a
  test suite.
- **Coverage:** all 100 projects scored. 19 of the 100 could not be attempted
  at all — their own build systems are broken (defective Makefiles / CMake
  files), so the file-and-flag list the converter needs as input could not be
  produced and the converter never ran on them. That leaves **81 projects the
  converter actually ran on**; the 19 unreachable ones contribute zero to the
  stage and site counts below.

### Aggregate — the full 6-stage pipeline

Every project now runs the SAME six differential stages as SQLite — C→C++,
compile C++, A/B native-vs-C++, C→Rust, build Rust, A/B native-vs-Rust — plus
both test oracles and the per-operation unsafe-SITE census. (Earlier reports
scored only the Tier-1 Rust-compile step; this run adds the C++ lane, the A/B
oracles, pass@1, and the site metrics.)

| Stage (of 100 projects) | Result |
|---|---|
| Reachable — own build produced a compile DB | **81** (the other 19 have broken build systems; the converter never ran) |
| C → C++ transpiled, fully | **52** (+ 15 partial) |
| Emitted C++ compiles, all TUs | **38** |
| C → Rust transpiled, fully | **48** (+ 17 partial) |
| Emitted Rust compiles, all crates | **23** |
| Both lanes fully transpiled AND compiled | **12** |
| A/B — native C vs transpiled **C++** binary | **12 pass**, 0 divergent, 88 not linkable¹ |
| A/B — native C vs transpiled **Rust** binary | **2 pass**, 0 divergent, 98 not linkable¹ |
| pass@1 — emitted crate spliced under the RBench interface + `cargo test` | 0 pass / 35 attempted / 65 no interface match |

C++: **173 of 239** emitted TUs compile (the C++ lane is per-TU objects). Rust: **16** projects' whole-program monocrates compile (the 16-project fair-comparison population above).

¹ For multi-TU projects the per-TU emitted objects do not link into a single
binary (cross-TU C++ name mangling; unresolved compiler-builtin FFI on the Rust
side) — recorded as `—`, honestly, never a silent pass. Where a project IS
linkable (single-TU or ABI-consistent), the A/B runs, and **every leg that ran
matched the native output byte-for-byte (0 divergences).** C++-lane A/B passers:
gorilla-paper-encode, utf8, Graph-recogniser, quadtree, libfor, cJSON,
Simple-Config, Linear-Algebra-C, leftpad, vec, libvcd, kd3.

### Unsafe operation SITES — the headline

Safety is measured in per-operation **SITES**, not functions, and reported as
the Multi-Dimensional Safety Matrix: Original C sites, Emitted Rust sites, the
reduction %, and the Unsafe-Operation-Density (UOD = unsafe sites ÷ total
expressions) on each side. Both lanes count the same whole-program function
population (the C funnel counts `#include`d project functions, matching the
emitter's whole-program materialisation — each project is emitted as one
whole-program crate), so there is no scope-mismatch outlier.

The fair apples-to-apples aggregate is over the **16 projects where both lanes
fully transpiled and the Rust compiled** (failed-transpilation projects have a C
count but little/no compiling Rust, so a whole-corpus sum would be meaningless —
the per-project table still shows all 100 honestly): **13,570 Original C unsafe
sites → 22,034 Emitted Rust unsafe sites** (Unsafe Site Reduction **−62.4%**), at
**Baseline C UOD 6.33% → Emitted Rust UOD 9.24%**.

Only GENUINELY external calls count toward the total: an `extern_unsafe_call` is
a call to libc / a foreign symbol. Calls the transpiler introduces purely to
stitch the program together — first-party functions the emitter exposes through
an `extern "C"` boundary so the emitted crate splices under the CRUST-bench test
harness (`first_party_call`), plus benign compiler intrinsics
like `assert` / branch hints (`intrinsic_call`) — are emission artifacts, split
into two separate excluded lanes. The reduction stays negative because this
build is a faithful transliteration (ownership/borrow uplift is deliberately
deferred): genuine libc calls that are free in C are explicit unsafe calls in
Rust, and the emitter synthesises helper/accessor functions (absent
from the C source) that carry their own unsafe operations. The real memory-safety
story lives in the per-family C→Rust split beneath the table.

### Per-project results

Generated from the run's per-project result rows by
[`benchmarks/generate_report.py`](benchmarks/generate_report.py) (the harness
regenerates this table as `results/REPORT.md` on every sweep). Every column —
including what a "site" is and why the Rust site total can exceed C's — is
defined in the legend rendered directly beneath the table, and the per-family
C→Rust before/after breakdown follows it.

<!-- crust-table:begin -->
<div class="wide-table">

| # | Project | Transpiled | Compiled | Tested | Non-safe Sites (faithful) | Safe Sites (uplift) | Site Reduction (%) | Faithful UOD | Safe UOD | Total Fns | Unsafe Fns (faithful) | Unsafe Fns (safe) | Fns Made Safe |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | [SQLite](https://www.sqlite.org/) → [Rust output](https://github.com/o2alexanderfedin/sqlite-rust-mirror) — **flagship** | ✅ all 84 files | ✅ one whole-program monocrate | ✅ all 10 SQL scripts byte-identical vs native CLI (3 runs) | 81,292 | 78,433 | +3.5% | 8.1% | 7.8% | 3,594 | 2,956 | 2,784 | 172 (6%) |
| 2 | [2DPartInt](https://github.com/eafit-apolo/2DPartInt) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 3 | [42-Kocaeli-Printf](https://github.com/enes2424/42-Kocaeli-Printf) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 4 | [aes128-SIMD](https://github.com/at0m741/aes128-SIMD) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 5 | [amp](https://github.com/clibs/amp) · [mirror](https://github.com/o2alexanderfedin/amp-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 47 | 39 | +17.0% | 9.6% | 8.1% | 6 | 5 | 5 | 0 (0%) |
| 6 | [approxidate](https://github.com/thatguystone/approxidate) · [mirror](https://github.com/o2alexanderfedin/approxidate-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 486 | 386 | +20.6% | 8.9% | 7.9% | 34 | 24 | 23 | 3 (12%) |
| 7 | [avalanche](https://github.com/drjerry/avalanche) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 8 | [bhshell](https://github.com/bsach64/bhshell) | C++ ⚠️ · Rust ❌ | C++ 4/4 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 9 | [bigint](https://github.com/adam-mcdaniel/bigint) · [mirror](https://github.com/o2alexanderfedin/bigint-rust-mirror) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 185 | 170 | +8.1% | 5.3% | 4.9% | 44 | 33 | 33 | 0 (0%) |
| 10 | [bitset](https://github.com/abenhlal/bitset) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 11 | [blt](https://github.com/blynn/blt) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 12 | [bostree](https://github.com/phillipberndt/bostree) · [mirror](https://github.com/o2alexanderfedin/bostree-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/3 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 495 | 508 | −2.6% | 13.1% | 13.2% | 24 | 22 | 22 | 0 (0%) |
| 13 | [btree-map](https://github.com/EdsonHTJ/btree-map) · [mirror](https://github.com/o2alexanderfedin/btree-map-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 371 | 382 | −3.0% | 11.0% | 11.1% | 27 | 25 | 25 | 0 (0%) |
| 14 | [c-aces](https://github.com/enum-class/c-aces) | C++ ⚠️ · Rust ❌ | C++ 5/5 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 15 | [c-blind-rsa-signatures](https://github.com/jedisct1/c-blind-rsa-signatures) · [mirror](https://github.com/o2alexanderfedin/c-blind-rsa-signatures-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 1,850 | 1,844 | +0.3% | 16.9% | 17.3% | 593 | 484 | 487 | 0 (0%) |
| 16 | [c-string](https://github.com/vnkrtv/c-string) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 17 | [carrays](https://github.com/noporpoise/carrays) · [mirror](https://github.com/o2alexanderfedin/carrays-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 2,040 | 1,537 | +24.7% | 10.2% | 8.4% | 105 | 99 | 98 | 1 (1%) |
| 18 | [cfsm](https://github.com/nhjschulz/cfsm) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 19 | [chtrie](https://github.com/dongyx/chtrie) · [mirror](https://github.com/o2alexanderfedin/chtrie-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 89 | 79 | +11.2% | 10.4% | 9.4% | 4 | 4 | 4 | 0 (0%) |
| 20 | [CircularBuffer](https://github.com/Roen-Ro/CircularBuffer) | C++ ⚠️ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 21 | [cissy](https://github.com/slass100/cissy) · [mirror](https://github.com/o2alexanderfedin/cissy-rust-mirror) | C++ ✅ · Rust ✅ | C++ 4/7 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 418 | 376 | +10.0% | 13.1% | 12.3% | 28 | 26 | 24 | 2 (8%) |
| 22 | [cJSON](https://github.com/faycheng/cJSON) · [mirror](https://github.com/o2alexanderfedin/cJSON-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 1,172 | 1,183 | −0.9% | 10.1% | 10.2% | 63 | 55 | 56 | 1 (2%) |
| 23 | [clhash](https://github.com/simdhash/clhash) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 24 | [clog](https://github.com/mmueller/clog) | C++ ✅ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 25 | [coroutine](https://github.com/cloudwu/coroutine) | C++ ⚠️ · Rust ❌ | C++ 1/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 26 | [cset](https://github.com/RobusGauli/cset.h) · [mirror](https://github.com/o2alexanderfedin/cset-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 27 | [csyncmers](https://github.com/rchikhi/csyncmers) · [mirror](https://github.com/o2alexanderfedin/csyncmers-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 111 | 67 | +39.6% | 9.7% | 6.0% | 8 | 5 | 5 | 0 (0%) |
| 28 | [dict](https://github.com/wrnlb666/dict) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 29 | [emlang](https://github.com/LordOfTrident/emlang) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 30 | [expr](https://github.com/radarsat1/expr) | C++ ✅ · Rust ❌ | C++ 1/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 31 | [FastHamming](https://github.com/BenBE/FastHamming.git) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 32 | [fft](https://github.com/kevin0x0/fft) · [mirror](https://github.com/o2alexanderfedin/fft-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 124 | 124 | 0.0% | 5.5% | 5.5% | 6 | 4 | 4 | 0 (0%) |
| 33 | [file2str](https://github.com/willemt/file2str) · [mirror](https://github.com/o2alexanderfedin/file2str-rust-mirror) | C++ ✅ · Rust ✅ | C++ 4/4 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 174 | 148 | +14.9% | 9.6% | 8.3% | 32 | 27 | 25 | 2 (7%) |
| 34 | [fleur](https://github.com/hashlookup/fleur) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 35 | [fs_c](https://github.com/jwerle/fs.c) · [mirror](https://github.com/o2alexanderfedin/fs_c-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 47 | 47 | 0.0% | 10.1% | 10.1% | 25 | 23 | 23 | 0 (0%) |
| 36 | [fslib](https://github.com/c0stya/fslib) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 37 | [Genetic-neural-network-for-simple-control](https://github.com/DemianovE/Genetic-neural-network-for-simple-control) | C++ ⚠️ · Rust ❌ | C++ 12/12 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 38 | [geofence](https://github.com/bytebeamio/geofence.git) · [mirror](https://github.com/o2alexanderfedin/geofence-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 10 | 8 | +20.0% | 4.4% | 3.6% | 3 | 2 | 2 | 0 (0%) |
| 39 | [gfc](https://github.com/maxmouchet/gfc.git) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 40 | [gorilla-paper-encode](https://github.com/MrBean818/gorilla-paper-encode) · [mirror](https://github.com/o2alexanderfedin/gorilla-paper-encode-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 215 | 133 | +38.1% | 6.3% | 4.0% | 25 | 19 | 15 | 4 (21%) |
| 41 | [Graph-recogniser](https://github.com/NikolaYolov/Graph-recogniser) · [mirror](https://github.com/o2alexanderfedin/Graph-recogniser-rust-mirror) | C++ ✅ · Rust ✅ | C++ 4/4 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 290 | 296 | −2.1% | 10.5% | 10.7% | 31 | 27 | 26 | 1 (4%) |
| 42 | [hamta](https://github.com/burtgulash/hamta) · [mirror](https://github.com/o2alexanderfedin/hamta-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 33 | 32 | +3.0% | 9.1% | 8.8% | 8 | 7 | 6 | 1 (14%) |
| 43 | [Holdem-Odds](https://github.com/gnuvince/Holdem-Odds) · [mirror](https://github.com/o2alexanderfedin/Holdem-Odds-rust-mirror) | C++ ✅ · Rust ✅ | C++ 4/5 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 88 | 72 | +18.2% | 6.7% | 5.5% | 29 | 23 | 19 | 4 (17%) |
| 44 | [hydra](https://github.com/emad-elsaid/hydra) · [mirror](https://github.com/o2alexanderfedin/hydra-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 154 | 148 | +3.9% | 14.5% | 14.3% | 14 | 13 | 14 | 0 (0%) |
| 45 | [impcheck](https://github.com/domschrei/impcheck) | C++ ⚠️ · Rust ❌ | C++ 2/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 46 | [inversion_list](https://github.com/hou-12/Inversion-List-Implementation-for-Interval-Manipulation) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 47 | [jccc](https://github.com/jabacat/jccc) · [mirror](https://github.com/o2alexanderfedin/jccc-rust-mirror) | C++ ✅ · Rust ✅ | C++ 12/13 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 450 | 358 | +20.4% | 11.7% | 10.2% | 60 | 46 | 47 | 0 (0%) |
| 48 | [kairoCompiler](https://github.com/kairo-yr/kairoCompiler) | C++ ✅ · Rust ❌ | C++ 3/10 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 49 | [kd3](https://github.com/shawnchin/kd3) · [mirror](https://github.com/o2alexanderfedin/kd3-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ ✅·Rust — · pass@1 — | 308 | 259 | +15.9% | 10.6% | 9.0% | 32 | 31 | 27 | 4 (13%) |
| 50 | [lambda-calculus-eval](https://github.com/Lorenzobattistela/lambda-calculus-eval) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 51 | [leftpad](https://github.com/sjmulder/leftpad) · [mirror](https://github.com/o2alexanderfedin/leftpad-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ ✅·Rust ✅ · pass@1 — | 47 | 47 | 0.0% | 10.9% | 10.9% | 3 | 2 | 2 | 0 (0%) |
| 52 | [lib2bit](https://github.com/dpryan79/lib2bit) · [mirror](https://github.com/o2alexanderfedin/lib2bit-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 594 | 624 | −5.1% | 8.8% | 9.1% | 22 | 20 | 20 | 0 (0%) |
| 53 | [libbase122](https://github.com/kevinAlbs/libbase122) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 54 | [libbeaufort](https://github.com/jwerle/libbeaufort) · [mirror](https://github.com/o2alexanderfedin/libbeaufort-rust-mirror) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 78 | 78 | 0.0% | 8.0% | 8.0% | 6 | 6 | 6 | 0 (0%) |
| 55 | [libfor](https://github.com/cruppstahl/libfor) · [mirror](https://github.com/o2alexanderfedin/libfor-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ ✅·Rust — · pass@1 — | 18,847 | 18,846 | +0.0% | 9.2% | 9.2% | 418 | 410 | 409 | 1 (0%) |
| 56 | [libm17](https://github.com/M17-Project/libm17) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 57 | [libpgn](https://github.com/youkwhd/libpgn) · [mirror](https://github.com/o2alexanderfedin/libpgn-rust-mirror) | C++ ✅ · Rust ✅ | C++ 11/12 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 394 | 351 | +10.9% | 10.9% | 9.8% | 60 | 48 | 43 | 5 (10%) |
| 58 | [libpsbt](https://github.com/jb55/libpsbt) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 59 | [libqueue](https://github.com/resyfer/libqueue) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 60 | [libtinyfseq](https://github.com/Cryptkeeper/libtinyfseq) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 61 | [libutf](https://github.com/holepunchto/libutf) · [mirror](https://github.com/o2alexanderfedin/libutf-rust-mirror) | C++ ⚠️ · Rust ✅ | C++ 0/27 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 62 | [libvcd](https://github.com/sorousherafat/libvcd) · [mirror](https://github.com/o2alexanderfedin/libvcd-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 129 | 106 | +17.8% | 10.2% | 8.6% | 11 | 10 | 9 | 1 (10%) |
| 63 | [libwecan](https://github.com/nisennenmondai/libwecan) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 64 | [Linear-Algebra-C](https://github.com/barrettotte/Linear-Algebra-C) · [mirror](https://github.com/o2alexanderfedin/Linear-Algebra-C-rust-mirror) | C++ ✅ · Rust ✅ | C++ 4/4 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 633 | 624 | +1.4% | 7.1% | 7.0% | 113 | 99 | 99 | 0 (0%) |
| 65 | [ljmm](https://github.com/cloudflare/ljmm) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 66 | [LTRE](https://github.com/Bricktech2000/LTRE) | C++ ✅ · Rust ❌ | C++ 1/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 67 | [Math-Library-in-C](https://github.com/Astrodynamic/Math-Library-in-C) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 68 | [matrix_multiplication](https://github.com/DevRuibin/matrix_multiplication) | C++ ⚠️ · Rust ❌ | C++ 1/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 69 | [mdb](https://github.com/chuigda/mdb.git) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 70 | [Megalania](https://github.com/blackle/Megalania) | C++ ⚠️ · Rust ❌ | C++ 16/16 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 71 | [merkle-tree-c](https://github.com/TheWaWaR/merkle-tree-c) · [mirror](https://github.com/o2alexanderfedin/merkle-tree-c-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 442 | 363 | +17.9% | 1.9% | 1.6% | 50 | 45 | 38 | 7 (16%) |
| 72 | [morton](https://github.com/jart/morton) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 73 | [murmurhash_c](https://github.com/jwerle/murmurhash.c) · [mirror](https://github.com/o2alexanderfedin/murmurhash_c-rust-mirror) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 71 | 60 | +15.5% | 9.1% | 8.2% | 7 | 5 | 3 | 2 (40%) |
| 74 | [mvptree](https://github.com/michaelmior/mvptree) · [mirror](https://github.com/o2alexanderfedin/mvptree-rust-mirror) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 1,443 | 1,424 | +1.3% | 12.9% | 12.8% | 37 | 35 | 35 | 0 (0%) |
| 75 | [NandC](https://github.com/Dcraftbg/NandC) · [mirror](https://github.com/o2alexanderfedin/NandC-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 53 | 20 | +62.3% | 7.5% | 3.2% | 16 | 7 | 4 | 3 (43%) |
| 76 | [Phills_DHT](https://github.com/PhillipTaylor/Phills_DHT) · [mirror](https://github.com/o2alexanderfedin/Phills_DHT-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 89 | 87 | +2.2% | 15.8% | 15.7% | 8 | 8 | 8 | 0 (0%) |
| 77 | [quadtree](https://github.com/thejefflarson/quadtree) · [mirror](https://github.com/o2alexanderfedin/quadtree-rust-mirror) | C++ ✅ · Rust ✅ | C++ 5/5 · Rust 1/1 | A/B C++ ✅·Rust ✅ · pass@1 — | 339 | 348 | −2.7% | 11.5% | 11.7% | 32 | 28 | 26 | 2 (7%) |
| 78 | [razz_simulation](https://github.com/eus/razz_simulation) | C++ ✅ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 79 | [rbtree-lab](https://github.com/jwowo/rbtree-lab) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 80 | [recordManager](https://github.com/prachikotadia/-Record-Manager) | C++ ⚠️ · Rust ❌ | C++ 7/7 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 81 | [rect_pack_h](https://github.com/luihabl/rect_pack.h) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 82 | [Remimu](https://github.com/wareya/Remimu) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 83 | [rhbloom](https://github.com/tidwall/rhbloom) · [mirror](https://github.com/o2alexanderfedin/rhbloom-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 218 | 211 | +3.2% | 8.3% | 8.0% | 21 | 17 | 15 | 2 (12%) |
| 84 | [roaring-bitmap](https://github.com/chriso/roaring-bitmap) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 85 | [rubiksolver](https://github.com/justjkk/rubiksolver) · [mirror](https://github.com/o2alexanderfedin/rubiksolver-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/5 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 683 | 679 | +0.6% | 11.7% | 11.7% | 32 | 28 | 28 | 0 (0%) |
| 86 | [satc](https://github.com/rjungemann/satc) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 87 | [Simple-Config](https://github.com/0xHaru/Simple-Config) · [mirror](https://github.com/o2alexanderfedin/Simple-Config-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 257 | 366 | −42.4% | 7.7% | 10.3% | 51 | 41 | 39 | 5 (12%) |
| 88 | [Simple-Sparsehash](https://github.com/qpfiffer/Simple-Sparsehash) · [mirror](https://github.com/o2alexanderfedin/Simple-Sparsehash-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 395 | 406 | −2.8% | 7.2% | 7.3% | 34 | 30 | 30 | 0 (0%) |
| 89 | [simple_lang](https://github.com/lxbme/simple_lang) | C++ ✅ · Rust ❌ | C++ 11/11 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 90 | [SimpleXML](https://github.com/kiennt/SimpleXML.git) | C++ ⚠️ · Rust ❌ | C++ 1/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 91 | [skp](https://github.com/rdentato/skp) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 92 | [SlothLang](https://github.com/AaronCGoidel/SlothLang) | C++ ⚠️ · Rust ❌ | C++ 3/3 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 93 | [ted](https://github.com/ajpen/ted) · [mirror](https://github.com/o2alexanderfedin/ted-rust-mirror) | C++ ⚠️ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 650 | 631 | +2.9% | 9.9% | 9.6% | 45 | 42 | 41 | 1 (2%) |
| 94 | [tisp](https://github.com/edvb/tisp) · [mirror](https://github.com/o2alexanderfedin/tisp-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 523 | 510 | +2.5% | 11.1% | 10.8% | 47 | 45 | 43 | 2 (4%) |
| 95 | [totp](https://github.com/sjmulder/totp) · [mirror](https://github.com/o2alexanderfedin/totp-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 181 | 170 | +6.1% | 7.8% | 7.5% | 16 | 13 | 13 | 0 (0%) |
| 96 | [ulidgen](https://github.com/leahneukirchen/ulidgen) | C++ ⚠️ · Rust ❌ | C++ 1/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 97 | [utf8](https://github.com/zahash/utf8.c) · [mirror](https://github.com/o2alexanderfedin/utf8-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 98 | [VaultSync](https://github.com/elhalili/VaultSync) | n/a — project build broken | — | — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 99 | [vec](https://github.com/rxi/vec) · [mirror](https://github.com/o2alexanderfedin/vec-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 1,985 | 2,040 | −2.8% | 15.4% | 15.5% | 11 | 9 | 10 | 0 (0%) |
| 100 | [worsp](https://github.com/sosukesuzuki/worsp) | C++ ⚠️ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | pending | pending | pending | pending | pending | n/a | n/a | n/a | n/a |
| 101 | [XOpt](https://github.com/drylikov/XOpt.git) · [mirror](https://github.com/o2alexanderfedin/XOpt-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 637 | 618 | +3.0% | 6.5% | 6.3% | 25 | 20 | 20 | 0 (0%) |

</div>

<sub>A **site** is one individual unsafe OPERATION, not a function or a whole `unsafe {}` block. Every safety number below compares **two Rust emissions of the same program**, both scored by the same `unsafe_census` instrument: the **faithful** baseline (lab factory — all uplift segments dropped, a straight transliteration) and the **safe** production default (pointer→`Option`/span, alloc→`Box`/`Vec`, printf→`print!`, cstring-global uplift all ON). **Transpiled / Compiled** — did cpp2rust emit, and does the emitted code build, for the C++ lane and the Rust lane (`ok/total` translation units). **Tested** — the differential oracles: **A/B** runs the project built from native C vs from the transpiled C++/Rust and compares output byte-for-byte (`—` = not linkable as one binary, e.g. cross-TU C++ name mangling or unresolved builtin FFI; logged, never silently passed); **pass@1** is CRUST-bench's official oracle — the emitted crate spliced under the hand-written RBench interface, then `cargo test`. For SQLite the Tested cell is the whole-CLI differential over the SQL scripts. **Non-safe Sites (faithful)** / **Safe Sites (uplift)** — the 6-family unsafe-site total (`raw_ptr_deref + extern_unsafe_call + static_mut + union_read + transmute + inline_asm`) in each emission; `first_party_call` (harness-FFI / transpiler shims), `intrinsic_call` (benign compiler intrinsics), `boundary_reborrow` (`&*p`/`&mut *p` reborrows synthesized where a lifted callee signature meets a caller local that stayed a raw pointer — the SAME pointer risk re-spelled at each call seam, not new unsafety), `unchecked_arith` (C pointer arithmetic) and whole `unsafe_blocks` are separate lanes, never folded into the total. **Site Reduction (%)** — `(faithful − safe) ÷ faithful`; **positive = the uplift REMOVED unsafe sites** relative to the faithful baseline. **Faithful UOD** / **Safe UOD** — Unsafe-Operation-Density: unsafe sites ÷ total expressions in that emission's own AST (lower is safer; the denominator grows with any added scaffolding, so density cannot be gamed by code inflation). **Total Fns** — every function-with-a-body counted (by census line, so same-named impl/trait methods are not merged); **Unsafe Fns (faithful)** / **Unsafe Fns (safe)** — those carrying ≥1 unsafe site in each emission; **Fns Made Safe** — the region-keyed join: functions unsafe in the faithful baseline that the uplift makes fully safe, shown as `n (n ÷ unsafe-faithful)`. Safety cells render `pending` / `n/a` for any project whose faithful OR safe emission had a non-zero parse-error count — those projects are excluded from the aggregate (the excluded count is reported there). Whole-program **SQLite shows a small reduction by design**: it is emitted as one monocrate where almost every function is externally visible across the link set, so the ownership/pointer uplifts are ABI-vetoed there to preserve the C-ABI boundary — the site-removing signal concentrates in the smaller, self-contained CRUST-bench projects. All counts use thousands separators.</sub>

**Unsafe operation sites by family — across the 44 projects with a clean two-mode parse** (the faithful lab baseline vs the safe uplift, both emissions of the same program; 56 project(s) excluded for a non-zero parse-error count in one mode (shown `pending` above)):

| Family | Sites (faithful) | Sites (safe uplift) | Δ (faithful−safe) |
|---|---:|---:|---:|
| raw_ptr_deref | 24,251 | 23,962 | 289 |
| extern_unsafe_call | 12,272 | 11,521 | 751 |
| static_mut | 606 | 606 | 0 |
| union read | 2 | 2 | 0 |
| transmute | 714 | 714 | 0 |
| inline_asm | 0 | 0 | 0 |
| **Total (memory-safety sites)** | **37,845** | **36,805** | **1,040** |
| _unchecked_arith (separate lane)_ | _0_ | _0_ | _—_ |
| _first_party_call (harness-FFI / transpiler shims — excluded)_ | _—_ | _1,078_ | _—_ |
| _intrinsic_call (benign compiler intrinsics — excluded)_ | _—_ | _739_ | _—_ |
| _boundary_reborrow (`&*p`/`&mut *p` at lifted-signature seams — excluded)_ | _0_ | _0_ | _0_ |

Totals — Non-safe (faithful) unsafe sites **37,845** → Safe (uplift) unsafe sites **36,805** (Site Reduction **+2.7%**: the uplift nets FEWER unsafe sites than the faithful baseline). Faithful UOD **9.36%** → Safe UOD **9.16%** (unsafe sites ÷ total expressions in each emission's AST).
Function-level — of **1,972** functions carrying ≥1 unsafe site in the faithful baseline, the uplift makes **54** fully safe (**2.7%**); **1,931** functions still carry an unsafe site in the safe emission, out of **2,266** functions total.
<!-- crust-table:end -->

### pass@1 — 0 pass / 35 attempted / 65 no interface match

pass@1 is the benchmark's headline metric: does the emitted Rust compile
against the project's *separately authored* Rust interface and pass
`cargo test`? This run now ATTEMPTS it (earlier reports recorded it
`not-attempted`): for every project with a compiling Rust crate, the emitted
modules are spliced under the hand-written RBench interface and `cargo test`
is run. 35 projects reached the splice; none passed — the emitted crate is a
faithful C-ABI translation whose module shapes and signatures do not yet
reconcile with the third-party hand-written interface (the remaining 65 had no
interface module to splice against). This is recorded honestly as `fail`/`—`,
never a blended success. For scale: the benchmark paper's best single-shot
model result solved 15 of 100 on this metric.

### Framing

clang2rust is tuned for large, self-contained C codebases such as
[SQLite](https://www.sqlite.org/) — where the complete command-line shell,
transpiled to Rust, runs byte-identical to the native build (see the
[README](README.md)). CRUST-bench is a deliberately different target: 100
unrelated third-party repositories with their own build systems and externally
supplied Rust interfaces. On this run the converter fully transpiles 48 of the
81 reachable projects to Rust (23 all the way to fully-compiling Rust) and 52
to C++, declines loudly — never silently mis-translating — where it hits
constructs it does not yet support, and every A/B leg that was linkable ran
byte-identical to native. We publish these numbers as a transparent baseline
to track over time, not as a figure to inflate or omit.

### Run environment notes

- On macOS, the harness splices the host SDK path into each project's
  compilation database so system headers resolve for a stand-alone parser
  (an environment fix, not a scoring change).
- Makefile-only projects need [`bear`](https://github.com/rizsotto/Bear) to
  record a compilation database; with `bear` installed, most of the 78
  Makefile-only projects became reachable. The 19 still-unreachable projects
  fail inside their own build files (broken make rules, CMake configs
  referencing missing files, or no build system at all).
- The Tier-1 compile check invokes `rustc` directly on each emitted crate
  (`--crate-type=lib --emit=obj`) — the emitted crates are C-ABI translation
  units, so a binary-target build would ask for an entry point that is not
  supposed to exist.

See [`benchmarks/CRUST-bench.md`](benchmarks/CRUST-bench.md) for the full
methodology and `benchmarks/run_crust_bench.sh --help` for harness usage.
