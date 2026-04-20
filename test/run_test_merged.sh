#!/bin/bash
# test/run_test_merged.sh — stub smoke test for MODKIT_MERGED_TRACKED
# (specimen-level L1 wrapper — ADR-001).
#
# Creates a casetrack project with one patient + one specimen (no assay),
# writes a specimen-level samplesheet (no assay_id column), runs
# `nextflow -stub` with --casetrack_level=specimen, asserts the row
# landed in the `specimens` table.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

command -v nextflow  >/dev/null || { echo "ERROR: nextflow not on PATH"; exit 1; }
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_smoke_merged_XXXXXX)"
PROJ="${TMPROOT}/proj"
RUN_TAG="20260420_hg38_merged_v1"
TOOL="modkit_merged"

# Isolate the registry per smoke-test run so stale entries from other
# projects don't collide with the local 'proj' id.
export CASETRACK_REGISTRY="${TMPROOT}/registry.json"

echo "== smoke-test workspace: ${TMPROOT}"
cd "${TMPROOT}"

# ── 1. stub input files ──────────────────────────────────────────────────────
mkdir -p "${TMPROOT}/data"
: > "${TMPROOT}/data/stub.fa"
: > "${TMPROOT}/data/stub.fa.fai"
: > "${TMPROOT}/data/stub.merged.bam"
: > "${TMPROOT}/data/stub.merged.bam.bai"

# Specimen-level samplesheet — no assay_id column (ADR-001 D2).
cat > "${TMPROOT}/samplesheet.csv" <<CSV
patient,specimen,genome,bam,bai
P01,P01_primary,hg38,${TMPROOT}/data/stub.merged.bam,${TMPROOT}/data/stub.merged.bam.bai
CSV

# ── 2. casetrack project + [analyses.modkit_merged] declaration ─────────────
casetrack init --project-dir "${PROJ}" --from-template hgsoc --bare

cat >> "${PROJ}/casetrack.toml" <<'TOML'

[analyses.modkit_merged]
level         = "specimen"
column_prefix = "modkit_merged"
summary_tsv   = "modkit_merged_summary.tsv"
# Wrapper-renamed analysis: the nextflow process is still the stock
# MODKIT_PILEUP module; nf_process tells the L2/L3 importers that trace/
# versions rows tagged MODKIT_PILEUP belong to this analysis.
nf_process    = "MODKIT_PILEUP"
TOML

casetrack register --project-dir "${PROJ}" --level patient  --id P01 \
    --meta 'age=55,sex=F'
casetrack register --project-dir "${PROJ}" --level specimen --id P01_primary \
    --parent P01 --meta 'tissue_site=tumor'

# ── 3. nextflow run ──────────────────────────────────────────────────────────
cd "${TMPROOT}"
nextflow run "${REPO}/main.nf" \
    -profile test \
    -stub \
    --input                  "${TMPROOT}/samplesheet.csv" \
    --fasta                  "${TMPROOT}/data/stub.fa" \
    --fai                    "${TMPROOT}/data/stub.fa.fai" \
    --casetrack_project_dir  "${PROJ}" \
    --casetrack_level        specimen \
    --run_tag                "${RUN_TAG}" \
    -ansi-log false

# ── 4. assertions — L1 (data columns landed on specimens table) ──────────────
DB="${PROJ}/casetrack.db"
echo
echo "== asserting DB state"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT specimen_id, modkit_merged_mean_meth, modkit_merged_n_cpgs, modkit_merged_mean_cov, modkit_merged_run_tag, modkit_merged_done FROM specimens WHERE specimen_id='P01_primary';"

SELECT() { sqlite3 "${DB}" "$@"; }

test "$(SELECT "SELECT modkit_merged_mean_meth FROM specimens WHERE specimen_id='P01_primary';")" = "0.72" \
    || { echo "FAIL: expected modkit_merged_mean_meth=0.72"; exit 1; }
test "$(SELECT "SELECT modkit_merged_run_tag FROM specimens WHERE specimen_id='P01_primary';")" = "${RUN_TAG}" \
    || { echo "FAIL: expected modkit_merged_run_tag=${RUN_TAG}"; exit 1; }
test -n "$(SELECT "SELECT modkit_merged_done FROM specimens WHERE specimen_id='P01_primary';")" \
    || { echo "FAIL: modkit_merged_done is empty"; exit 1; }

# Assert the leaf directory was created at the specimen depth (no assay_id
# component) — this is the core ADR-001 D4 behavior.
LEAF="${PROJ}/results/${TOOL}/${RUN_TAG}/P01/P01_primary"
test -f "${LEAF}/modkit_merged_summary.tsv" \
    || { echo "FAIL: summary TSV missing at ${LEAF}"; exit 1; }
# And confirm no rogue assay-depth leaf leaked.
test ! -e "${LEAF}/P01_primary" \
    || { echo "FAIL: unexpected extra depth — leaf should stop at specimen"; exit 1; }

# Nothing should have landed on the assays table (no assay_id was provided).
ASSAYS_ROW_COUNT=$(SELECT "SELECT COUNT(*) FROM assays;")
test "${ASSAYS_ROW_COUNT}" = "0" \
    || { echo "FAIL: assays table should be empty at specimen level, got ${ASSAYS_ROW_COUNT}"; exit 1; }

# ── 5. L2 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting trace import (L2)"
TRACE="${PROJ}/results/_nextflow/${RUN_TAG}/execution_trace.txt"
test -f "${TRACE}" || { echo "FAIL: trace file missing at ${TRACE}"; exit 1; }

sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT modkit_merged_exit_status, modkit_merged_attempts FROM specimens WHERE specimen_id='P01_primary';"

EXIT_STATUS=$(SELECT "SELECT modkit_merged_exit_status FROM specimens WHERE specimen_id='P01_primary';")
test "${EXIT_STATUS}" = "0" \
    || { echo "FAIL: expected modkit_merged_exit_status=0, got '${EXIT_STATUS}'"; exit 1; }

# ── 6. L3 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting versions import (L3)"
VERSIONS="${PROJ}/results/_nextflow/${RUN_TAG}/versions.yml"
test -f "${VERSIONS}" || { echo "FAIL: versions.yml missing at ${VERSIONS}"; exit 1; }

MODKIT_VER=$(SELECT "SELECT modkit_merged_modkit_version FROM specimens WHERE specimen_id='P01_primary';")
test -n "${MODKIT_VER}" \
    || { echo "FAIL: modkit_merged_modkit_version not populated on specimens table"; exit 1; }
echo "modkit version recorded on specimen row: ${MODKIT_VER}"

echo
echo "PASS — specimen-level stub smoke test OK (L1 + L2 + L3)"
echo "       workspace: ${TMPROOT}"
