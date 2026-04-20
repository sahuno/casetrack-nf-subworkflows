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
include { MODKIT_MERGED_TRACKED  } from './subworkflows/local/modkit_merged_tracked.nf'

workflow {
    // Guard rails — fail fast before any heavy lifting starts.
    if (!params.input) error "--input <samplesheet.csv> is required"
    if (!params.casetrack_project_dir) error "--casetrack_project_dir is required"
    if (!params.run_tag) error "--run_tag is required (e.g. 20260418_hg38_v1)"
    if (!params.fasta && !workflow.stubRun) error "--fasta is required for non-stub runs"

    def level = params.casetrack_level ?: 'assay'
    if (!(level in ['assay', 'specimen', 'patient'])) {
        error "--casetrack_level must be one of: assay, specimen, patient (got '${level}')"
    }

    INPUT_CHECK(params.input, level)

    // Build the reference channel once, fan out to every MODKIT_PILEUP call.
    ch_fasta = params.fasta
        ? Channel.of([[id: 'ref'], file(params.fasta, checkIfExists: true),
                      file(params.fai, checkIfExists: true)]).first()
        : Channel.of([[id: 'ref'], [], []]).first()

    ch_bed = params.bed
        ? Channel.of([[id: 'regions'], file(params.bed, checkIfExists: true)]).first()
        : Channel.of([[id: 'regions'], []]).first()

    if (level == 'specimen') {
        MODKIT_MERGED_TRACKED(INPUT_CHECK.out.bam_bai, ch_fasta, ch_bed)
    } else {
        MODKIT_PILEUP_TRACKED(INPUT_CHECK.out.bam_bai, ch_fasta, ch_bed)
    }

    // L3 — collect the nf-core `topic: versions` channel to one YAML per run.
    // Format matches the nf-core convention; versions_to_casetrack.py parses
    // it in onComplete and writes {prefix}_tool_version columns.
    channel.topic('versions')
        .map { process, tool, version -> "${process}:\n    ${tool}: ${version}\n" }
        .unique()
        .collectFile(
            name: 'versions.yml',
            storeDir: "${params.casetrack_project_dir}/results/_nextflow/${params.run_tag}",
            sort: true,
        )
}

// L2 — on completion (success or failure), import Nextflow's execution
// trace into casetrack as per-assay metadata columns. Runs on the driver
// (where `nextflow run` was invoked), not on SLURM.
workflow.onComplete {
    log.info "Pipeline completed: ${workflow.success ? 'SUCCESS' : 'FAILED'}"
    log.info "casetrack project:  ${params.casetrack_project_dir}"
    log.info "run_tag:            ${params.run_tag}"

    if (!params.casetrack_import_trace) {
        log.info "casetrack trace import disabled (params.casetrack_import_trace=false)"
        return
    }

    def trace_path = "${params.casetrack_project_dir}/results/_nextflow/${params.run_tag}/execution_trace.txt"
    def trace_file = new File(trace_path)
    if (!trace_file.exists()) {
        log.warn "casetrack trace import: ${trace_path} not found — skipping"
        return
    }

    def trace_helper = "${projectDir}/bin/trace_to_casetrack.py"
    def trace_level = params.casetrack_level ?: 'assay'
    def trace_cmd = [
        trace_helper,
        '--project-dir',  params.casetrack_project_dir.toString(),
        '--trace',        trace_path,
        '--run-tag',      params.run_tag.toString(),
        '--level',        trace_level,
        '--casetrack-bin', params.casetrack_bin.toString(),
    ]
    log.info "casetrack trace import: ${trace_cmd.join(' ')}"
    def trace_proc = trace_cmd.execute()
    trace_proc.consumeProcessOutput(System.out, System.err)
    trace_proc.waitFor()
    if (trace_proc.exitValue() != 0) {
        log.warn "casetrack trace import exited with rc=${trace_proc.exitValue()}"
    }

    // L3 — versions import, uses the YAML emitted by `channel.topic('versions')
    // .collectFile(name: 'versions.yml', ...)` in the workflow block.
    if (params.casetrack_import_versions) {
        def versions_path = "${params.casetrack_project_dir}/results/_nextflow/${params.run_tag}/versions.yml"
        def versions_file = new File(versions_path)
        if (!versions_file.exists()) {
            log.warn "casetrack versions import: ${versions_path} not found — skipping"
        } else {
            // Collect IDs at the run's tracking level — versions are run-level,
            // broadcast to every row this run covered. Column to read from the
            // samplesheet depends on level (ADR-001).
            def level = params.casetrack_level ?: 'assay'
            def key_col = level == 'specimen' ? 'specimen'
                        : level == 'patient'  ? 'patient'
                        : 'assay_id'
            def lines = new File(params.input.toString()).readLines()
            def header = lines[0].split(',').toList()
            def key_idx = header.indexOf(key_col)
            if (key_idx < 0) {
                log.warn "casetrack versions import: samplesheet missing '${key_col}' column — skipping"
                return
            }
            def ids = lines
                .drop(1)
                .collect { it.split(',')[key_idx] }
                .findAll { it }
                .unique()
                .join(',')
            def versions_helper = "${projectDir}/bin/versions_to_casetrack.py"
            def versions_cmd = [
                versions_helper,
                '--project-dir',   params.casetrack_project_dir.toString(),
                '--versions',      versions_path,
                '--run-tag',       params.run_tag.toString(),
                '--assay-ids',     ids,
                '--level',         level,
                '--casetrack-bin', params.casetrack_bin.toString(),
            ]
            log.info "casetrack versions import: ${versions_cmd.join(' ')}"
            def vproc = versions_cmd.execute()
            vproc.consumeProcessOutput(System.out, System.err)
            vproc.waitFor()
            if (vproc.exitValue() != 0) {
                log.warn "casetrack versions import exited with rc=${vproc.exitValue()}"
            }
        }
    }
}
