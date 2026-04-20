/*
 * summarize_callmods.nf — parse modkit call-mods log + emit one-row TSV.
 *
 * Summary columns: callmods_model, n_reads, n_skipped, n_failed, <id_col>.
 * The log file emitted by modkit call-mods contains lines like:
 *   [INFO] processed N reads, skipped M reads, failed F reads
 * We parse that with awk; fall back to 0 if not found (stub runs emit empty log).
 */

process SUMMARIZE_CALLMODS {
    tag "${meta.id}"
    label 'process_single'

    container 'https://depot.galaxyproject.org/singularity/ont-modkit:0.6.1--hcdda2d0_0'

    input:
    tuple val(meta), path(bam)
    tuple val(meta2), path(log_file)

    output:
    tuple val(meta), path("modkit_callmods_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    def args   = task.ext.args ?: ''
    // Extract model from args (--model <path>); record basename only.
    def model_flag = args =~ /--model\s+(\S+)/
    def model_val  = model_flag ? new File(model_flag[0][1]).name : 'unknown'
    """
    N_READS=\$(awk '/processed [0-9]+ reads/{n=\$2}END{print (n=="")?0:n}' "${log_file}")
    N_SKIP=\$(awk '/skipped [0-9]+ reads/{n=\$2}END{print (n=="")?0:n}' "${log_file}")
    N_FAIL=\$(awk '/failed [0-9]+ reads/{n=\$2}END{print (n=="")?0:n}' "${log_file}")
    printf '${id_col}\\tcallmods_model\\tn_reads\\tn_skipped\\tn_failed\\n' > modkit_callmods_summary.tsv
    printf '%s\\t${model_val}\\t%s\\t%s\\t%s\\n' '${id_value}' "\$N_READS" "\$N_SKIP" "\$N_FAIL" >> modkit_callmods_summary.tsv
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    def args   = task.ext.args ?: ''
    def model_flag = args =~ /--model\s+(\S+)/
    def model_val  = model_flag ? new File(model_flag[0][1]).name : 'unknown'
    """
    printf '${id_col}\\tcallmods_model\\tn_reads\\tn_skipped\\tn_failed\\n' > modkit_callmods_summary.tsv
    printf '%s\\t${model_val}\\t500\\t10\\t2\\n' '${id_value}' >> modkit_callmods_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
