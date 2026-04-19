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
    """
    summarize_modkit.py \\
        --bedmethyl ${bedgz} \\
        --assay-id ${meta.assay_id} \\
        --output modkit_summary.tsv \\
        --min-coverage ${min_cov}
    """

    stub:
    """
    printf 'assay_id\\tmean_meth\\tn_cpgs\\tmean_cov\\n' > modkit_summary.tsv
    printf '%s\\t0.7200\\t1500\\t18.00\\n' '${meta.assay_id}' >> modkit_summary.tsv
    """
}
