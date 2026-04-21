/*
 * casetrack_register.nf — canonical "register results" step for every
 *                         tracked subworkflow.
 *
 * Places a summary TSV at the tool-first path prescribed by the project's
 * casetrack.toml [layout.path_templates], then runs
 * `casetrack append --infer-from-path` from that leaf. The summary filename
 * MUST match [analyses.<tool>].summary_tsv declared in the project TOML.
 *
 * Level-aware (ADR-001). `params.casetrack_level` ∈ {assay, specimen, patient}
 * picks which path template applies. The leaf shape matches the
 * [layout.path_templates.<level>] declared in every v0.5+ casetrack project:
 *
 *   assay    → results/{tool}/{run_tag}/{patient}/{specimen}/{assay_id}
 *   specimen → results/{tool}/{run_tag}/{patient}/{specimen}
 *   patient  → results/{tool}/{run_tag}/{patient}
 *
 * `casetrack append --infer-from-path` recovers the level from path depth,
 * so no explicit --level flag is needed here.
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
    def level = params.casetrack_level ?: 'assay'
    if (!proj)    error "params.casetrack_project_dir is required"
    if (!run_tag) error "params.run_tag is required"
    def leaf = _resolve_leaf(proj, tool, run_tag, level, meta)
    """
    set -euo pipefail
    LEAF="${leaf}"
    mkdir -p "\$LEAF"
    cp -f "${summary_tsv}" "\$LEAF/${summary_name}"
    cd "\$LEAF"
    ${bin} append --infer-from-path --overwrite
    """

    stub:
    def bin = params.casetrack_bin ?: 'casetrack'
    def proj = params.casetrack_project_dir
    def run_tag = params.run_tag
    def level = params.casetrack_level ?: 'assay'
    def leaf = _resolve_leaf(proj, tool, run_tag, level, meta)
    """
    set -euo pipefail
    LEAF="${leaf}"
    mkdir -p "\$LEAF"
    cp -f "${summary_tsv}" "\$LEAF/${summary_name}"
    cd "\$LEAF"
    ${bin} append --infer-from-path --overwrite
    """
}

// Level → leaf path. Kept at file scope so both script: and stub: can use it.
def _resolve_leaf(proj, tool, run_tag, level, meta) {
    if (level == 'assay') {
        return "${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}/${meta.assay_id}"
    } else if (level == 'specimen') {
        return "${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}"
    } else if (level == 'patient') {
        return "${proj}/results/${tool}/${run_tag}/${meta.patient}"
    } else {
        error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
    }
}
