#!/bin/bash
# 00_init_project.sh — idempotent casetrack project setup for the pilot.
# Run once before the first invocation of run.sh.

set -euo pipefail

PROJ="${PROJ:-/data1/greenbab/users/ahunos/projects/casetrack_giab_pilot}"

if [[ -f "${PROJ}/casetrack.toml" ]]; then
    echo "Project exists at ${PROJ}; skipping init (delete to re-init)."
else
    casetrack init --project-dir "${PROJ}" --from-template giab_ont --bare
fi

# Append the [analyses.modkit_pileup] declaration if not already present.
if ! grep -q '^\[analyses.modkit_pileup\]' "${PROJ}/casetrack.toml"; then
    cat >> "${PROJ}/casetrack.toml" <<'TOML'

[analyses.modkit_pileup]
level         = "assay"
column_prefix = "modkit"
summary_tsv   = "modkit_summary.tsv"
TOML
    echo "Added [analyses.modkit_pileup] to casetrack.toml"
fi

# Register HG006 hierarchy. `casetrack register` is idempotent: re-registering
# an existing id prints a warning but does not error.
casetrack register --project-dir "${PROJ}" --level patient  --id HG006 \
    --meta 'sex=M,trio_role=proband,cohort=GIAB' || true
casetrack register --project-dir "${PROJ}" --level specimen --id HG006_gDNA \
    --parent HG006 --meta 'specimen_type=whole_genome_dna,cell_line=GM24694,source=NIST' || true
casetrack register --project-dir "${PROJ}" --level assay    --id HG006_PAY77227 \
    --parent HG006_gDNA --meta 'assay_type=ONT_WGS,flowcell_id=PAY77227,chemistry=R10.4.1' || true

echo
echo "Project ready at: ${PROJ}"
echo "Run: bash run.sh"
