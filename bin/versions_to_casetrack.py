#!/usr/bin/env python3
"""Import nf-core tool versions into a casetrack project (L3 of proposal 0004).

Reads the nf-core-style ``versions.yml`` that every module emits via the
``topic: versions`` channel, matches each process name against the target
project's ``[analyses.<tool>]`` declarations, and writes one
``{prefix}_tool_version`` column per tracked tool.

Tool versions are run-level metadata, not per-assay facts — the same
version applies to every assay that used it. To keep the schema simple
we store the version on every assay row (it's a TEXT column, cheap) and
leave historical per-run version history to the provenance log +
Nextflow's ``versions.yml`` next to the run's trace files.

Invoked from the same ``workflow.onComplete`` hook as L2.

Example versions.yml (nf-core convention):

    MODKIT_PILEUP_TRACKED:MODKIT_PILEUP:
        modkit: 0.6.1
    MODKIT_PILEUP_TRACKED:SUMMARIZE_MODKIT:
        python: 3.13.0

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


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project-dir", required=True,
                   help="Casetrack project directory (contains casetrack.toml)")
    p.add_argument("--versions", required=True,
                   help="Path to nf-core versions.yml (or a concatenation thereof)")
    p.add_argument("--run-tag", required=True,
                   help="Run identifier; recorded in provenance")
    p.add_argument("--assay-ids", required=True,
                   help="Comma-separated list of assay_ids to update — these "
                        "rows get {prefix}_tool_version columns filled.")
    p.add_argument("--level", default="assay",
                   choices=["patient", "specimen", "assay"])
    p.add_argument("--casetrack-bin", default="casetrack")
    p.add_argument("--fill-only", action="store_true",
                   help="Use COALESCE (don't overwrite non-null cells)")
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def load_tool_prefix_map(toml_path: Path) -> dict[str, str]:
    """NF process name (upper) → column_prefix."""
    with open(toml_path, "rb") as f:
        schema = tomllib.load(f)
    analyses = schema.get("analyses") or {}
    return {
        tool.upper(): (spec.get("column_prefix") or tool)
        for tool, spec in analyses.items()
    }


# versions.yml is a minimal subset of YAML — we parse it without PyYAML so
# this script stays stdlib-only. Each top-level key is a process name
# (e.g. "MODKIT_PILEUP_TRACKED:MODKIT_PILEUP:"). Nested entries are
# "  tool: version". Blank lines separate blocks.

_KEY_RE   = re.compile(r"^([A-Za-z][\w:]*?):\s*$")
_ENTRY_RE = re.compile(r"^\s+([\w\-.]+):\s*(['\"]?)([^'\"]+?)\2\s*$")


def parse_versions_yml(path: Path) -> dict[str, dict[str, str]]:
    """Return {PROCESS_NAME: {tool_name: version, ...}}."""
    out: dict[str, dict[str, str]] = {}
    current: str | None = None
    with open(path) as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if m := _KEY_RE.match(line):
                current = m.group(1)
                out.setdefault(current, {})
                continue
            if m := _ENTRY_RE.match(line):
                if current is None:
                    continue
                tool, _, version = m.group(1), m.group(2), m.group(3).strip()
                out[current][tool] = version
    return out


def tool_from_process(process_name: str) -> str:
    """'MODKIT_PILEUP_TRACKED:MODKIT_PILEUP' → 'MODKIT_PILEUP'."""
    return process_name.rsplit(":", 1)[-1].strip()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)s versions_to_casetrack: %(message)s",
    )
    log = logging.getLogger(__name__)

    project_dir  = Path(args.project_dir).resolve()
    versions_yml = Path(args.versions).resolve()
    toml_path    = project_dir / "casetrack.toml"

    if not versions_yml.exists():
        log.warning("versions file not found: %s — skipping", versions_yml)
        return 0
    if not toml_path.exists():
        log.error("casetrack.toml not found at %s", toml_path)
        return 2

    prefix_map = load_tool_prefix_map(toml_path)
    if not prefix_map:
        log.warning("no [analyses.*] entries in %s", toml_path)
        return 0

    parsed = parse_versions_yml(versions_yml)
    log.info("parsed %d process block(s) from %s", len(parsed), versions_yml)

    assay_ids = [a.strip() for a in args.assay_ids.split(",") if a.strip()]
    if not assay_ids:
        log.warning("--assay-ids is empty; nothing to write")
        return 0

    # For each tracked tool: collect versions from any matching process block
    # and emit one `casetrack append --analysis <tool>_versions` call.
    overall_rc = 0
    wrote_any = False
    for process_name, tools in sorted(parsed.items()):
        short = tool_from_process(process_name).upper()
        if short not in prefix_map:
            continue
        prefix = prefix_map[short]
        tool_lower = short.lower()

        # Collect per-tool versions; use underscore-separated column names
        # to match casetrack's identifier rules.
        cols = {}
        for tool, ver in tools.items():
            safe_tool = re.sub(r"[^A-Za-z0-9_]", "_", tool)
            cols[f"{safe_tool}_version"] = ver

        if not cols:
            continue

        tsv = Path(tempfile.mkstemp(
            prefix=f"casetrack_versions_{tool_lower}_", suffix=".tsv")[1])
        colnames = sorted(cols.keys())
        with open(tsv, "w") as fh:
            fh.write("\t".join(["assay_id"] + colnames) + "\n")
            for aid in assay_ids:
                fh.write("\t".join([aid] + [cols[c] for c in colnames]) + "\n")
        log.info("tool=%s prefix=%s versions=%s tsv=%s",
                 tool_lower, prefix, cols, tsv)

        if args.dry_run:
            log.info("--dry-run: skipping casetrack append")
            tsv.unlink()
            continue

        col_types = ",".join(f"{c}:TEXT" for c in colnames)
        cmd = [
            args.casetrack_bin, "append",
            "--project-dir", str(project_dir),
            "--level", args.level,
            "--results", str(tsv),
            "--analysis", f"{tool_lower}_versions",
            "--column-prefix", prefix,
            "--col-type", col_types,
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
        else:
            wrote_any = True

    if not wrote_any and overall_rc == 0:
        log.info("no tracked tools had versions in %s", versions_yml)
    elif overall_rc == 0:
        log.info("versions import complete (run_tag=%s)", args.run_tag)
    return overall_rc


if __name__ == "__main__":
    sys.exit(main())
