/*
 * input_check.nf — parse an extended nf-core-style samplesheet into channels
 *                  consumable by the tracked subworkflows.
 *
 * Required columns: patient, specimen, assay_id, genome, bam
 * Optional:         bai
 *
 * Emits:
 *   ch_bam_bai : [ meta, bam, bai ]
 *     meta = [id, patient, specimen, assay_id, genome] — .id mirrors
 *     .assay_id so stock nf-core modules keep working with `tag "${meta.id}"`.
 *
 * See assets/schema_input.json for the JSON Schema enforced upstream by
 * `nf-validation` / `nf-schema`.
 */

def row_to_meta(row) {
    def meta = [
        id:       row.assay_id,
        patient:  row.patient,
        specimen: row.specimen,
        assay_id: row.assay_id,
        genome:   row.genome,
    ]
    return meta
}

workflow INPUT_CHECK {
    take:
    samplesheet      // path to CSV

    main:
    ch_bam_bai = Channel
        .fromPath(samplesheet, checkIfExists: true)
        .splitCsv(header: true, sep: ',')
        .map { row ->
            for (k in ['patient', 'specimen', 'assay_id', 'genome', 'bam']) {
                if (!row[k]) {
                    error "samplesheet row missing required column '${k}': ${row}"
                }
            }
            def meta = row_to_meta(row)
            def bam  = file(row.bam, checkIfExists: true)
            def bai  = row.bai ? file(row.bai, checkIfExists: true) : []
            tuple(meta, bam, bai)
        }

    emit:
    bam_bai = ch_bam_bai
}
