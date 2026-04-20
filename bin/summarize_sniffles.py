#!/usr/bin/env python3
# Author: Samuel Ahuno
# Date: 2026-04-20
# Purpose: Parse a Sniffles2 VCF (bgzipped or plain) and emit a one-row casetrack summary TSV.
"""
Parses INFO/SVTYPE + FILTER fields from a Sniffles2 VCF (gzipped or plain).
Emits columns: <id_col>, n_svs_total, n_pass, n_ins, n_del, n_dup, n_inv, n_bnd, vcf_path.

Usage:
    python summarize_sniffles.py --vcf <path.vcf.gz> --id-col assay_id --id-value P01_A001 --vcf-abs-path /abs/path.vcf.gz
"""
from __future__ import annotations

import argparse
import gzip
import logging
import sys
from collections import Counter
from pathlib import Path

logging.basicConfig(
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[logging.StreamHandler(sys.stderr)],
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

_KNOWN_SVTYPES = {"INS", "DEL", "DUP", "INV", "BND"}


def _open(path: Path):
    if path.suffix == ".gz" or path.name.endswith(".vcf.gz"):
        return gzip.open(path, "rt")
    return open(path, "r")


def parse_vcf(vcf_path: Path) -> dict:
    counts: Counter = Counter()
    n_pass = 0
    n_total = 0

    with _open(vcf_path) as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 8:
                continue
            n_total += 1
            filter_col = fields[6]
            info_col   = fields[7]

            if filter_col.upper() == "PASS":
                n_pass += 1

            svtype = "OTHER"
            for token in info_col.split(";"):
                if token.startswith("SVTYPE="):
                    svtype = token.split("=", 1)[1].upper()
                    break
            counts[svtype] += 1

    return {
        "n_svs_total": n_total,
        "n_pass":      n_pass,
        "n_ins":       counts.get("INS", 0),
        "n_del":       counts.get("DEL", 0),
        "n_dup":       counts.get("DUP", 0),
        "n_inv":       counts.get("INV", 0),
        "n_bnd":       counts.get("BND", 0),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vcf",          required=True, help="Path to VCF (plain or .vcf.gz)")
    ap.add_argument("--id-col",       required=True, help="ID column name (assay_id / specimen_id / patient_id)")
    ap.add_argument("--id-value",     required=True, help="ID value")
    ap.add_argument("--vcf-abs-path", default=None,  help="Absolute path to store in vcf_path column (defaults to --vcf)")
    ap.add_argument("--out",          default="sniffles2_summary.tsv", help="Output TSV path")
    args = ap.parse_args()

    vcf_path = Path(args.vcf)
    abs_path = args.vcf_abs_path or str(vcf_path.resolve())

    if not vcf_path.exists():
        logger.error("VCF not found: %s", vcf_path)
        return 1

    logger.info("Parsing VCF: %s", vcf_path)
    stats = parse_vcf(vcf_path)
    stats["vcf_path"] = abs_path

    cols   = [args.id_col] + list(stats.keys())
    values = [args.id_value] + [str(v) for v in stats.values()]

    with open(args.out, "w") as fh:
        fh.write("\t".join(cols) + "\n")
        fh.write("\t".join(values) + "\n")

    logger.info("Written: %s (%d SVs, %d PASS)", args.out, stats["n_svs_total"], stats["n_pass"])
    logger.info("=== DONE: summarize_sniffles.py completed successfully ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
