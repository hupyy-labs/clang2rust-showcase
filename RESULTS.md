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
_Pending: the first full cargo-geiger two-mode sweep has not run yet.
`benchmarks/run_all.sh` regenerates this section from the measured results._
<!-- crust-table:end -->
