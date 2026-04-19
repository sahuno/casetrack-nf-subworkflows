/*
 * main.nf — demo pipeline: MODKIT_PILEUP for every row in the samplesheet,
 *           with casetrack bookkeeping on each output.
 *
 * Run (full):
 *   nextflow run main.nf \\
 *       --input       test/samplesheet.csv \\
 *       --fasta       /path/to/reference.fa \\
 *       --fai         /path/to/reference.fa.fai \\
 *       --casetrack_project_dir /abs/path/to/project \\
 *       --run_tag     20260418_hg38_v1 \\
 *       -profile      slurm,apptainer
 *
 * Run (stub smoke test):
 *   bash test/run_test.sh
 */

nextflow.enable.dsl = 2

include { INPUT_CHECK            } from './subworkflows/local/input_check.nf'
include { MODKIT_PILEUP_TRACKED  } from './subworkflows/local/modkit_pileup_tracked.nf'

workflow {
    // Guard rails — fail fast before any heavy lifting starts.
    if (!params.input) error "--input <samplesheet.csv> is required"
    if (!params.casetrack_project_dir) error "--casetrack_project_dir is required"
    if (!params.run_tag) error "--run_tag is required (e.g. 20260418_hg38_v1)"
    if (!params.fasta && !workflow.stubRun) error "--fasta is required for non-stub runs"

    INPUT_CHECK(params.input)

    // Build the reference channel once, fan out to every MODKIT_PILEUP call.
    ch_fasta = params.fasta
        ? Channel.of([[id: 'ref'], file(params.fasta, checkIfExists: true),
                      file(params.fai, checkIfExists: true)]).first()
        : Channel.of([[id: 'ref'], [], []]).first()

    ch_bed = params.bed
        ? Channel.of([[id: 'regions'], file(params.bed, checkIfExists: true)]).first()
        : Channel.of([[id: 'regions'], []]).first()

    MODKIT_PILEUP_TRACKED(INPUT_CHECK.out.bam_bai, ch_fasta, ch_bed)
}

workflow.onComplete {
    log.info "Pipeline completed: ${workflow.success ? 'SUCCESS' : 'FAILED'}"
    log.info "casetrack project:  ${params.casetrack_project_dir}"
    log.info "run_tag:            ${params.run_tag}"
}
