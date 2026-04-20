/*
 * summarize_sniffles.nf — parse Sniffles2 VCF and emit one-row casetrack TSV.
 *
 * Summary columns: <id_col>, n_svs_total, n_pass, n_ins, n_del, n_dup,
 *                  n_inv, n_bnd, vcf_path.
 * Uses bin/summarize_sniffles.py (stdlib-only, no container dependency).
 */

process SUMMARIZE_SNIFFLES {
    tag "${meta.id}"
    label 'process_single'

    // Python 3 stdlib only — use the lightweight python container.
    container 'https://depot.galaxyproject.org/singularity/python:3.12'

    input:
    tuple val(meta), path(vcf_gz), path(tbi)

    output:
    tuple val(meta), path("sniffles2_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    def abs_vcf = "\$(readlink -f ${vcf_gz})"
    """
    python3 ${projectDir}/bin/summarize_sniffles.py \\
        --vcf          "${vcf_gz}" \\
        --id-col       "${id_col}" \\
        --id-value     "${id_value}" \\
        --vcf-abs-path "${abs_vcf}" \\
        --out          sniffles2_summary.tsv
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    printf '${id_col}\\tn_svs_total\\tn_pass\\tn_ins\\tn_del\\tn_dup\\tn_inv\\tn_bnd\\tvcf_path\\n' > sniffles2_summary.tsv
    printf '%s\\t42\\t38\\t15\\t12\\t5\\t3\\t7\\t/stub/path.vcf.gz\\n' '${id_value}' >> sniffles2_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
