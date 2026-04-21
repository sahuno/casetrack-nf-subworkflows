/*
 * summarize_sort.nf — emit a one-row TSV for samtools_sort.
 * Level-aware key via _resolve_key (same helper as summarize_modkit.nf).
 */

process SUMMARIZE_SORT {
    tag "${meta.id}"
    label 'process_single'

    container 'https://depot.galaxyproject.org/singularity/samtools:1.21--h50ea8bc_0'

    input:
    tuple val(meta), path(bam)

    output:
    tuple val(meta), path("samtools_sort_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    N_READS=\$(samtools view -c "${bam}")
    SIZE=\$(stat -c %s "${bam}")
    SORT_ORDER=\$(samtools view -H "${bam}" | awk '/^@HD/{for(i=1;i<=NF;i++){if(\$i~/^SO:/){split(\$i,a,":");print a[2];exit}}}')
    DEST="${params.casetrack_project_dir}/data/processed/${meta.genome}/${meta.patient}/${meta.id}/${meta.id}.${meta.genome}.sorted.bam"
    printf '${id_col}\\tsorted_bam_path\\tsorted_bam_size_bytes\\tn_reads\\tsort_order\\n' > samtools_sort_summary.tsv
    printf '%s\\t%s\\t%s\\t%s\\t%s\\n' '${id_value}' "\$DEST" "\$SIZE" "\$N_READS" "\${SORT_ORDER:-unknown}" >> samtools_sort_summary.tsv
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    printf '${id_col}\\tsorted_bam_path\\tsorted_bam_size_bytes\\tn_reads\\tsort_order\\n' > samtools_sort_summary.tsv
    printf '%s\\t/stub/path.bam\\t1024\\t100\\tcoordinate\\n' '${id_value}' >> samtools_sort_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
