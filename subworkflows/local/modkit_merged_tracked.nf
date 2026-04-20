/*
 * MODKIT_MERGED_TRACKED — specimen-level MODKIT_PILEUP + casetrack bookkeeping.
 *
 * Mirrors MODKIT_PILEUP_TRACKED but keys on specimen_id instead of assay_id.
 * Intended for pipelines that merge per-flowcell BAMs into one specimen-level
 * BAM upstream, then call modkit pileup on the merged file.
 *
 * The nf-core module is imported unchanged from modules/nf-core/modkit/pileup/
 * (`nf-core modules update` stays safe). The summarize + register processes
 * read `params.casetrack_level` and adapt their output schema + path
 * template accordingly (see ADR-001).
 *
 * Required params:
 *   params.casetrack_project_dir   : absolute path to the casetrack project
 *   params.run_tag                 : {date}_{genome}_{description}
 *   params.casetrack_level         : must be "specimen" when using this wrapper
 *   params.casetrack_bin           : casetrack CLI entry point (default: 'casetrack')
 *
 * The project's casetrack.toml must declare:
 *
 *   [analyses.modkit_merged]
 *   level         = "specimen"
 *   column_prefix = "modkit_merged"
 *   summary_tsv   = "modkit_merged_summary.tsv"
 *
 * Input channel shape:
 *   ch_bam_bai : [ meta, merged_bam, bai ]
 *     meta = [id, patient, specimen, genome] where meta.id == meta.specimen
 *            (no assay_id — this is the whole point of the merged wrapper)
 */

include { MODKIT_PILEUP       } from '../../modules/nf-core/modkit/pileup/main.nf'
include { SUMMARIZE_MODKIT    } from '../../modules/local/summarize_modkit.nf'
include { CASETRACK_REGISTER  } from '../../modules/local/casetrack_register.nf'

workflow MODKIT_MERGED_TRACKED {
    take:
    ch_bam_bai   // [ meta, merged_bam, bai ] — specimen-keyed
    ch_fasta     // [ meta2, fasta, fai ]
    ch_bed       // [ meta3, bed ] (may be empty)

    main:
    // Phase 1: stock nf-core module on the merged specimen-level BAM.
    MODKIT_PILEUP(ch_bam_bai, ch_fasta, ch_bed)

    // Phase 2: per-specimen summary TSV. SUMMARIZE_MODKIT reads
    // params.casetrack_level internally to pick the right key column.
    SUMMARIZE_MODKIT(MODKIT_PILEUP.out.bedgz)

    // Phase 3: register with casetrack at specimen level. CASETRACK_REGISTER
    // reads params.casetrack_level and writes to the matching leaf depth.
    ch_register = SUMMARIZE_MODKIT.out.summary
        .map { meta, tsv -> tuple(meta, 'modkit_merged', 'modkit_merged_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    bedgz          = MODKIT_PILEUP.out.bedgz
    summary        = SUMMARIZE_MODKIT.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
