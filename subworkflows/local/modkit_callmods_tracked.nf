/*
 * MODKIT_CALLMODS_TRACKED — re-call methylation on basecalled BAM + register.
 *
 * Output is a BAM with MM/ML tags (not a bedMethyl). A downstream
 * MODKIT_PILEUP_TRACKED run produces per-site methylation stats.
 *
 * casetrack.toml declaration required:
 *   [analyses.modkit_callmods]
 *   level         = "assay"   # or "specimen"
 *   column_prefix = "callmods"
 *   summary_tsv   = "modkit_callmods_summary.tsv"
 *   nf_process    = "MODKIT_CALLMODS"
 */

include { MODKIT_CALLMODS    } from '../../modules/nf-core/modkit/callmods/main'
include { SUMMARIZE_CALLMODS } from '../../modules/local/summarize_callmods'
include { CASETRACK_REGISTER } from '../../modules/local/casetrack_register'

workflow MODKIT_CALLMODS_TRACKED {
    take:
    ch_bam     // [ meta, bam ]

    main:
    MODKIT_CALLMODS(ch_bam)

    // Join bam + log on meta for SUMMARIZE_CALLMODS.
    ch_bam_log = MODKIT_CALLMODS.out.bam
        .join(MODKIT_CALLMODS.out.log, by: 0)

    SUMMARIZE_CALLMODS(
        ch_bam_log.map { meta, bam, log -> tuple(meta, bam) },
        ch_bam_log.map { meta, bam, log -> tuple(meta, log) },
    )

    ch_register = SUMMARIZE_CALLMODS.out.summary
        .map { meta, tsv -> tuple(meta, 'modkit_callmods', 'modkit_callmods_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    bam            = MODKIT_CALLMODS.out.bam
    summary        = SUMMARIZE_CALLMODS.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
