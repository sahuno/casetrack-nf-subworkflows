#!/bin/bash
# test/run_test_malformed.sh — negative test: casetrack v0.6 hierarchy ID
# validation (proposal 0005 Part A) surfaces through the Nextflow
# integration's register step.
#
# Three scenarios:
#   1. Malformed samplesheet ID with whitespace → casetrack register exits
#      non-zero with a helpful error naming the offending value.
#   2. Case-variant ID conflict → registering HG006 then hg006 is rejected.
#   3. Custom id_pattern override in TOML lets legacy LIMS IDs with colons
#      through, so cohorts with pre-existing non-default IDs have an
#      escape hatch.
#
# No Nextflow invocation required — these scenarios fail before the pipeline
# would start, which is the point (errors surface at init, not three jobs in).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 0. prerequisites ─────────────────────────────────────────────────────────
command -v casetrack >/dev/null || { echo "ERROR: casetrack not on PATH"; exit 1; }
command -v sqlite3   >/dev/null || { echo "ERROR: sqlite3 not on PATH"; exit 1; }

TMPROOT="$(mktemp -d -t casetrack_nf_negative_XXXXXX)"
echo "== negative-test workspace: ${TMPROOT}"

# ── scenario 1: whitespace in patient_id ─────────────────────────────────────
echo
echo "== scenario 1: malformed patient_id (whitespace) should be rejected"
PROJ1="${TMPROOT}/proj_whitespace"
casetrack init --project-dir "${PROJ1}" --from-template hgsoc --bare > /dev/null

set +e
ERR_OUT="$(casetrack register --project-dir "${PROJ1}" --level patient \
              --id 'HG 006' --meta 'sex=M' 2>&1)"
RC=$?
set -e

if [[ ${RC} -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for whitespace id; got 0"
    exit 1
fi
if [[ "${ERR_OUT}" != *"HG 006"* ]] || [[ "${ERR_OUT}" != *"valid identifier"* ]]; then
    echo "FAIL: expected error naming 'HG 006' + 'valid identifier'"
    echo "actual: ${ERR_OUT}"
    exit 1
fi
echo "  OK — exit ${RC}, error mentions the offending value"

# ── scenario 2: case-variant conflict ────────────────────────────────────────
echo
echo "== scenario 2: case-variant (HG006 then hg006) should be rejected"
PROJ2="${TMPROOT}/proj_case_variant"
casetrack init --project-dir "${PROJ2}" --from-template hgsoc --bare > /dev/null
casetrack register --project-dir "${PROJ2}" --level patient --id HG006 \
    --meta 'sex=M' > /dev/null

set +e
ERR_OUT="$(casetrack register --project-dir "${PROJ2}" --level patient \
              --id hg006 --meta 'sex=M' 2>&1)"
RC=$?
set -e

if [[ ${RC} -eq 0 ]]; then
    echo "FAIL: expected non-zero exit for case-variant; got 0"
    exit 1
fi
if [[ "${ERR_OUT}" != *"hg006"* ]] || [[ "${ERR_OUT}" != *"HG006"* ]] \
        || [[ "${ERR_OUT}" != *"allow_case_variants"* ]]; then
    echo "FAIL: expected error naming both 'hg006' and 'HG006' + the allow flag"
    echo "actual: ${ERR_OUT}"
    exit 1
fi
echo "  OK — exit ${RC}, error cites the existing variant + escape hatch"

# ── scenario 3: custom id_pattern override accepts legacy LIMS IDs ───────────
echo
echo "== scenario 3: [levels.patient] id_pattern override allows colons"
PROJ3="${TMPROOT}/proj_custom_pattern"
casetrack init --project-dir "${PROJ3}" --from-template hgsoc --bare > /dev/null

# Add the escape-hatch override to casetrack.toml — loosens the default
# regex to accept colons (common in legacy LIMS IDs like MSK-001:2024).
python3 -c "
from pathlib import Path
p = Path('${PROJ3}/casetrack.toml')
t = p.read_text().splitlines()
for i, line in enumerate(t):
    if line.strip() == '[levels.patient]':
        t.insert(i + 1, 'id_pattern = \"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}\$\"')
        break
p.write_text('\n'.join(t) + '\n')
"

casetrack register --project-dir "${PROJ3}" --level patient \
    --id 'MSK-001:2024' --meta 'sex=M' > /dev/null
COUNT="$(sqlite3 "${PROJ3}/casetrack.db" \
    "SELECT COUNT(*) FROM patients WHERE patient_id='MSK-001:2024';")"
if [[ "${COUNT}" != "1" ]]; then
    echo "FAIL: expected MSK-001:2024 to land under id_pattern override; count=${COUNT}"
    exit 1
fi
echo "  OK — custom id_pattern accepted 'MSK-001:2024'"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "PASS — all negative scenarios behaved as expected"
echo "       workspace: ${TMPROOT}"
