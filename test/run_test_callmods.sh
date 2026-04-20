#!/bin/bash
# test/run_test_callmods.sh — stub smoke test for MODKIT_CALLMODS_TRACKED (C3).
#
# Uses assay level (call-mods is per-basecalled assay).
# Runs `nextflow -stub` with --tool=modkit_callmods.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

command -v nextflow  >/dev/null || { echo "ERROR: nextflow not on PATH"; exit 1; }
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_smoke_callmods_XXXXXX)"
PROJ="${TMPROOT}/proj"
RUN_TAG="20260420_hg38_callmods_v1"
TOOL="modkit_callmods"

export CASETRACK_REGISTRY="${TMPROOT}/registry.json"

echo "== smoke-test workspace: ${TMPROOT}"
cd "${TMPROOT}"

# ── 1. stub input files ──────────────────────────────────────────────────────
mkdir -p "${TMPROOT}/data"
: > "${TMPROOT}/data/stub.bam"
: > "${TMPROOT}/data/stub.bam.bai"

cat > "${TMPROOT}/samplesheet.csv" <<CSV
patient,specimen,assay_id,genome,bam,bai
P01,P01_primary,P01_A001,hg38,${TMPROOT}/data/stub.bam,${TMPROOT}/data/stub.bam.bai
CSV

# ── 2. casetrack project ─────────────────────────────────────────────────────
casetrack init --project-dir "${PROJ}" --from-template hgsoc --bare

cat >> "${PROJ}/casetrack.toml" <<'TOML'

[analyses.modkit_callmods]
level         = "assay"
column_prefix = "callmods"
summary_tsv   = "modkit_callmods_summary.tsv"
nf_process    = "MODKIT_CALLMODS"
TOML

casetrack register --project-dir "${PROJ}" --level patient  --id P01 \
    --meta 'age=55,sex=F'
casetrack register --project-dir "${PROJ}" --level specimen --id P01_primary \
    --parent P01 --meta 'tissue_site=tumor'
casetrack register --project-dir "${PROJ}" --level assay    --id P01_A001 \
    --parent P01_primary --meta 'assay_type=ONT'

# ── 3. nextflow run ──────────────────────────────────────────────────────────
cd "${TMPROOT}"
nextflow run "${REPO}/main.nf" \
    -profile test \
    -stub \
    --input                  "${TMPROOT}/samplesheet.csv" \
    --casetrack_project_dir  "${PROJ}" \
    --casetrack_level        assay \
    --tool                   modkit_callmods \
    --run_tag                "${RUN_TAG}" \
    -ansi-log false

# ── 4. L1 assertions ─────────────────────────────────────────────────────────
DB="${PROJ}/casetrack.db"
echo
echo "== asserting DB state (L1)"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT assay_id, callmods_callmods_model, callmods_n_reads, callmods_n_skipped, callmods_n_failed, callmods_run_tag, modkit_callmods_done FROM assays WHERE assay_id='P01_A001';"

SELECT() { sqlite3 "${DB}" "$@"; }

test "$(SELECT "SELECT callmods_n_reads FROM assays WHERE assay_id='P01_A001';")" = "500" \
    || { echo "FAIL: expected callmods_n_reads=500"; exit 1; }
test "$(SELECT "SELECT callmods_n_skipped FROM assays WHERE assay_id='P01_A001';")" = "10" \
    || { echo "FAIL: expected callmods_n_skipped=10"; exit 1; }
test "$(SELECT "SELECT callmods_run_tag FROM assays WHERE assay_id='P01_A001';")" = "${RUN_TAG}" \
    || { echo "FAIL: expected callmods_run_tag=${RUN_TAG}"; exit 1; }
test -n "$(SELECT "SELECT modkit_callmods_done FROM assays WHERE assay_id='P01_A001';")" \
    || { echo "FAIL: modkit_callmods_done is empty"; exit 1; }

# Leaf path at assay depth.
LEAF="${PROJ}/results/${TOOL}/${RUN_TAG}/P01/P01_primary/P01_A001"
test -f "${LEAF}/modkit_callmods_summary.tsv" \
    || { echo "FAIL: summary TSV missing at ${LEAF}"; exit 1; }

# ── 5. L2 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting trace import (L2)"
TRACE="${PROJ}/results/_nextflow/${RUN_TAG}/execution_trace.txt"
test -f "${TRACE}" || { echo "FAIL: trace file missing at ${TRACE}"; exit 1; }

EXIT_STATUS=$(SELECT "SELECT callmods_exit_status FROM assays WHERE assay_id='P01_A001';")
test "${EXIT_STATUS}" = "0" \
    || { echo "FAIL: expected callmods_exit_status=0, got '${EXIT_STATUS}'"; exit 1; }

# ── 6. L3 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting versions import (L3)"
VERSIONS="${PROJ}/results/_nextflow/${RUN_TAG}/versions.yml"
test -f "${VERSIONS}" || { echo "FAIL: versions.yml missing at ${VERSIONS}"; exit 1; }

MODKIT_VER=$(SELECT "SELECT callmods_modkit_version FROM assays WHERE assay_id='P01_A001';")
test -n "${MODKIT_VER}" \
    || { echo "FAIL: callmods_modkit_version not populated on assays table"; exit 1; }
echo "modkit version recorded on assay row: ${MODKIT_VER}"

echo
echo "PASS — MODKIT_CALLMODS_TRACKED assay-level stub smoke test OK (L1 + L2 + L3)"
echo "       workspace: ${TMPROOT}"
