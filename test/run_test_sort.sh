#!/bin/bash
# test/run_test_sort.sh — stub smoke test for SAMTOOLS_SORT_TRACKED (C1).
#
# Creates a casetrack project with one patient + one specimen (no assay),
# writes a specimen-level samplesheet, runs `nextflow -stub` with
# --tool=samtools_sort --casetrack_level=specimen, then asserts L1/L2/L3.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

command -v nextflow  >/dev/null || { echo "ERROR: nextflow not on PATH"; exit 1; }
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_smoke_sort_XXXXXX)"
PROJ="${TMPROOT}/proj"
RUN_TAG="20260420_hg38_sort_v1"
TOOL="samtools_sort"

# Isolate registry per run.
export CASETRACK_REGISTRY="${TMPROOT}/registry.json"

echo "== smoke-test workspace: ${TMPROOT}"
cd "${TMPROOT}"

# ── 1. stub input files ──────────────────────────────────────────────────────
mkdir -p "${TMPROOT}/data"
: > "${TMPROOT}/data/stub.bam"
: > "${TMPROOT}/data/stub.bam.bai"

# Specimen-level samplesheet — no assay_id (ADR-001 D2).
cat > "${TMPROOT}/samplesheet.csv" <<CSV
patient,specimen,genome,bam,bai
P01,P01_primary,hg38,${TMPROOT}/data/stub.bam,${TMPROOT}/data/stub.bam.bai
CSV

# ── 2. casetrack project + [analyses.samtools_sort] declaration ──────────────
casetrack init --project-dir "${PROJ}" --from-template hgsoc --bare

cat >> "${PROJ}/casetrack.toml" <<'TOML'

[analyses.samtools_sort]
level         = "specimen"
column_prefix = "sort"
summary_tsv   = "samtools_sort_summary.tsv"
nf_process    = "SAMTOOLS_SORT"
TOML

casetrack register --project-dir "${PROJ}" --level patient  --id P01 \
    --meta 'age=55,sex=F'
casetrack register --project-dir "${PROJ}" --level specimen --id P01_primary \
    --parent P01 --meta 'tissue_site=tumor'

# ── 3. nextflow run — no --fasta needed for sort ─────────────────────────────
cd "${TMPROOT}"
nextflow run "${REPO}/main.nf" \
    -profile test \
    -stub \
    --input                  "${TMPROOT}/samplesheet.csv" \
    --casetrack_project_dir  "${PROJ}" \
    --casetrack_level        specimen \
    --tool                   samtools_sort \
    --run_tag                "${RUN_TAG}" \
    -ansi-log false

# ── 4. assertions — L1 (data columns on specimens table) ────────────────────
DB="${PROJ}/casetrack.db"
echo
echo "== asserting DB state (L1)"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT specimen_id, sort_sorted_bam_path, sort_sorted_bam_size_bytes, sort_n_reads, sort_sort_order, sort_run_tag, samtools_sort_done FROM specimens WHERE specimen_id='P01_primary';"

SELECT() { sqlite3 "${DB}" "$@"; }

test -n "$(SELECT "SELECT sort_sorted_bam_path FROM specimens WHERE specimen_id='P01_primary';")" \
    || { echo "FAIL: sort_sorted_bam_path is empty"; exit 1; }
test "$(SELECT "SELECT sort_sorted_bam_size_bytes FROM specimens WHERE specimen_id='P01_primary';")" = "1024" \
    || { echo "FAIL: expected sort_sorted_bam_size_bytes=1024"; exit 1; }
test "$(SELECT "SELECT sort_n_reads FROM specimens WHERE specimen_id='P01_primary';")" = "100" \
    || { echo "FAIL: expected sort_n_reads=100"; exit 1; }
test "$(SELECT "SELECT sort_run_tag FROM specimens WHERE specimen_id='P01_primary';")" = "${RUN_TAG}" \
    || { echo "FAIL: expected sort_run_tag=${RUN_TAG}"; exit 1; }
test -n "$(SELECT "SELECT samtools_sort_done FROM specimens WHERE specimen_id='P01_primary';")" \
    || { echo "FAIL: samtools_sort_done is empty"; exit 1; }

# Leaf path at specimen depth (no assay_id component).
LEAF="${PROJ}/results/${TOOL}/${RUN_TAG}/P01/P01_primary"
test -f "${LEAF}/samtools_sort_summary.tsv" \
    || { echo "FAIL: summary TSV missing at ${LEAF}"; exit 1; }
test ! -e "${LEAF}/P01_primary" \
    || { echo "FAIL: unexpected extra depth — leaf should stop at specimen"; exit 1; }

# assays table must be empty (specimen-level run).
ASSAYS_ROW_COUNT=$(SELECT "SELECT COUNT(*) FROM assays;")
test "${ASSAYS_ROW_COUNT}" = "0" \
    || { echo "FAIL: assays table should be empty at specimen level, got ${ASSAYS_ROW_COUNT}"; exit 1; }

# ── 5. L2 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting trace import (L2)"
TRACE="${PROJ}/results/_nextflow/${RUN_TAG}/execution_trace.txt"
test -f "${TRACE}" || { echo "FAIL: trace file missing at ${TRACE}"; exit 1; }

sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT sort_exit_status, sort_attempts FROM specimens WHERE specimen_id='P01_primary';"

EXIT_STATUS=$(SELECT "SELECT sort_exit_status FROM specimens WHERE specimen_id='P01_primary';")
# Stub runs report exit_status=0 in trace.
test "${EXIT_STATUS}" = "0" \
    || { echo "FAIL: expected sort_exit_status=0, got '${EXIT_STATUS}'"; exit 1; }

# ── 6. L3 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting versions import (L3)"
VERSIONS="${PROJ}/results/_nextflow/${RUN_TAG}/versions.yml"
test -f "${VERSIONS}" || { echo "FAIL: versions.yml missing at ${VERSIONS}"; exit 1; }

SAMTOOLS_VER=$(SELECT "SELECT sort_samtools_version FROM specimens WHERE specimen_id='P01_primary';")
test -n "${SAMTOOLS_VER}" \
    || { echo "FAIL: sort_samtools_version not populated on specimens table"; exit 1; }
echo "samtools version recorded on specimen row: ${SAMTOOLS_VER}"

echo
echo "== full specimen row (sort columns)"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT sort_sorted_bam_path, sort_sorted_bam_size_bytes, sort_n_reads, sort_sort_order, sort_exit_status, sort_samtools_version FROM specimens WHERE specimen_id='P01_primary';"

echo
echo "PASS — SAMTOOLS_SORT_TRACKED specimen-level stub smoke test OK (L1 + L2 + L3)"
echo "       workspace: ${TMPROOT}"
