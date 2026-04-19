/*
 * casetrack_register.nf — canonical "register results" step for every
 *                         tracked subworkflow.
 *
 * Places a summary TSV at the tool-first path prescribed by the project's
 * casetrack.toml [layout.path_templates], then runs
 * `casetrack append --infer-from-path` from that leaf. The summary filename
 * MUST match [analyses.<tool>].summary_tsv declared in the project TOML.
 *
 * Runs on the local executor with maxForks=1: casetrack serializes its own
 * writes through SQLite WAL + busy_timeout, but a throttle keeps provenance
 * logs readable and avoids log-line interleaving under heavy fan-in.
 */

process CASETRACK_REGISTER {
    tag "${tool}:${meta.id}"
    executor 'local'
    maxForks 1
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(meta), val(tool), val(summary_name), path(summary_tsv)

    output:
    tuple val(meta), val(tool), emit: ok

    when:
    task.ext.when == null || task.ext.when

    script:
    def bin = params.casetrack_bin ?: 'casetrack'
    def proj = params.casetrack_project_dir
    def run_tag = params.run_tag
    if (!proj)    error "params.casetrack_project_dir is required"
    if (!run_tag) error "params.run_tag is required"
    """
    set -euo pipefail
    LEAF="${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}/${meta.assay_id}"
    mkdir -p "\$LEAF"
    # Stage the summary under the name [analyses.<tool>].summary_tsv expects.
    cp -f "${summary_tsv}" "\$LEAF/${summary_name}"
    cd "\$LEAF"
    ${bin} append --infer-from-path
    """

    stub:
    def bin = params.casetrack_bin ?: 'casetrack'
    def proj = params.casetrack_project_dir
    def run_tag = params.run_tag
    """
    set -euo pipefail
    LEAF="${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}/${meta.assay_id}"
    mkdir -p "\$LEAF"
    cp -f "${summary_tsv}" "\$LEAF/${summary_name}"
    cd "\$LEAF"
    ${bin} append --infer-from-path
    """
}
