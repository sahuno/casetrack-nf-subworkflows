/*
 * SAMTOOLS_SORT_TRACKED — coordinate-sort a BAM + register with casetrack.
 *
 * Pass-through wrapper: the sort itself has no biological meaning
 * (just reorders records), so the summary only records that the sort
 * completed and where the output landed.
 *
 * casetrack.toml declaration required:
 *   [analyses.samtools_sort]
 *   level         = "specimen"  # or "assay"
 *   column_prefix = "sort"
 *   summary_tsv   = "samtools_sort_summary.tsv"
 *   nf_process    = "SAMTOOLS_SORT"
 */

include { SAMTOOLS_SORT      } from '../../modules/nf-core/samtools/sort/main'
include { SUMMARIZE_SORT     } from '../../modules/local/summarize_sort'
include { CASETRACK_REGISTER } from '../../modules/local/casetrack_register'

workflow SAMTOOLS_SORT_TRACKED {
    take:
    ch_bam     // [ meta, bam ]

    main:
    SAMTOOLS_SORT(ch_bam, [[id:'ref'], [], []], '')   // no ref needed for coordinate sort

    SUMMARIZE_SORT(SAMTOOLS_SORT.out.bam)

    ch_register = SUMMARIZE_SORT.out.summary
        .map { meta, tsv -> tuple(meta, 'samtools_sort', 'samtools_sort_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    sorted_bam     = SAMTOOLS_SORT.out.bam
    summary        = SUMMARIZE_SORT.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
