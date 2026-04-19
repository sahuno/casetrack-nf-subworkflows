#!/usr/bin/env python3
"""Distill one modkit pileup bedMethyl into a one-row summary TSV.

The TSV schema matches [analyses.modkit_pileup] from the shipped casetrack
templates. Column names here flow through `casetrack append --column-prefix
modkit` to become `modkit_mean_meth`, `modkit_n_cpgs`, `modkit_median_cov`.

Keyed on `assay_id` (the leaf directory name in the tool-first layout).

Author: Samuel Ahuno <ekwame001@gmail.com>
"""
from __future__ import annotations

import argparse
import gzip
import logging
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bedmethyl", required=True,
                   help="Path to modkit pileup bedMethyl (may be .bed or .bed.gz)")
    p.add_argument("--assay-id", required=True,
                   help="Assay id; written as the first column of the summary TSV")
    p.add_argument("--output", required=True, help="Output summary TSV path")
    p.add_argument("--min-coverage", type=int, default=5,
                   help="Minimum per-site coverage to include in the mean (default: 5)")
    p.add_argument("--mod-code", default="m",
                   help="Mod code to summarize (default: 'm' = 5mC). Use 'any' "
                        "to include all; modkit pileup emits one row per site per "
                        "mod code (m, h, a) so filtering is usually required.")
    return p.parse_args()


def iter_bedmethyl(path: Path):
    """Yield (chrom, start, end, mod_code, coverage, pct_modified) tuples.

    modkit pileup bedMethyl columns:
        1 chrom, 2 start, 3 end, 4 mod_code, 5 score (int),
        6 strand, 7 thickstart, 8 thickend, 9 color,
        10 valid_coverage, 11 percent_modified, ...
    """
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 11:
                continue
            try:
                cov = int(parts[9])
                pct = float(parts[10])
            except ValueError:
                continue
            yield (parts[0], int(parts[1]), int(parts[2]),
                   parts[3], cov, pct)


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)s: %(message)s",
    )
    log = logging.getLogger("summarize_modkit")

    src = Path(args.bedmethyl)
    if not src.exists():
        log.error("bedMethyl not found: %s", src)
        return 1

    # Streaming single-pass stats — constant memory regardless of input size.
    # modkit chr21 WGS pileup emits ~55M rows (3 mod codes per site); a
    # naive list-based approach OOMs even at 2 GB. Mean coverage replaces
    # median because a true streaming median would require extra machinery
    # (P² or t-digest) without adding much decision value at this scope.
    mod_filter = None if args.mod_code == "any" else args.mod_code
    n_cpgs = 0
    n_skipped_mod = 0
    n_skipped_cov = 0
    sum_pct = 0.0
    sum_cov = 0

    for chrom, start, end, mod, cov, pct in iter_bedmethyl(src):
        if mod_filter is not None and mod != mod_filter:
            n_skipped_mod += 1
            continue
        if cov < args.min_coverage:
            n_skipped_cov += 1
            continue
        sum_pct += pct
        sum_cov += cov
        n_cpgs += 1

    if n_cpgs == 0:
        log.warning(
            "No sites met mod=%s min-coverage=%d in %s "
            "(skipped_mod=%d skipped_cov=%d)",
            args.mod_code, args.min_coverage, src, n_skipped_mod, n_skipped_cov,
        )
        mean_meth = float("nan")
        mean_cov = 0.0
    else:
        mean_meth = (sum_pct / n_cpgs) / 100.0
        mean_cov = sum_cov / n_cpgs

    log.info(
        "assay_id=%s mod=%s n_cpgs=%d mean_meth=%.4f mean_cov=%.2f "
        "(skipped_mod=%d skipped_cov=%d)",
        args.assay_id, args.mod_code, n_cpgs, mean_meth, mean_cov,
        n_skipped_mod, n_skipped_cov,
    )

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as fh:
        fh.write("assay_id\tmean_meth\tn_cpgs\tmean_cov\n")
        fh.write(
            f"{args.assay_id}\t{mean_meth:.4f}\t{n_cpgs}\t{mean_cov:.2f}\n"
        )
    log.info("Wrote %s", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
