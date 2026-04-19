#!/usr/bin/env python3
"""Import a Nextflow execution trace into a casetrack project as per-assay
metadata columns (L2 of proposal 0004).

Reads the target project's casetrack.toml to discover which tools to track
(via ``[analyses.<tool>]``) and their column prefixes, parses the trace
file, keeps the last attempt per ``(tool, assay_id)`` pair, and invokes
``casetrack append --analysis <tool>_trace --column-prefix <prefix>`` once
per tool to write:

  {prefix}_slurm_job_id      TEXT     (Nextflow native_id; empty under local executor)
  {prefix}_realtime_sec      INTEGER  (realtime parsed from "1h30m", "5s", etc.)
  {prefix}_peak_rss_bytes    INTEGER  (peak_rss parsed from "500 MB", "2 GB")
  {prefix}_exit_status       INTEGER  (exit column; 0 on success)
  {prefix}_attempts          INTEGER  (max attempt seen for this (tool, assay_id))
  {prefix}_queue             TEXT     (queue the task ran on; may be empty)

Plus a ``{tool}_trace_done`` timestamp column auto-added by casetrack
append. ``append`` is used instead of ``add-metadata`` because trace
columns are not pre-declared in casetrack.toml — ``append`` auto-adds
them via ALTER TABLE; ``add-metadata`` refuses.

Any trace row whose process name does not match a declared ``[analyses.*]``
entry is silently skipped — that's how SUMMARIZE_<TOOL> and
CASETRACK_REGISTER bookkeeping processes are filtered out automatically.

Invoked from a Nextflow ``workflow.onComplete`` hook. Stdlib only (no
pandas / tomllib workarounds — requires Python ≥ 3.11 for ``tomllib``,
which is what casetrack itself requires).

Author: Samuel Ahuno <ekwame001@gmail.com>
"""
from __future__ import annotations

import argparse
import csv
import logging
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Iterable


# Casetrack uses different key column names per level; the trace TSV we hand
# to `casetrack append` must put the level-appropriate name in column 1.
_KEY_BY_LEVEL = {
    "patient":  "patient_id",
    "specimen": "specimen_id",
    "assay":    "assay_id",
}


# ── duration / byte-size parsers ──────────────────────────────────────────────

# Nextflow-style durations: "5ms", "1.5s", "2m", "1h30m", "1h 30m 5s"
_DURATION_UNITS = {
    "ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400,
}
_DURATION_RE = re.compile(r"(?P<n>\d+(?:\.\d+)?)\s*(?P<u>ms|s|m|h|d)")


def parse_duration_sec(s: str) -> int | None:
    """Parse Nextflow's duration format ("1h30m5s", "500ms", "-") → seconds.

    Returns None on "-", empty, or unparseable input.
    """
    if not s or s in ("-", "0"):
        return 0 if s == "0" else None
    total = 0.0
    for m in _DURATION_RE.finditer(s):
        total += float(m.group("n")) * _DURATION_UNITS[m.group("u")]
    if total == 0 and not _DURATION_RE.search(s):
        return None
    return int(round(total))


# Nextflow-style sizes: "500 MB", "2.5 GB", "100 KB", "1024"
_SIZE_UNITS = {
    "B":   1,
    "KB":  1024,             "K":   1024,
    "MB":  1024**2,          "M":   1024**2,
    "GB":  1024**3,          "G":   1024**3,
    "TB":  1024**4,          "T":   1024**4,
    "KiB": 1024,             "MiB": 1024**2,
    "GiB": 1024**3,          "TiB": 1024**4,
}
_SIZE_RE = re.compile(r"(?P<n>\d+(?:\.\d+)?)\s*(?P<u>B|[KMGT](?:i?B)?)?")


def parse_bytes(s: str) -> int | None:
    """Parse Nextflow's size format ("500 MB", "-", "0") → bytes.

    Returns None on "-", empty, or unparseable. Returns 0 for "0".
    """
    if not s or s == "-":
        return None
    if s == "0":
        return 0
    m = _SIZE_RE.fullmatch(s.strip())
    if not m:
        return None
    n = float(m.group("n"))
    u = (m.group("u") or "B").upper()
    # Normalize variants: "K" → "KB", "Ki" → "KIB" → "KIB" (map KiB explicitly)
    u = {"KIB": "KiB", "MIB": "MiB", "GIB": "GiB", "TIB": "TiB"}.get(u, u)
    mult = _SIZE_UNITS.get(u)
    if mult is None:
        return None
    return int(round(n * mult))


# ── main flow ─────────────────────────────────────────────────────────────────


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project-dir", required=True,
                   help="Casetrack project directory (contains casetrack.toml)")
    p.add_argument("--trace", required=True,
                   help="Path to Nextflow execution_trace.txt")
    p.add_argument("--run-tag", required=True,
                   help="Run identifier; used to namespace the provenance entry")
    p.add_argument("--level", default="assay",
                   choices=["patient", "specimen", "assay"],
                   help="Target casetrack level (default: assay)")
    p.add_argument("--casetrack-bin", default="casetrack",
                   help="casetrack CLI entry point")
    p.add_argument("--fill-only", action="store_true",
                   help="Use COALESCE (don't overwrite existing non-null cells)")
    p.add_argument("--dry-run", action="store_true",
                   help="Emit the metadata TSV but don't call casetrack add-metadata")
    return p.parse_args()


def load_tool_prefix_map(toml_path: Path) -> dict[str, str]:
    """Return a case-insensitive map from NF process name → column_prefix.

    Example: {'MODKIT_PILEUP': 'modkit', 'DORADO_BASECALLER': 'dorado'}
    """
    with open(toml_path, "rb") as f:
        schema = tomllib.load(f)
    analyses = schema.get("analyses") or {}
    out: dict[str, str] = {}
    for tool, spec in analyses.items():
        prefix = spec.get("column_prefix") or tool
        out[tool.upper()] = prefix
    return out


def tool_from_process(process_field: str) -> str:
    """Extract the last :SEGMENT from a Nextflow 'process' trace column.

    'MODKIT_PILEUP_TRACKED:MODKIT_PILEUP' → 'MODKIT_PILEUP'
    'MODKIT_PILEUP' → 'MODKIT_PILEUP'
    """
    return process_field.rsplit(":", 1)[-1].strip()


def read_trace_rows(trace_path: Path) -> Iterable[dict[str, str]]:
    with open(trace_path, newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            yield row


def collapse_to_last_attempt(rows: list[dict]) -> list[dict]:
    """Keep one row per (tool, assay_id) — the one with the latest 'complete'
    timestamp (falling back to max 'attempt', then last occurrence).
    """
    best: dict[tuple[str, str], dict] = {}
    for r in rows:
        key = (r["_tool"], r["_assay_id"])
        if key not in best:
            best[key] = r
            continue
        prev = best[key]
        # Compare by complete timestamp (lexicographic works for ISO-ish strings).
        if r.get("complete", "") > prev.get("complete", ""):
            best[key] = r
        elif r.get("complete", "") == prev.get("complete", ""):
            try:
                if int(r.get("attempt", "0")) > int(prev.get("attempt", "0")):
                    best[key] = r
            except ValueError:
                pass
    return list(best.values())


def build_per_tool_tsv(rows: list[dict], level: str) -> Path:
    """Emit a TSV for a single tool with one row per entity and UNprefixed
    metric columns. ``casetrack append --column-prefix <prefix>`` will add
    the prefix on the way in.

    The first column name is level-appropriate (``assay_id`` /
    ``specimen_id`` / ``patient_id``) because casetrack's ``append``
    validates that the level's key column exists in the TSV.

    Columns: <level_key>, slurm_job_id, realtime_sec, peak_rss_bytes,
             exit_status, attempts, queue.
    """
    cols = ["slurm_job_id", "realtime_sec", "peak_rss_bytes",
            "exit_status", "attempts", "queue"]
    key_col = _KEY_BY_LEVEL[level]
    tsv = Path(tempfile.mkstemp(prefix="casetrack_trace_", suffix=".tsv")[1])
    with open(tsv, "w") as fh:
        fh.write("\t".join([key_col] + cols) + "\n")
        for r in sorted(rows, key=lambda x: x["_assay_id"]):
            metrics = {
                "slurm_job_id":   r.get("native_id", "").strip() or "",
                "realtime_sec":   parse_duration_sec(r.get("realtime", "")),
                "peak_rss_bytes": parse_bytes(r.get("peak_rss", "")),
                "exit_status":    r.get("exit", "").strip() or "",
                "attempts":       r.get("attempt", "").strip() or "",
                "queue":          r.get("queue", "").strip() or "",
            }
            values = [r["_assay_id"]] + [
                "" if metrics[c] is None else str(metrics[c]) for c in cols
            ]
            fh.write("\t".join(values) + "\n")
    return tsv


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)s trace_to_casetrack: %(message)s",
    )
    log = logging.getLogger(__name__)

    project_dir = Path(args.project_dir).resolve()
    trace_path  = Path(args.trace).resolve()
    toml_path   = project_dir / "casetrack.toml"

    if not trace_path.exists():
        log.warning("trace file not found: %s — skipping import", trace_path)
        return 0
    if not toml_path.exists():
        log.error("casetrack.toml not found at %s", toml_path)
        return 2

    prefix_map = load_tool_prefix_map(toml_path)
    if not prefix_map:
        log.warning("no [analyses.*] entries in %s — nothing to import", toml_path)
        return 0

    # Parse trace.txt, tagging each row with its (tool, assay_id) or dropping it.
    kept: list[dict] = []
    dropped = 0
    for r in read_trace_rows(trace_path):
        tool = tool_from_process(r.get("process", "")).upper()
        if tool not in prefix_map:
            dropped += 1
            continue
        aid = (r.get("tag") or "").strip()
        if not aid:
            dropped += 1
            continue
        r["_tool"] = tool
        r["_assay_id"] = aid
        kept.append(r)

    log.info("trace rows kept=%d dropped=%d (processes tracked: %s)",
             len(kept), dropped, sorted(prefix_map.keys()))

    if not kept:
        log.warning("no matching trace rows; nothing to write")
        return 0

    collapsed = collapse_to_last_attempt(kept)
    log.info("collapsed to %d (tool, assay) pairs", len(collapsed))

    # One `casetrack append` per tool — separate analyses keep the trace
    # `_done` timestamp (e.g. modkit_pileup_trace_done) disjoint from the
    # tool's own data _done, and give each tool its own ALTER TABLE.
    by_tool: dict[str, list[dict]] = {}
    for r in collapsed:
        by_tool.setdefault(r["_tool"], []).append(r)

    overall_rc = 0
    for tool_upper, tool_rows in sorted(by_tool.items()):
        prefix = prefix_map[tool_upper]
        tool_lower = tool_upper.lower()
        analysis_name = f"{tool_lower}_trace"

        tsv = build_per_tool_tsv(tool_rows, args.level)
        log.info("tool=%s prefix=%s rows=%d tsv=%s level=%s",
                 tool_lower, prefix, len(tool_rows), tsv, args.level)

        if args.dry_run:
            log.info("--dry-run: skipping casetrack append for %s", tool_lower)
            tsv.unlink()
            continue

        cmd = [
            args.casetrack_bin, "append",
            "--project-dir", str(project_dir),
            "--level", args.level,
            "--results", str(tsv),
            "--analysis", analysis_name,
            "--column-prefix", prefix,
            "--col-type",
                "slurm_job_id:TEXT,realtime_sec:INTEGER,"
                "peak_rss_bytes:INTEGER,exit_status:INTEGER,"
                "attempts:INTEGER,queue:TEXT",
        ]
        if not args.fill_only:
            cmd.append("--overwrite")

        log.info("invoking: %s", " ".join(cmd))
        try:
            rc = subprocess.run(cmd, check=False).returncode
        finally:
            try:
                tsv.unlink()
            except OSError:
                pass
        if rc != 0:
            log.error("casetrack append failed for %s with rc=%d", tool_lower, rc)
            overall_rc = rc

    if overall_rc == 0:
        log.info("trace import complete (run_tag=%s)", args.run_tag)
    return overall_rc


if __name__ == "__main__":
    sys.exit(main())
