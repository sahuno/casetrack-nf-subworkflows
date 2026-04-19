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
from statistics import median


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bedmethyl", required=True,
                   help="Path to modkit pileup bedMethyl (may be .bed or .bed.gz)")
    p.add_argument("--assay-id", required=True,
                   help="Assay id; written as the first column of the summary TSV")
    p.add_argument("--output", required=True, help="Output summary TSV path")
    p.add_argument("--min-coverage", type=int, default=5,
                   help="Minimum per-site coverage to include in the mean (default: 5)")
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

    pcts: list[float] = []
    coverages: list[int] = []
    n_cpgs = 0
    for chrom, start, end, mod, cov, pct in iter_bedmethyl(src):
        if cov < args.min_coverage:
            continue
        pcts.append(pct)
        coverages.append(cov)
        n_cpgs += 1

    if n_cpgs == 0:
        log.warning("No sites met min-coverage=%d in %s", args.min_coverage, src)
        mean_meth = float("nan")
        median_cov = 0
    else:
        mean_meth = sum(pcts) / len(pcts) / 100.0
        median_cov = int(median(coverages))

    log.info("assay_id=%s n_cpgs=%d mean_meth=%.4f median_cov=%d",
             args.assay_id, n_cpgs, mean_meth, median_cov)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as fh:
        fh.write("assay_id\tmean_meth\tn_cpgs\tmedian_cov\n")
        fh.write(f"{args.assay_id}\t{mean_meth:.4f}\t{n_cpgs}\t{median_cov}\n")
    log.info("Wrote %s", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
