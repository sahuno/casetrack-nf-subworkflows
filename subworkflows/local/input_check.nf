/*
 * input_check.nf — parse an extended nf-core-style samplesheet into channels
 *                  consumable by the tracked subworkflows.
 *
 * Level-aware (ADR-001). The caller passes the level and we validate + shape
 * meta accordingly:
 *
 *   level=assay:    required = patient, specimen, assay_id, genome, bam
 *                   meta.id = meta.assay_id
 *   level=specimen: required = patient, specimen, genome, bam
 *                   meta.id = meta.specimen_id (== row.specimen)
 *                   (assay_id is absent per ADR-001 D2)
 *   level=patient:  required = patient, genome, bam
 *                   meta.id = meta.patient_id (== row.patient)
 *
 * `meta.id` mirrors the level's primary key so stock nf-core modules (which
 * do `tag "${meta.id}"`) produce readable logs at any level.
 *
 * Emits:
 *   ch_bam_bai : [ meta, bam, bai ]
 *
 * See:
 *   - assets/schema_input.json          — assay-level JSON Schema
 *   - assets/schema_input_specimen.json — specimen-level JSON Schema
 */

def _required_cols(level) {
    if (level == 'assay')    return ['patient', 'specimen', 'assay_id', 'genome', 'bam']
    if (level == 'specimen') return ['patient', 'specimen', 'genome', 'bam']
    if (level == 'patient')  return ['patient', 'genome', 'bam']
    error "casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}

def row_to_meta(row, level) {
    def meta = [
        patient: row.patient,
        genome:  row.genome,
    ]
    if (row.specimen) meta.specimen = row.specimen
    if (level == 'assay') {
        meta.assay_id = row.assay_id
        meta.id       = row.assay_id
    } else if (level == 'specimen') {
        meta.id = row.specimen
    } else if (level == 'patient') {
        meta.id = row.patient
    }
    return meta
}

workflow INPUT_CHECK {
    take:
    samplesheet      // path to CSV
    level            // 'assay' | 'specimen' | 'patient'

    main:
    def required = _required_cols(level)

    ch_bam_bai = Channel
        .fromPath(samplesheet, checkIfExists: true)
        .splitCsv(header: true, sep: ',')
        .map { row ->
            for (k in required) {
                if (!row[k]) {
                    error "samplesheet row missing required column '${k}' at level=${level}: ${row}"
                }
            }
            def meta = row_to_meta(row, level)
            def bam  = file(row.bam, checkIfExists: true)
            def bai  = row.bai ? file(row.bai, checkIfExists: true) : []
            tuple(meta, bam, bai)
        }

    emit:
    bam_bai = ch_bam_bai
}
