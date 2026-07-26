<link rel="stylesheet" href="results.css">

# Results

Two measurements, one honest report: **SQLite** — the product's primary
target, the 84-translation-unit CLI link set (including the command-line
shell, `shell.c`) transpiled whole, built as **one whole-program monocrate**
with 0 rustc errors, and differentially tested **byte-for-byte against the
native CLI** over the same SQL scripts — and **CRUST-bench** — 100 unrelated
third-party C repositories, published as a transparent external baseline.

## Methodology

Every project is transpiled **twice** from the same source: once **without**
safety uplifting (*before*) and once **with** it (*after* — the production
default). Both Rust outputs are measured by
[cargo-geiger v0.13.0](https://crates.io/crates/cargo-geiger) (crates.io),
the community-standard unsafe-usage detector; the table reports geiger's
unsafe-**expression** counts (individual unsafe operations, e.g. raw-pointer
dereferences, inside unsafe code). The **before → after** delta is exactly
what the safety uplift removes. The table below is rendered by
[`benchmarks/generate_report.py`](benchmarks/generate_report.py) (tested by
[`benchmarks/test_generate_report.py`](benchmarks/test_generate_report.py))
from the per-project result rows and the per-mode raw geiger measurements;
every column is defined in the legend beneath the table.

## Per-project results

<!-- crust-table:begin -->
<div class="wide-table">

| # | Project | Transpiled | Built | Tests | Unsafe (before) | Unsafe (after) | Change |
|---|---|---|---|---|---:|---:|---:|
| 1 | [SQLite](https://www.sqlite.org/) → [Rust output](https://github.com/o2alexanderfedin/sqlite-rust-mirror) — **flagship** | ✅ all 84 files | ✅ one whole-program monocrate | ✅ all 10 SQL scripts byte-identical vs native CLI (3 runs) | 438,340 | 436,115 | +0.5% |
| 2 | [2DPartInt](https://github.com/eafit-apolo/2DPartInt) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 3 | [42-Kocaeli-Printf](https://github.com/enes2424/42-Kocaeli-Printf) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 4 | [aes128-SIMD](https://github.com/at0m741/aes128-SIMD) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 5 | [amp](https://github.com/clibs/amp) · [mirror](https://github.com/o2alexanderfedin/amp-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 180 | 143 | +20.6% |
| 6 | [approxidate](https://github.com/thatguystone/approxidate) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 7 | [avalanche](https://github.com/drjerry/avalanche) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 8 | [bhshell](https://github.com/bsach64/bhshell) | C++ ⚠️ · Rust ❌ | C++ 4/4 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 9 | [bigint](https://github.com/adam-mcdaniel/bigint) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 10 | [bitset](https://github.com/abenhlal/bitset) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 11 | [blt](https://github.com/blynn/blt) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 12 | [bostree](https://github.com/phillipberndt/bostree) · [mirror](https://github.com/o2alexanderfedin/bostree-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/3 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 1,647 | 1,554 | +5.6% |
| 13 | [btree-map](https://github.com/EdsonHTJ/btree-map) · [mirror](https://github.com/o2alexanderfedin/btree-map-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 1,243 | 1,242 | +0.1% |
| 14 | [c-aces](https://github.com/enum-class/c-aces) | C++ ⚠️ · Rust ❌ | C++ 5/5 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 15 | [c-blind-rsa-signatures](https://github.com/jedisct1/c-blind-rsa-signatures) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 16 | [c-string](https://github.com/vnkrtv/c-string) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 17 | [carrays](https://github.com/noporpoise/carrays) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 18 | [cfsm](https://github.com/nhjschulz/cfsm) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 19 | [chtrie](https://github.com/dongyx/chtrie) · [mirror](https://github.com/o2alexanderfedin/chtrie-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 254 | 224 | +11.8% |
| 20 | [CircularBuffer](https://github.com/Roen-Ro/CircularBuffer) | C++ ⚠️ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 21 | [cissy](https://github.com/slass100/cissy) | C++ ✅ · Rust ✅ | C++ 4/7 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 22 | [cJSON](https://github.com/faycheng/cJSON) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 23 | [clhash](https://github.com/simdhash/clhash) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 24 | [clog](https://github.com/mmueller/clog) | C++ ✅ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 25 | [coroutine](https://github.com/cloudwu/coroutine) | C++ ⚠️ · Rust ❌ | C++ 1/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 26 | [cset](https://github.com/RobusGauli/cset.h) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 27 | [csyncmers](https://github.com/rchikhi/csyncmers) · [mirror](https://github.com/o2alexanderfedin/csyncmers-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 436 | 141 | +67.7% |
| 28 | [dict](https://github.com/wrnlb666/dict) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 29 | [emlang](https://github.com/LordOfTrident/emlang) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 30 | [expr](https://github.com/radarsat1/expr) | C++ ✅ · Rust ❌ | C++ 1/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 31 | [FastHamming](https://github.com/BenBE/FastHamming.git) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 32 | [fft](https://github.com/kevin0x0/fft) · [mirror](https://github.com/o2alexanderfedin/fft-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 605 | 605 | 0.0% |
| 33 | [file2str](https://github.com/willemt/file2str) | C++ ✅ · Rust ✅ | C++ 4/4 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | 648 | n/a (build) | — |
| 34 | [fleur](https://github.com/hashlookup/fleur) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 35 | [fs_c](https://github.com/jwerle/fs.c) · [mirror](https://github.com/o2alexanderfedin/fs_c-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 112 | 112 | 0.0% |
| 36 | [fslib](https://github.com/c0stya/fslib) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 37 | [Genetic-neural-network-for-simple-control](https://github.com/DemianovE/Genetic-neural-network-for-simple-control) | C++ ⚠️ · Rust ❌ | C++ 12/12 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 38 | [geofence](https://github.com/bytebeamio/geofence.git) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 39 | [gfc](https://github.com/maxmouchet/gfc.git) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 40 | [gorilla-paper-encode](https://github.com/MrBean818/gorilla-paper-encode) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 41 | [Graph-recogniser](https://github.com/NikolaYolov/Graph-recogniser) | C++ ✅ · Rust ✅ | C++ 4/4 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 42 | [hamta](https://github.com/burtgulash/hamta) · [mirror](https://github.com/o2alexanderfedin/hamta-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 124 | 121 | +2.4% |
| 43 | [Holdem-Odds](https://github.com/gnuvince/Holdem-Odds) | C++ ✅ · Rust ✅ | C++ 4/5 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 44 | [hydra](https://github.com/emad-elsaid/hydra) · [mirror](https://github.com/o2alexanderfedin/hydra-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 437 | 419 | +4.1% |
| 45 | [impcheck](https://github.com/domschrei/impcheck) | C++ ⚠️ · Rust ❌ | C++ 2/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 46 | [inversion_list](https://github.com/hou-12/Inversion-List-Implementation-for-Interval-Manipulation) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 47 | [jccc](https://github.com/jabacat/jccc) | C++ ✅ · Rust ✅ | C++ 12/13 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 48 | [kairoCompiler](https://github.com/kairo-yr/kairoCompiler) | C++ ✅ · Rust ❌ | C++ 3/10 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 49 | [kd3](https://github.com/shawnchin/kd3) · [mirror](https://github.com/o2alexanderfedin/kd3-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ ✅·Rust — · pass@1 — | 1,187 | 882 | +25.7% |
| 50 | [lambda-calculus-eval](https://github.com/Lorenzobattistela/lambda-calculus-eval) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 51 | [leftpad](https://github.com/sjmulder/leftpad) · [mirror](https://github.com/o2alexanderfedin/leftpad-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ ✅·Rust ✅ · pass@1 — | 154 | 154 | 0.0% |
| 52 | [lib2bit](https://github.com/dpryan79/lib2bit) · [mirror](https://github.com/o2alexanderfedin/lib2bit-rust-mirror) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 1,803 | 1,904 | −5.6% |
| 53 | [libbase122](https://github.com/kevinAlbs/libbase122) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 54 | [libbeaufort](https://github.com/jwerle/libbeaufort) · [mirror](https://github.com/o2alexanderfedin/libbeaufort-rust-mirror) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 232 | 232 | 0.0% |
| 55 | [libfor](https://github.com/cruppstahl/libfor) · [mirror](https://github.com/o2alexanderfedin/libfor-rust-mirror) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 1/1 | A/B C++ ✅·Rust — · pass@1 — | 53,779 | 53,777 | +0.0% |
| 56 | [libm17](https://github.com/M17-Project/libm17) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 57 | [libpgn](https://github.com/youkwhd/libpgn) | C++ ✅ · Rust ✅ | C++ 11/12 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 58 | [libpsbt](https://github.com/jb55/libpsbt) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 59 | [libqueue](https://github.com/resyfer/libqueue) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 60 | [libtinyfseq](https://github.com/Cryptkeeper/libtinyfseq) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 61 | [libutf](https://github.com/holepunchto/libutf) | C++ ⚠️ · Rust ✅ | C++ 0/27 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 62 | [libvcd](https://github.com/sorousherafat/libvcd) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 63 | [libwecan](https://github.com/nisennenmondai/libwecan) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 64 | [Linear-Algebra-C](https://github.com/barrettotte/Linear-Algebra-C) | C++ ✅ · Rust ✅ | C++ 4/4 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 65 | [ljmm](https://github.com/cloudflare/ljmm) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 66 | [LTRE](https://github.com/Bricktech2000/LTRE) | C++ ✅ · Rust ❌ | C++ 1/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 67 | [Math-Library-in-C](https://github.com/Astrodynamic/Math-Library-in-C) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 68 | [matrix_multiplication](https://github.com/DevRuibin/matrix_multiplication) | C++ ⚠️ · Rust ❌ | C++ 1/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 69 | [mdb](https://github.com/chuigda/mdb.git) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 70 | [Megalania](https://github.com/blackle/Megalania) | C++ ⚠️ · Rust ❌ | C++ 16/16 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 71 | [merkle-tree-c](https://github.com/TheWaWaR/merkle-tree-c) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 72 | [morton](https://github.com/jart/morton) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 73 | [murmurhash_c](https://github.com/jwerle/murmurhash.c) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 74 | [mvptree](https://github.com/michaelmior/mvptree) | C++ ✅ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 75 | [NandC](https://github.com/Dcraftbg/NandC) | C++ ✅ · Rust ✅ | C++ 0/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 76 | [Phills_DHT](https://github.com/PhillipTaylor/Phills_DHT) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 77 | [quadtree](https://github.com/thejefflarson/quadtree) · [mirror](https://github.com/o2alexanderfedin/quadtree-rust-mirror) | C++ ✅ · Rust ✅ | C++ 5/5 · Rust 1/1 | A/B C++ ✅·Rust ✅ · pass@1 — | 1,025 | 1,026 | −0.1% |
| 78 | [razz_simulation](https://github.com/eus/razz_simulation) | C++ ✅ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 79 | [rbtree-lab](https://github.com/jwowo/rbtree-lab) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 80 | [recordManager](https://github.com/prachikotadia/-Record-Manager) | C++ ⚠️ · Rust ❌ | C++ 7/7 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 81 | [rect_pack_h](https://github.com/luihabl/rect_pack.h) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 82 | [Remimu](https://github.com/wareya/Remimu) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 83 | [rhbloom](https://github.com/tidwall/rhbloom) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 84 | [roaring-bitmap](https://github.com/chriso/roaring-bitmap) | C++ ❌ · Rust ❌ | C++ 0/0 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 85 | [rubiksolver](https://github.com/justjkk/rubiksolver) | C++ ✅ · Rust ✅ | C++ 2/5 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 86 | [satc](https://github.com/rjungemann/satc) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 87 | [Simple-Config](https://github.com/0xHaru/Simple-Config) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 88 | [Simple-Sparsehash](https://github.com/qpfiffer/Simple-Sparsehash) · [mirror](https://github.com/o2alexanderfedin/Simple-Sparsehash-rust-mirror) | C++ ✅ · Rust ✅ | C++ 1/2 · Rust 1/1 | A/B C++ —·Rust — · pass@1 — | 1,054 | 1,042 | +1.1% |
| 89 | [simple_lang](https://github.com/lxbme/simple_lang) | C++ ✅ · Rust ❌ | C++ 11/11 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 90 | [SimpleXML](https://github.com/kiennt/SimpleXML.git) | C++ ⚠️ · Rust ❌ | C++ 1/2 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 91 | [skp](https://github.com/rdentato/skp) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 92 | [SlothLang](https://github.com/AaronCGoidel/SlothLang) | C++ ⚠️ · Rust ❌ | C++ 3/3 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 93 | [ted](https://github.com/ajpen/ted) | C++ ⚠️ · Rust ✅ | C++ 3/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 94 | [tisp](https://github.com/edvb/tisp) | C++ ✅ · Rust ✅ | C++ 0/2 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 95 | [totp](https://github.com/sjmulder/totp) | C++ ✅ · Rust ✅ | C++ 2/3 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 96 | [ulidgen](https://github.com/leahneukirchen/ulidgen) | C++ ⚠️ · Rust ❌ | C++ 1/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 97 | [utf8](https://github.com/zahash/utf8.c) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 98 | [VaultSync](https://github.com/elhalili/VaultSync) | n/a — project build broken | — | — | n/a (build) | n/a (build) | — |
| 99 | [vec](https://github.com/rxi/vec) | C++ ✅ · Rust ✅ | C++ 2/2 · Rust 0/1 | A/B C++ ✅·Rust — · pass@1 — | 7,886 | n/a (build) | — |
| 100 | [worsp](https://github.com/sosukesuzuki/worsp) | C++ ⚠️ · Rust ❌ | C++ 0/1 · Rust 0/0 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |
| 101 | [XOpt](https://github.com/drylikov/XOpt.git) | C++ ✅ · Rust ✅ | C++ 1/1 · Rust 0/1 | A/B C++ —·Rust — · pass@1 — | n/a (build) | n/a (build) | — |

</div>

<sub>Measured by **cargo-geiger v0.13.0** (crates.io). Each project is transpiled twice from the same source — once **without** safety uplifting (*before*) and once **with** it (*after*) — and both Rust outputs are measured by cargo-geiger. **Transpiled** — the transpiler emitted output (C++ lane · Rust lane). **Built** — the emitted code compiles (`ok/total` translation units or crates). **Tests** — the differential oracles: **A/B** compares the native-C binary's output byte-for-byte with the transpiled C++/Rust binary (`—` = not linkable as one binary); **pass@1** is CRUST-bench's official oracle (the emitted crate spliced under the hand-written RBench interface, then `cargo test`). For SQLite, Tests is the whole-CLI differential over the SQL scripts. **Unsafe (before) / Unsafe (after)** — cargo-geiger's Expressions count in each emission. **Change** — `(before − after) ÷ before`, signed: positive = the uplift removed unsafe expressions, negative = worse. cargo-geiger's five categories (all stored per mode in the raw per-mode JSON files; the table shows Expressions): **Functions** — unsafe function definitions vs safe; **Expressions** — individual unsafe operations (e.g. raw-pointer dereferences) inside unsafe code; **Impls** — unsafe trait implementations; **Traits** — unsafe trait declarations; **Methods** — unsafe methods in impls. Crate safety tiers, as cargo-geiger reports them: 🔒 no unsafe usage found and the crate declares `#![forbid(unsafe_code)]`; ❓ no unsafe usage found, forbid not declared; ☢️ unsafe usage found. Emitted crates do not declare `forbid(unsafe_code)`, so a fully-safe result reads ❓ under geiger's own rules. `n/a (build)` — that mode did not compile, so geiger cannot measure it; `pending` — not yet measured. Projects without a clean both-mode measurement are excluded from the aggregate (count disclosed).</sub>

**Aggregate over the 16 both-mode-measured project(s):** before 64,272 → after 63,578 unsafe expressions (Change +1.1%); 84 project(s) excluded (n/a (build)).
<!-- crust-table:end -->
