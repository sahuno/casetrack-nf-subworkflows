/*
 * SNIFFLES2_TRACKED — call SVs from long-read BAM + register with casetrack.
 *
 * Summary columns: n_svs_total, n_pass, n_ins, n_del, n_dup, n_inv, n_bnd, vcf_path.
 *
 * casetrack.toml declaration required:
 *   [analyses.sniffles2]
 *   level         = "assay"   # or "specimen"
 *   column_prefix = "sv"
 *   summary_tsv   = "sniffles2_summary.tsv"
 *   nf_process    = "SNIFFLES"
 */

include { SNIFFLES           } from '../../modules/nf-core/sniffles/main'
include { SUMMARIZE_SNIFFLES } from '../../modules/local/summarize_sniffles'
include { CASETRACK_REGISTER } from '../../modules/local/casetrack_register'

workflow SNIFFLES2_TRACKED {
    take:
    ch_bam_bai   // [ meta, bam, bai ]
    ch_ref        // [ meta2, fasta ] — pass [[:], []] for no reference
    ch_tandem     // [ meta3, bed ]   — pass [[:], []] for no tandem repeats

    main:
    SNIFFLES(
        ch_bam_bai,
        ch_ref,
        ch_tandem,
        true,   // vcf_output
        false,  // snf_output (population calling not needed for casetrack tracking)
    )

    // SNIFFLES emits vcf + tbi; both needed for SUMMARIZE_SNIFFLES.
    ch_vcf_tbi = SNIFFLES.out.vcf
        .join(SNIFFLES.out.tbi, by: 0)

    SUMMARIZE_SNIFFLES(ch_vcf_tbi)

    ch_register = SUMMARIZE_SNIFFLES.out.summary
        .map { meta, tsv -> tuple(meta, 'sniffles2', 'sniffles2_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    vcf            = SNIFFLES.out.vcf
    tbi            = SNIFFLES.out.tbi
    summary        = SUMMARIZE_SNIFFLES.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
