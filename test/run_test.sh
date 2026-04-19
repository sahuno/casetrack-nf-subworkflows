#!/bin/bash
# test/run_test.sh — end-to-end stub smoke test for the tracked subworkflows.
#
# Creates a fresh casetrack project in a temp dir, generates a stub
# samplesheet with absolute paths, runs `nextflow -stub` against it,
# then asserts the row landed in the project's SQLite DB with the
# expected modkit_* columns (including the auto-injected modkit_run_tag).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# ── 0. prerequisites ─────────────────────────────────────────────────────────
command -v nextflow  >/dev/null || { echo "ERROR: nextflow not on PATH"; exit 1; }
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_smoke_XXXXXX)"
PROJ="${TMPROOT}/proj"
RUN_TAG="20260418_hg38_v1"
TOOL="modkit_pileup"

echo "== smoke-test workspace: ${TMPROOT}"
cd "${TMPROOT}"

# ── 1. stub input files (empty — -stub short-circuits the tool) ──────────────
mkdir -p "${TMPROOT}/data"
: > "${TMPROOT}/data/stub.fa"
: > "${TMPROOT}/data/stub.fa.fai"
: > "${TMPROOT}/data/stub.bam"
: > "${TMPROOT}/data/stub.bam.bai"

cat > "${TMPROOT}/samplesheet.csv" <<CSV
patient,specimen,assay_id,genome,bam,bai
P01,P01_primary,P01_primary_ONT1,hg38,${TMPROOT}/data/stub.bam,${TMPROOT}/data/stub.bam.bai
CSV

# ── 2. fresh casetrack project + [analyses.modkit_pileup] declaration ───────
casetrack init --project-dir "${PROJ}" --from-template hgsoc --bare

cat >> "${PROJ}/casetrack.toml" <<'TOML'

[analyses.modkit_pileup]
level         = "assay"
column_prefix = "modkit"
summary_tsv   = "modkit_summary.tsv"
TOML

# Register the single stub assay hierarchy.
casetrack register --project-dir "${PROJ}" --level patient  --id P01 \
    --meta 'age=55,sex=F'
casetrack register --project-dir "${PROJ}" --level specimen --id P01_primary \
    --parent P01 --meta 'tissue_site=tumor'
casetrack register --project-dir "${PROJ}" --level assay    --id P01_primary_ONT1 \
    --parent P01_primary --meta 'assay_type=ONT'

# ── 3. nextflow run ──────────────────────────────────────────────────────────
cd "${TMPROOT}"
nextflow run "${REPO}/main.nf" \
    -profile test \
    -stub \
    --input                  "${TMPROOT}/samplesheet.csv" \
    --fasta                  "${TMPROOT}/data/stub.fa" \
    --fai                    "${TMPROOT}/data/stub.fa.fai" \
    --casetrack_project_dir  "${PROJ}" \
    --run_tag                "${RUN_TAG}" \
    -ansi-log false

# ── 4. assertions ────────────────────────────────────────────────────────────
DB="${PROJ}/casetrack.db"
echo
echo "== asserting DB state"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT assay_id, modkit_mean_meth, modkit_n_cpgs, modkit_median_cov, modkit_run_tag, modkit_pileup_done FROM assays WHERE assay_id='P01_primary_ONT1';"

SELECT() { sqlite3 "${DB}" "$@"; }

test "$(SELECT "SELECT modkit_mean_meth FROM assays WHERE assay_id='P01_primary_ONT1';")" = "0.72" \
    || { echo "FAIL: expected modkit_mean_meth=0.72"; exit 1; }
test "$(SELECT "SELECT modkit_run_tag FROM assays WHERE assay_id='P01_primary_ONT1';")" = "${RUN_TAG}" \
    || { echo "FAIL: expected modkit_run_tag=${RUN_TAG}"; exit 1; }
test -n "$(SELECT "SELECT modkit_pileup_done FROM assays WHERE assay_id='P01_primary_ONT1';")" \
    || { echo "FAIL: modkit_pileup_done is empty"; exit 1; }

LEAF="${PROJ}/results/${TOOL}/${RUN_TAG}/P01/P01_primary/P01_primary_ONT1"
test -f "${LEAF}/modkit_summary.tsv" \
    || { echo "FAIL: summary TSV missing at ${LEAF}"; exit 1; }

echo
echo "PASS — stub smoke test OK"
echo "       workspace: ${TMPROOT}"
