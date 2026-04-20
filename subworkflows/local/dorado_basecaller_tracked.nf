/*
 * DORADO_BASECALLER_TRACKED — basecall pod5 → BAM + register with casetrack.
 *
 * GPU wrapper. Requires SLURM profile with --gres=gpu:1 on the DORADO_BASECALLER
 * process (set via custom.config withName: 'DORADO_BASECALLER_TRACKED:DORADO_BASECALLER').
 *
 * casetrack.toml declaration required:
 *   [analyses.dorado_basecaller]
 *   level         = "assay"
 *   column_prefix = "dorado"
 *   summary_tsv   = "dorado_basecaller_summary.tsv"
 *   nf_process    = "DORADO_BASECALLER"
 */

include { DORADO_BASECALLER  } from '../../modules/local/dorado_basecaller'
include { SUMMARIZE_DORADO   } from '../../modules/local/summarize_dorado'
include { CASETRACK_REGISTER } from '../../modules/local/casetrack_register'

workflow DORADO_BASECALLER_TRACKED {
    take:
    ch_pod5    // [ meta, pod5_dir ]
    ch_model   // val — dorado model string, e.g. params.dorado_model
    ch_ref     // [ meta2, fasta ] — pass [[:], []] for unaligned output

    main:
    DORADO_BASECALLER(ch_pod5, ch_model, ch_ref)

    // Join BAM + summary on meta so SUMMARIZE_DORADO gets both.
    ch_bam_summary = DORADO_BASECALLER.out.bam
        .join(DORADO_BASECALLER.out.summary, by: 0)

    SUMMARIZE_DORADO(
        ch_bam_summary.map { meta, bam, tsv -> tuple(meta, bam) },
        ch_bam_summary.map { meta, bam, tsv -> tuple(meta, tsv) },
        ch_model,
    )

    ch_register = SUMMARIZE_DORADO.out.summary
        .map { meta, tsv -> tuple(meta, 'dorado_basecaller', 'dorado_basecaller_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    bam            = DORADO_BASECALLER.out.bam
    summary        = SUMMARIZE_DORADO.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
