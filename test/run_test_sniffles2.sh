#!/bin/bash
# test/run_test_sniffles2.sh — stub smoke test for SNIFFLES2_TRACKED (C4).
#
# Assay level. Runs `nextflow -stub` with --tool=sniffles2.
# Stub VCF has no data rows → n_svs_total=0 (expected for stub).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

command -v nextflow  >/dev/null || { echo "ERROR: nextflow not on PATH"; exit 1; }
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_smoke_sniffles_XXXXXX)"
PROJ="${TMPROOT}/proj"
RUN_TAG="20260420_hg38_sniffles_v1"
TOOL="sniffles2"

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

[analyses.sniffles2]
level         = "assay"
column_prefix = "sv"
summary_tsv   = "sniffles2_summary.tsv"
nf_process    = "SNIFFLES"
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
    --tool                   sniffles2 \
    --run_tag                "${RUN_TAG}" \
    -ansi-log false

# ── 4. L1 assertions ─────────────────────────────────────────────────────────
DB="${PROJ}/casetrack.db"
echo
echo "== asserting DB state (L1)"
sqlite3 -header -separator ' | ' "${DB}" \
    "SELECT assay_id, sv_n_svs_total, sv_n_pass, sv_n_ins, sv_n_del, sv_n_dup, sv_n_inv, sv_n_bnd, sv_vcf_path, sv_run_tag, sniffles2_done FROM assays WHERE assay_id='P01_A001';"

SELECT() { sqlite3 "${DB}" "$@"; }

# Stub SUMMARIZE_SNIFFLES emits stub values (42 SVs, 38 PASS).
test "$(SELECT "SELECT sv_n_svs_total FROM assays WHERE assay_id='P01_A001';")" = "42" \
    || { echo "FAIL: expected sv_n_svs_total=42 (stub value)"; exit 1; }
test "$(SELECT "SELECT sv_n_pass FROM assays WHERE assay_id='P01_A001';")" = "38" \
    || { echo "FAIL: expected sv_n_pass=38 (stub value)"; exit 1; }
test "$(SELECT "SELECT sv_run_tag FROM assays WHERE assay_id='P01_A001';")" = "${RUN_TAG}" \
    || { echo "FAIL: expected sv_run_tag=${RUN_TAG}"; exit 1; }
test -n "$(SELECT "SELECT sniffles2_done FROM assays WHERE assay_id='P01_A001';")" \
    || { echo "FAIL: sniffles2_done is empty"; exit 1; }

# Leaf path at assay depth.
LEAF="${PROJ}/results/${TOOL}/${RUN_TAG}/P01/P01_primary/P01_A001"
test -f "${LEAF}/sniffles2_summary.tsv" \
    || { echo "FAIL: summary TSV missing at ${LEAF}"; exit 1; }

# ── 5. L2 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting trace import (L2)"
TRACE="${PROJ}/results/_nextflow/${RUN_TAG}/execution_trace.txt"
test -f "${TRACE}" || { echo "FAIL: trace file missing at ${TRACE}"; exit 1; }

EXIT_STATUS=$(SELECT "SELECT sv_exit_status FROM assays WHERE assay_id='P01_A001';")
test "${EXIT_STATUS}" = "0" \
    || { echo "FAIL: expected sv_exit_status=0, got '${EXIT_STATUS}'"; exit 1; }

# ── 6. L3 assertions ─────────────────────────────────────────────────────────
echo
echo "== asserting versions import (L3)"
VERSIONS="${PROJ}/results/_nextflow/${RUN_TAG}/versions.yml"
test -f "${VERSIONS}" || { echo "FAIL: versions.yml missing at ${VERSIONS}"; exit 1; }

SNIFFLES_VER=$(SELECT "SELECT sv_sniffles_version FROM assays WHERE assay_id='P01_A001';")
test -n "${SNIFFLES_VER}" \
    || { echo "FAIL: sv_sniffles_version not populated on assays table"; exit 1; }
echo "sniffles version recorded on assay row: ${SNIFFLES_VER}"

echo
echo "PASS — SNIFFLES2_TRACKED assay-level stub smoke test OK (L1 + L2 + L3)"
echo "       workspace: ${TMPROOT}"
