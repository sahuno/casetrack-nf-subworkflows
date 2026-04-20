/*
 * dorado_basecaller.nf — local module; no nf-core equivalent at time of writing.
 *
 * Inputs:
 *   tuple val(meta), path(pod5_dir)   — meta.id is the assay-level ID;
 *                                       pod5_dir is the directory of .pod5 files.
 *   val(model)                         — dorado model string, e.g. "dna_r10.4.1_e8.2_400bps_sup@v4.3.0"
 *
 * Outputs:
 *   bam        — aligned+modcalled BAM (if ref provided) or unaligned BAM
 *   summary    — dorado summary TSV (one row per read, used for QC)
 *   versions   — topic:versions entry
 */

process DORADO_BASECALLER {
    tag "${meta.id}"
    label 'process_high_gpu'

    container 'docker.io/nanoporetech/dorado:latest'

    // GPU resources declared via task.ext.args in custom.config:
    //   withName: 'DORADO_BASECALLER_TRACKED:DORADO_BASECALLER' {
    //       clusterOptions = '--gres=gpu:1'
    //       memory = '0'   // let SLURM assign all node memory to avoid mem conflict
    //   }

    input:
    tuple val(meta), path(pod5_dir)
    val(model)
    tuple val(meta_ref), path(fasta)   // pass [[:],[]] for unaligned output

    output:
    tuple val(meta), path("${prefix}.bam"),     emit: bam
    tuple val(meta), path("${prefix}_summary.tsv"), emit: summary
    tuple val("${task.process}"), val('dorado'), eval("dorado --version 2>&1 | head -1 | sed 's/dorado //'"), topic: versions, emit: versions_dorado

    when:
    task.ext.when == null || task.ext.when

    script:
    def args     = task.ext.args ?: ''
    prefix       = task.ext.prefix ?: "${meta.id}"
    def ref_flag = fasta ? "--reference ${fasta}" : ""
    """
    dorado basecaller \\
        ${args} \\
        ${model} \\
        ${pod5_dir} \\
        ${ref_flag} \\
        --device cuda:all \\
        > ${prefix}.bam

    dorado summary ${prefix}.bam > ${prefix}_summary.tsv
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.bam
    printf 'filename\\tread_id\\trun_id\\tchannel\\tmux\\tminknow_events\\ttemplated_length\\tsequence_length_template\\tmean_qscore_template\\tn50\\n' > ${prefix}_summary.tsv
    printf 'stub.pod5\\tstub-read-id\\tstub-run\\t1\\t1\\t1000\\t1000\\t1200\\t15.5\\t12000\\n' >> ${prefix}_summary.tsv
    printf 'stub.pod5\\tstub-read-id-2\\tstub-run\\t2\\t1\\t800\\t800\\t900\\t14.2\\t11000\\n' >> ${prefix}_summary.tsv
    """
}
