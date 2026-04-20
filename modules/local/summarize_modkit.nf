/*
 * summarize_modkit.nf — distill a modkit pileup bedMethyl into a one-row
 *                       summary TSV keyed on assay_id.
 *
 * Output columns: assay_id, mean_meth, n_cpgs, mean_cov
 *
 * These map to modkit_mean_meth / modkit_n_cpgs / modkit_mean_cov after
 * casetrack's --column-prefix rename. Summarize is streaming (single pass,
 * constant memory) so chr21 WGS pileups (~55M rows) work at 2 GB. The TSV filename matches
 * [analyses.modkit_pileup].summary_tsv = "modkit_summary.tsv" in the
 * project's casetrack.toml.
 */

process SUMMARIZE_MODKIT {
    tag "${meta.id}"
    label 'process_single'

    input:
    tuple val(meta), path(bedgz)

    output:
    tuple val(meta), path("modkit_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def min_cov = task.ext.min_coverage ?: 5
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    summarize_modkit.py \\
        --bedmethyl ${bedgz} \\
        --id-col ${id_col} \\
        --id-value ${id_value} \\
        --output modkit_summary.tsv \\
        --min-coverage ${min_cov}
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    printf '${id_col}\\tmean_meth\\tn_cpgs\\tmean_cov\\n' > modkit_summary.tsv
    printf '%s\\t0.7200\\t1500\\t18.00\\n' '${id_value}' >> modkit_summary.tsv
    """
}

// Level → (id_col, id_value). Mirrors casetrack_register.nf's _resolve_leaf
// so the TSV key lines up with the SQLite primary key at that level.
def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
