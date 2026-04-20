#!/bin/bash
# test/run_test_dorado.sh — stub smoke test for DORADO_BASECALLER_TRACKED (C2).
#
# Uses assay level (dorado basecalls are per-assay / per-run).
# Runs `nextflow -stub` with --tool=dorado_basecaller.
# No GPU needed for stub.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

command -v nextflow  >/dev/null || { echo "ERROR: nextflow not on PATH"; exit 1; }
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_smoke_dorado_XXXXXX)"
PROJ="${TMPROOT}/proj"
RUN_TAG="20260420_hg38_dorado_v1"
TOOL="dorado_basecaller"
MODEL="dna_r10.4.1_e8.2_400bps_sup@v4.3.0"

export CASETRACK_REGISTRY="${TMPROOT}/registry.json"

echo "== smoke-test workspace: ${TMPROOT}"
cd "${TMPROOT}"

# ── 1. stub input files ──────────────────────────────────────────────────────
mkdir -p "${TMPROOT}/data/pod5s"
touch "${TMPROOT}/data/pod5s/reads.pod5"

# Assay-level samplesheet — pod5_dir in bam column.
cat > "${TMPROOT}/samplesheet.csv" <<CSV
patient,specimen,assay_id,genome,bam,bai
P01,P01_primary,P01_RUN001,hg38,${TMPROOT}/data/pod5s,
CSV

# ── 2. casetrack project ─────────────────────────────────────────────────────
casetrack init --project-dir "${PROJ}" --from-template hgsoc --bare

cat >> "${PROJ}/casetrack.toml" <<'TOML'

[analyses.dorado_basecaller]
level         = "assay"
column_prefix = "dorado"
summary_tsv   = "dorado_basecaller_summary.tsv"
nf_process    = "DORADO_BASECALLER"
TOML

casetrack register --project-dir "${PROJ}" --level patient  --id P01 \
    --meta 'age=55,sex=F'
casetrack register --project-dir "${PROJ}" --level specimen --id P01_primary \
    --parent P01 --meta 'tissue_site=tumor'
casetrack register --project-dir "${PROJ}" --level assay    --id P01_RUN001 \
    --parent P01_primary --meta 'assay_type=ONT'

# ── 3. nextflow run (stub — no GPU needed) ───────────────────────────────────
cd "${TMPROOT}"
nextflow run "${REPO}/main.nf" \
    -profile test \
    -stub \
    --input                  "${TMPROOT}/samplesheet.csv" \
    --casetrack_project_dir  "${PROJ}" \
    --casetrack_level        assay \
    --tool                   dorado_basecaller \
    --dorado_model           "${MODEL}" \
    --run_tag                "${RUN_TAG}" \
    -ansi-log false

# ── 4. L1 assertions ─────────────────────────────────────────────────────────
DB="${PROJ}/casetrack.db"
echo
echo "== asserting DB state (L1)"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT assay_id, dorado_basecaller_model, dorado_n_reads, dorado_n_bases, dorado_read_n50, dorado_pass_pct, dorado_mean_qscore, dorado_run_tag, dorado_basecaller_done FROM assays WHERE assay_id='P01_RUN001';"

SELECT() { sqlite3 "${DB}" "$@"; }

test "$(SELECT "SELECT dorado_basecaller_model FROM assays WHERE assay_id='P01_RUN001';")" = "${MODEL}" \
    || { echo "FAIL: expected dorado_basecaller_model=${MODEL}"; exit 1; }
test "$(SELECT "SELECT dorado_n_reads FROM assays WHERE assay_id='P01_RUN001';")" = "2" \
    || { echo "FAIL: expected dorado_n_reads=2"; exit 1; }
test "$(SELECT "SELECT dorado_run_tag FROM assays WHERE assay_id='P01_RUN001';")" = "${RUN_TAG}" \
    || { echo "FAIL: expected dorado_run_tag=${RUN_TAG}"; exit 1; }
test -n "$(SELECT "SELECT dorado_basecaller_done FROM assays WHERE assay_id='P01_RUN001';")" \
    || { echo "FAIL: dorado_basecaller_done is empty"; exit 1; }

# Leaf path at assay depth.
LEAF="${PROJ}/results/${TOOL}/${RUN_TAG}/P01/P01_primary/P01_RUN001"
test -f "${LEAF}/dorado_basecaller_summary.tsv" \
    || { echo "FAIL: summary TSV missing at ${LEAF}"; exit 1; }

# ── 5. L2 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting trace import (L2)"
TRACE="${PROJ}/results/_nextflow/${RUN_TAG}/execution_trace.txt"
test -f "${TRACE}" || { echo "FAIL: trace file missing at ${TRACE}"; exit 1; }

EXIT_STATUS=$(SELECT "SELECT dorado_exit_status FROM assays WHERE assay_id='P01_RUN001';")
test "${EXIT_STATUS}" = "0" \
    || { echo "FAIL: expected dorado_exit_status=0, got '${EXIT_STATUS}'"; exit 1; }

# ── 6. L3 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting versions import (L3)"
VERSIONS="${PROJ}/results/_nextflow/${RUN_TAG}/versions.yml"
test -f "${VERSIONS}" || { echo "FAIL: versions.yml missing at ${VERSIONS}"; exit 1; }

DORADO_VER=$(SELECT "SELECT dorado_dorado_version FROM assays WHERE assay_id='P01_RUN001';")
test -n "${DORADO_VER}" \
    || { echo "FAIL: dorado_dorado_version not populated on assays table"; exit 1; }
echo "dorado version recorded on assay row: ${DORADO_VER}"

echo
echo "PASS — DORADO_BASECALLER_TRACKED assay-level stub smoke test OK (L1 + L2 + L3)"
echo "       workspace: ${TMPROOT}"
