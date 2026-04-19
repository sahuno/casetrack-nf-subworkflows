/*
 * MODKIT_PILEUP_TRACKED — nf-core MODKIT_PILEUP + casetrack bookkeeping.
 *
 * Takes the same three input channels as the stock nf-core module, runs
 * it unchanged, distills the output to a one-row summary TSV, then
 * registers that row via casetrack.
 *
 * The nf-core module is imported from the vendored copy under
 * modules/nf-core/modkit/pileup/ so `nf-core modules update` can refresh
 * it without touching this wrapper.
 *
 * Required params:
 *   params.casetrack_project_dir    : absolute path to the casetrack project
 *   params.run_tag                  : {date}_{genome}_{description}
 *   params.casetrack_bin            : casetrack CLI entry point (default: 'casetrack')
 *
 * The project's casetrack.toml must declare:
 *
 *   [analyses.modkit_pileup]
 *   level         = "assay"
 *   column_prefix = "modkit"
 *   summary_tsv   = "modkit_summary.tsv"
 */

include { MODKIT_PILEUP       } from '../../modules/nf-core/modkit/pileup/main.nf'
include { SUMMARIZE_MODKIT    } from '../../modules/local/summarize_modkit.nf'
include { CASETRACK_REGISTER  } from '../../modules/local/casetrack_register.nf'

workflow MODKIT_PILEUP_TRACKED {
    take:
    ch_bam_bai   // [ meta, bam, bai ]
    ch_fasta     // [ meta2, fasta, fai ]
    ch_bed       // [ meta3, bed ] (may be empty)

    main:
    // Phase 1: run the stock nf-core module.
    MODKIT_PILEUP(ch_bam_bai, ch_fasta, ch_bed)

    // Phase 2: per-assay summary TSV.
    SUMMARIZE_MODKIT(MODKIT_PILEUP.out.bedgz)

    // Phase 3: register with casetrack. Leaf dir is computed inside the
    // register process from params.casetrack_project_dir + meta.{patient,
    // specimen, assay_id} + params.run_tag.
    ch_register = SUMMARIZE_MODKIT.out.summary
        .map { meta, tsv -> tuple(meta, 'modkit_pileup', 'modkit_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    bedgz          = MODKIT_PILEUP.out.bedgz
    summary        = SUMMARIZE_MODKIT.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
