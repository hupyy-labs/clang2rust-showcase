# clang2rust

**A C/C++ → idiomatic, memory-safe Rust transpiler.**

clang2rust converts existing C/C++ source into idiomatic, memory-safe Rust
that compiles and behaves identically to the original.

---

## Performance

| Metric | Result |
|---|---|
| Compiles | 281 / 281 SQLite corpus translation units produce Rust that compiles (rustc obj-OK) |
| Behavioral parity | The complete SQLite command-line shell, transpiled to Rust, is byte-identical to the native build across 10 SQL test scripts, reproduced 3× under an allocator-hardened harness. Flagship row: [RESULTS.md](RESULTS.md) |
| Safety | Measured two-mode by [cargo-geiger v0.13.0](https://crates.io/crates/cargo-geiger): each project is transpiled without and with safety uplifting, and both Rust outputs are geiger-scored. Fresh sweep numbers pending — see [RESULTS.md](RESULTS.md) |
| CRUST-bench (100 third-party C repos) | Full two-mode sweep pending under the cargo-geiger instrument — per-project table in [RESULTS.md](RESULTS.md) |
| Release | 0.22.0 |

*Measured on the [SQLite](https://www.sqlite.org/) separate-file source tree
(individual translation units, not the single-file amalgamation). Correctness
is confirmed by differentially comparing transpiled output byte-for-byte
against the original across real workloads.*

---

## Supported source constructs

| Source construct | Rust output | Status |
|---|---|---|
| Integer, enum, and boolean coercions & truthiness | Explicit, type-correct Rust equivalents | Shipped |
| Full control flow, including `goto` | Structured Rust control flow | Shipped |
| Variadic functions | Typed Rust collections | Shipped |
| `switch` / `case`, static-local variables | Idiomatic Rust `match` and statics | Shipped |
| Unions with a provable discriminant | Tagged Rust `enum`s | Shipped |
| Smart pointers | `Box`, `Rc`, `Arc` | Shipped |
| Raw pointers | Safe references, via borrow inference | In progress |
| C strings, wide strings | `String` / `&str` | Shipped |
| `printf`-family calls | Rust formatting (`print!`, `eprintln!`, etc.) | Shipped |
| Mutex / thread primitives | Rust `std::sync` / `std::thread` equivalents | Shipped |
| Multi-file C/C++ projects | Multi-module Rust crates | Shipped |
| Source comments & doc-comments | Carried into the Rust output | Shipped |

---

## Reference output

clang2rust's output on real-world code is published for inspection:

| Repository | Description |
|---|---|
| [sqlite-rust-mirror](https://github.com/o2alexanderfedin/sqlite-rust-mirror) | SQLite transpiled to Rust — reference output |
| [sqlite-cpp-mirror](https://github.com/o2alexanderfedin/sqlite-cpp-mirror) | SQLite transpiled to modern C++ — reference output |
| [sqlite/sqlite](https://github.com/sqlite/sqlite) | The original source corpus |

---

## Methodology — what we measure vs. what CRUST-Bench measures

We run our transpiler over the **[CRUST-Bench](https://arxiv.org/abs/2504.15254) corpus** (its 100 C projects), but we are **not** running the CRUST-Bench task, and our headline safety numbers are our **own instrument** — not a CRUST-Bench score. The two efforts measure different things.

**CRUST-Bench** is an *LLM* C→safe-Rust benchmark. Each C project ships with a hand-written **safe-Rust interface** (safe signatures + ownership types) and a ported Rust test suite; a language model fills in the bodies. Its two **scored** metrics are, per whole project:
- **Build** — does `cargo build` succeed (debug profile, warnings ignored);
- **Test** — does `cargo test` pass all ported tests — reported as **pass@1** plus two rounds of compiler-/test-feedback repair.

CRUST-Bench does **not** mechanically gate safety: there is no `#![forbid(unsafe_code)]`, `libc` is an allowed dependency (its own reference tests call `unsafe { libc::… }`), and unsafe usage is only tallied *post-hoc* as a coarse per-project flag ("does the output contain the `unsafe` keyword?"). It also **excludes** syntax-directed transpilers such as c2rust for producing too much unsafe/FFI Rust.

**This project** is a *deterministic* AST transpiler — the class CRUST-Bench excludes — and it measures safety with a community-standard instrument: [**cargo-geiger v0.13.0**](https://crates.io/crates/cargo-geiger), which counts unsafe usage (the table reports its unsafe-**expression** count — individual unsafe operations inside unsafe code), applied to **two Rust emissions of identical source**:
- **before** — safety uplifting *disabled*: a raw, unsafe-preserving lowering, comparable in spirit to a syntax-directed transpiler;
- **after** — safety uplifting *enabled* (the production default).

The **before → after** delta isolates exactly what our uplift removes — information CRUST-Bench's binary flag cannot express.

**How to read our numbers, honestly:**
- Our Unsafe (before)/(after)/Change columns compare our own two emissions with a third-party detector; there is no CRUST-Bench number to compare them to, and we do **not** claim to "beat" CRUST-Bench on safety.
- The only columns that map to CRUST-Bench's published methodology are **Built** (≈ their Build) and **Tests / pass@1** (≈ their Test). Our pass@1 is produced differently (a mechanical splice against the reference interface, not an LLM fill-and-repair loop), so it is **not** directly comparable either.
- Because we preserve C semantics and A/B-verify behavior, our output keeps `unsafe extern` at genuine libc/FFI edges (e.g. the SQLite lane). By CRUST-Bench's binary "no unsafe" rule that counts as unsafe — an intentional trade-off: we prioritize behavioral fidelity over an all-safe surface at the C boundary.

**The claim we do stand behind:** over the same corpus, our uplift *measurably reduces unsafe expressions* relative to a raw, c2rust-style lowering of the identical source — a reduction their coarse safety flag cannot see.

---

## Benchmark: CRUST-bench

[CRUST-bench](https://github.com/anirudhkhatry/CRUST-bench)
([paper](https://arxiv.org/abs/2504.15254)) is a published benchmark of 100
real-world C repositories, each paired with a hand-written safe-Rust
interface and a test suite. Its scoring metric, **pass@1**, asks whether a
single transpilation attempt compiles against the provided interface *and*
passes `cargo test`.

We report two honest tiers, described in full in
[`benchmarks/CRUST-bench.md`](benchmarks/CRUST-bench.md):

1. **Transpiles** — the emitted Rust compiles as its own crate.
2. **CRUST-bench pass@1** — the emitted Rust compiles against CRUST-bench's
   hand-written interface *and* passes `cargo test`.

clang2rust is currently tuned for large, self-contained C codebases like
SQLite, and does not yet reconcile its output against arbitrary
third-party, hand-written interfaces. We expect Tier-2 pass@1 to be low as a
result — we're publishing it anyway, as an honest baseline rather than a
number to hide.

Results: [`RESULTS.md`](RESULTS.md) — the SQLite flagship row plus the
per-project CRUST-bench table. The first full sweep under the cargo-geiger
instrument is pending; the table says so plainly until it runs.

### Reproduce

```console
$ benchmarks/run_crust_bench.sh --transpiler ../cpp-to-rust/cpp/build/bin/cpp2rust --cache ~/.cache/crust-bench
```

See [`benchmarks/CRUST-bench.md`](benchmarks/CRUST-bench.md) and
`benchmarks/run_crust_bench.sh --help` for full usage.

---

## License

See [`LICENSE`](LICENSE).
