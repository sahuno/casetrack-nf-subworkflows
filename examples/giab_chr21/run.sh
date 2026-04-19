#!/bin/bash
# run.sh — launch MODKIT_PILEUP_TRACKED on the HG006 chr21 BAM.
# Prereq: bash 00_init_project.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

PROJ="${PROJ:-/data1/greenbab/users/ahunos/projects/casetrack_giab_pilot}"
RUN_TAG="${RUN_TAG:-20260419_hg38_modkit_v1}"
FASTA="${FASTA:-/data1/greenbab/database/hg38/v0/Homo_sapiens_assembly38.fasta}"
FAI="${FAI:-${FASTA}.fai}"

if [[ ! -f "${PROJ}/casetrack.toml" ]]; then
    echo "ERROR: casetrack project not found at ${PROJ}"
    echo "Run: bash 00_init_project.sh"
    exit 1
fi

# Keep the workdir + .nextflow state next to the samplesheet so runs are
# self-contained.
cd "${HERE}"

nextflow run "${REPO}/main.nf" \
    -profile slurm,apptainer \
    -c "${HERE}/custom.config" \
    --input                 "${HERE}/samplesheet.csv" \
    --fasta                 "${FASTA}" \
    --fai                   "${FAI}" \
    --casetrack_project_dir "${PROJ}" \
    --run_tag               "${RUN_TAG}" \
    -ansi-log false
