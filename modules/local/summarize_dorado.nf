/*
 * summarize_dorado.nf — parse dorado summary TSV and emit a one-row casetrack TSV.
 *
 * Summary columns: basecaller_model, n_reads, n_bases, read_n50, pass_pct,
 *                  mean_qscore, <id_col>.
 */

process SUMMARIZE_DORADO {
    tag "${meta.id}"
    label 'process_single'

    container 'https://depot.galaxyproject.org/singularity/python:3.12'

    input:
    tuple val(meta), path(bam)
    tuple val(meta2), path(summary_tsv)
    val(model)

    output:
    tuple val(meta), path("dorado_basecaller_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    python3 - <<'PYEOF'
import csv, sys, math

model    = "${model}"
id_col   = "${id_col}"
id_value = "${id_value}"

rows = []
with open("${summary_tsv}") as fh:
    rdr = csv.DictReader(fh, delimiter='\\t')
    rows = list(rdr)

if not rows:
    print("WARNING: dorado summary TSV is empty", file=sys.stderr)
    n_reads = 0; n_bases = 0; mean_q = 0.0; n50 = 0; pass_pct = 0.0
else:
    lengths = [int(r.get('sequence_length_template', 0) or 0) for r in rows]
    qscores = [float(r.get('mean_qscore_template', 0) or 0) for r in rows]
    n_reads = len(rows)
    n_bases = sum(lengths)
    mean_q  = sum(qscores) / n_reads if n_reads else 0.0
    # N50 from lengths
    sl = sorted(lengths, reverse=True)
    half = n_bases / 2
    cum = 0
    n50 = 0
    for l in sl:
        cum += l
        if cum >= half:
            n50 = l
            break
    pass_rows = [r for r in rows if float(r.get('mean_qscore_template', 0) or 0) >= 8.0]
    pass_pct  = len(pass_rows) / n_reads * 100 if n_reads else 0.0

header = [id_col, 'basecaller_model', 'n_reads', 'n_bases', 'read_n50', 'pass_pct', 'mean_qscore']
row    = [id_value, model, n_reads, n_bases, n50, f'{pass_pct:.2f}', f'{mean_q:.3f}']
with open('dorado_basecaller_summary.tsv', 'w') as out:
    out.write('\\t'.join(header) + '\\n')
    out.write('\\t'.join(str(v) for v in row) + '\\n')
PYEOF
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    printf '${id_col}\\tbasecaller_model\\tn_reads\\tn_bases\\tread_n50\\tpass_pct\\tmean_qscore\\n' > dorado_basecaller_summary.tsv
    printf '%s\\t${model}\\t2\\t2100\\t11500\\t100.00\\t14.850\\n' '${id_value}' >> dorado_basecaller_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
