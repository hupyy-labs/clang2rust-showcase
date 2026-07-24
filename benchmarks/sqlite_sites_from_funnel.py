#!/usr/bin/env python3
"""sqlite_sites_from_funnel.py <census_faithful> <census_safe>

Fold TWO Rust `unsafe_census` logs — the FAITHFUL (all uplift dropped) and the
SAFE (production uplift) emissions of the SQLite whole-program Rust monocrate —
into the ONE-LINE site TSV that generate_report.py consumes via `--sqlite-sites`
(TWO_MODE_CONTRACT.md §7). It emits the SAME driver-row key shape a CRUST-bench
project emits, so the SQLite flagship row renders in the SAME two-mode site +
per-function columns as the corpus.

  ARG ORDER — do NOT swap (a swap silently INVERTS the reduction sign):
    argv[1] = census_faithful  — `unsafe_census` over the FAITHFUL Rust crate
                                 (emitted with all C2R_LAB_DROP_* toggles ON).
    argv[2] = census_safe      — `unsafe_census` over the SAFE (uplift) Rust
                                 crate (production default, no lab env vars).

  Each census file (TWO_MODE_CONTRACT.md §2) is a stream of per-function lines:
    FUNNEL_ACCT: lane=rust region=<stem>::<fn> raw_ptr_deref=N extern_unsafe_call=N
      first_party_call=N intrinsic_call=N boundary_reborrow=N static_mut=N
      union_read=N transmute=N inline_asm=N unchecked_arith=N unsafe_blocks=N
      total_exprs=N
  then ONE trailing summary line `FUNNEL_ACCT: lane=rust parse_errors=N`.

Emits one tab-separated key=value line to stdout:
  * r_*   — the SAFE emission (back-compat: same keys/meaning as before).
  * f_*   — the FAITHFUL emission (contract §5).
  * per-function join keys — total_fns / unsafe_fns_safe / unsafe_fns_faithful /
    fns_made_safe (contract §4).
  * safe_parse_errors / faithful_parse_errors — the both-mode validity gate
    (contract §5/§10).
Redirect stdout to benchmarks/sqlite-sites.tsv and pass that to
`generate_report.py --sqlite-sites`.

Pure reducer over already-produced logs — it runs neither the SQLite corpus nor
the census itself (that happens off the fixed develop tip, per run_all.sh §9).
"""
import re
import sys

# 6-family memory-safety SITE total (TWO_MODE_CONTRACT.md §3) — EXCLUDES
# unchecked_arith / first_party_call / intrinsic_call / unsafe_blocks.
SITE_FAMILIES = ("raw_ptr_deref", "extern_unsafe_call", "static_mut",
                 "union_read", "transmute", "inline_asm")
# Every per-region family key parsed off a census line (site families + the
# reported-but-excluded lanes + the UOD denominator). `boundary_reborrow`
# (`&*p`/`&mut *p` reborrows at lifted-signature seams) is a REPORTED-BUT-
# EXCLUDED lane — it is deliberately NOT in SITE_FAMILIES, so it never enters
# r_sites/f_sites; folding it in was the cause of the misleading negative
# "Site Reduction %" (a re-spelled pointer risk, not new unsafety).
ALL_FAMILIES = SITE_FAMILIES + ("first_party_call", "intrinsic_call",
                                "boundary_reborrow",
                                "unchecked_arith", "unsafe_blocks", "total_exprs")

_REGION_RX = re.compile(r"\bregion=(\S+)")
_PARSE_ERR_RX = re.compile(r"\bparse_errors=(\d+)\b")


def _kv(line, key):
    m = re.search(rf"\b{re.escape(key)}=(\d+)\b", line)
    return int(m.group(1)) if m else 0


def read_census(path):
    """Reduce one census file to:
        (totals over ALL_FAMILIES, region->summed-site_total dict,
         region_lines, unsafe_region_lines, parse_errors)

    Per-function metrics bucket by LINE, never by distinct region string
    (region keys collide across same-named impl/trait methods — §4); the
    region->site_total dict SUMS colliding keys for the fns-made-safe join.
    """
    totals = {k: 0 for k in ALL_FAMILIES}
    region_site = {}          # region key -> summed 6-family site_total
    region_lines = 0          # count of region= lines (§4 total_fns basis)
    unsafe_lines = 0          # region lines whose 6-family sum > 0
    parse_errors = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "region=" in line:
                    for k in ALL_FAMILIES:
                        totals[k] += _kv(line, k)
                    site = sum(_kv(line, k) for k in SITE_FAMILIES)
                    region_lines += 1
                    if site > 0:
                        unsafe_lines += 1
                    rm = _REGION_RX.search(line)
                    if rm:
                        region_site[rm.group(1)] = region_site.get(rm.group(1), 0) + site
                elif "parse_errors=" in line:
                    pm = _PARSE_ERR_RX.search(line)
                    if pm:
                        parse_errors += int(pm.group(1))
    except OSError as e:
        print(f"warning: {e}", file=sys.stderr)
    return totals, region_site, region_lines, unsafe_lines, parse_errors


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    faithful_path, safe_path = sys.argv[1], sys.argv[2]

    f_tot, f_region, _f_lines, f_unsafe, f_perr = read_census(faithful_path)
    s_tot, s_region, s_lines, s_unsafe, s_perr = read_census(safe_path)

    site_sum = lambda t: sum(t[k] for k in SITE_FAMILIES)

    # fns_made_safe — region-key JOIN (§4): the function had unsafe sites in the
    # faithful emission but NONE after the uplift.
    fns_made_safe = sum(1 for reg, fs in f_region.items()
                        if fs > 0 and s_region.get(reg, 0) == 0)

    fields = {
        "project": "sqlite",
        # --- SAFE (uplift) — r_* (unchanged meaning; back-compat) ------------
        "r_raw_ptr_deref": s_tot["raw_ptr_deref"],
        "r_extern_unsafe_call": s_tot["extern_unsafe_call"],
        "r_first_party_call": s_tot["first_party_call"],
        "r_intrinsic_call": s_tot["intrinsic_call"],
        "r_boundary_reborrow": s_tot["boundary_reborrow"],
        "r_static_mut": s_tot["static_mut"],
        "r_union_read": s_tot["union_read"],
        "r_transmute": s_tot["transmute"],
        "r_inline_asm": s_tot["inline_asm"],
        "r_unchecked_arith": s_tot["unchecked_arith"],
        "r_unsafe_blocks": s_tot["unsafe_blocks"],
        "r_sites": site_sum(s_tot),
        "rust_exprs": s_tot["total_exprs"],
        # --- NON-SAFE (faithful) — f_* (contract §5) ------------------------
        "f_raw_ptr_deref": f_tot["raw_ptr_deref"],
        "f_extern_unsafe_call": f_tot["extern_unsafe_call"],
        "f_boundary_reborrow": f_tot["boundary_reborrow"],
        "f_static_mut": f_tot["static_mut"],
        "f_union_read": f_tot["union_read"],
        "f_transmute": f_tot["transmute"],
        "f_inline_asm": f_tot["inline_asm"],
        "f_sites": site_sum(f_tot),
        "f_total_exprs": f_tot["total_exprs"],
        # --- per-function (§4) ----------------------------------------------
        "total_fns": s_lines,
        "unsafe_fns_safe": s_unsafe,
        "unsafe_fns_faithful": f_unsafe,
        "fns_made_safe": fns_made_safe,
        # --- both-mode validity gate (§5/§10) -------------------------------
        "safe_parse_errors": s_perr,
        "faithful_parse_errors": f_perr,
    }
    print("\t".join(f"{k}={v}" for k, v in fields.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
