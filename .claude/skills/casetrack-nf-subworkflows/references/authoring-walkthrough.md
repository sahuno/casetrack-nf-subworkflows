# Walkthrough — adding a new TOOL_TRACKED subworkflow

End-to-end example: add `SAMTOOLS_FLAGSTAT_TRACKED` to wrap nf-core's `SAMTOOLS_FLAGSTAT` with casetrack registration. Follow the same recipe for any tool.

## Step 1 — Confirm the level

Pick `assay`, `specimen`, or `patient` based on the granularity of the tool's input:
- `flagstat` runs on a single sorted BAM → typically 1 BAM per specimen → **`specimen`** level
- per-run flagstat (one BAM per assay before merging) would be `assay` level

Decision: `level = "specimen"`.

## Step 2 — Pick the tool key, prefix, and filename

Pick three names that will travel together and be easy to grep:

| Choice | Value | Constraint |
|---|---|---|
| Tool key (TOML) | `samtools_flagstat` | matches `[analyses.<key>]`; lowercase + underscores |
| Column prefix | `flagstat` | every result column gets `flagstat_*`; must be a valid identifier |
| Summary filename | `flagstat_summary.tsv` | matches `summary_tsv` in TOML and the `path()` output in summarize module |

These three names are the wiring between the subworkflow and the consuming project's TOML. Get them right once; they propagate.

## Step 3 — Write the summarize module

`modules/local/summarize_flagstat.nf`:

```groovy
/*
 * summarize_flagstat.nf — parse samtools flagstat output and emit a one-row casetrack TSV.
 * Level-aware via _resolve_key.
 */

process SUMMARIZE_FLAGSTAT {
    tag "${meta.id}"
    label 'process_single'
    container 'https://depot.galaxyproject.org/singularity/samtools:1.21--h50ea8bc_0'

    input:
    tuple val(meta), path(flagstat_txt)

    output:
    tuple val(meta), path("flagstat_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'specimen')
    """
    # samtools flagstat output is line-based, e.g. "152938 + 0 in total (QC-passed reads + QC-failed reads)"
    TOTAL=\$(awk '/in total/{print \$1; exit}' "${flagstat_txt}")
    MAPPED=\$(awk '/mapped \\(/{print \$1; exit}' "${flagstat_txt}")
    DUPLI=\$(awk '/duplicates/{print \$1; exit}' "${flagstat_txt}")
    PCT_MAPPED=\$(awk -v t="\$TOTAL" -v m="\$MAPPED" 'BEGIN{if(t>0)printf "%.2f", m/t*100; else print "0.00"}')

    # qc autoflag: < 80% mapped → qc_warn; < 50% mapped → qc_fail
    QC_PASS=true
    QC_FAIL=""
    QC_WARN=""
    if [ "\${PCT_MAPPED%.*}" -lt 50 ]; then
        QC_PASS=false
        QC_FAIL="mapping rate \${PCT_MAPPED}% < 50% — likely contamination or wrong reference"
    elif [ "\${PCT_MAPPED%.*}" -lt 80 ]; then
        QC_WARN="mapping rate \${PCT_MAPPED}% < 80% — review before downstream"
    fi

    printf '${id_col}\\ttotal_reads\\tmapped_reads\\tduplicate_reads\\tpct_mapped\\tqc_pass\\tqc_fail_reason\\tqc_warn\\n' \\
        > flagstat_summary.tsv
    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
        '${id_value}' "\$TOTAL" "\$MAPPED" "\$DUPLI" "\$PCT_MAPPED" "\$QC_PASS" "\$QC_FAIL" "\$QC_WARN" \\
        >> flagstat_summary.tsv
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'specimen')
    """
    printf '${id_col}\\ttotal_reads\\tmapped_reads\\tduplicate_reads\\tpct_mapped\\tqc_pass\\tqc_fail_reason\\tqc_warn\\n' \\
        > flagstat_summary.tsv
    printf '%s\\t150000\\t148000\\t450\\t98.67\\ttrue\\t\\t\\n' '${id_value}' >> flagstat_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
```

Notes on this summarize module:
- The first column is `id_col` (`assay_id` / `specimen_id` / `patient_id`) — required by casetrack.
- `qc_pass` / `qc_fail_reason` / `qc_warn` columns trigger casetrack's autoflag — a low mapping rate becomes a `qc_events` row in the same transaction as the data update.
- The `stub:` block lets `nextflow run -stub` smoke-test the channel topology without running flagstat.

## Step 4 — Write the subworkflow

`subworkflows/local/samtools_flagstat_tracked.nf`:

```groovy
/*
 * SAMTOOLS_FLAGSTAT_TRACKED — flagstat + register with casetrack.
 *
 * casetrack.toml declaration required:
 *   [analyses.samtools_flagstat]
 *   level         = "specimen"
 *   column_prefix = "flagstat"
 *   summary_tsv   = "flagstat_summary.tsv"
 *   nf_process    = "SAMTOOLS_FLAGSTAT"
 */

include { SAMTOOLS_FLAGSTAT  } from '../../modules/nf-core/samtools/flagstat/main'
include { SUMMARIZE_FLAGSTAT } from '../../modules/local/summarize_flagstat'
include { CASETRACK_REGISTER } from '../../modules/local/casetrack_register'

workflow SAMTOOLS_FLAGSTAT_TRACKED {
    take:
    ch_bam_bai    // [ meta, bam, bai ]

    main:
    SAMTOOLS_FLAGSTAT(ch_bam_bai)

    SUMMARIZE_FLAGSTAT(SAMTOOLS_FLAGSTAT.out.flagstat)

    ch_register = SUMMARIZE_FLAGSTAT.out.summary
        .map { meta, tsv -> tuple(meta, 'samtools_flagstat', 'flagstat_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    flagstat       = SAMTOOLS_FLAGSTAT.out.flagstat
    summary        = SUMMARIZE_FLAGSTAT.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
```

## Step 5 — Document the TOML block users need

In a code comment at the top of the subworkflow (above), AND in the repo's docs (e.g. `docs/TUTORIAL.md` or a per-tool `.md`):

```toml
[analyses.samtools_flagstat]
level         = "specimen"
column_prefix = "flagstat"
summary_tsv   = "flagstat_summary.tsv"
nf_process    = "SAMTOOLS_FLAGSTAT"
```

Then the user runs `casetrack schema apply --project-dir .` to add the `flagstat_*` and `samtools_flagstat_done` columns to the specimens table.

## Step 6 — Add a test

`test/run_test.sh` already runs the demo `MODKIT_PILEUP_TRACKED`. Add a stub-mode invocation of your new subworkflow:

```bash
# test/test_flagstat.sh
nextflow run main.nf \
    -profile test \
    -stub \
    --tool samtools_flagstat \
    --input test/samplesheet.csv \
    --casetrack_project_dir /tmp/test_casetrack \
    --run_tag 20260421_hg38_test \
    --casetrack_level specimen
```

If `main.nf` doesn't yet support `--tool samtools_flagstat`, add a switch on `params.tool` that includes and runs your new subworkflow.

## Step 7 — Verify the registration ran

After a real-data run:

```bash
casetrack query --project-dir <proj> --sql "
  SELECT specimen_id, samtools_flagstat_done,
         flagstat_total_reads, flagstat_pct_mapped, qc_status
  FROM specimens
  WHERE samtools_flagstat_done IS NOT NULL
  ORDER BY flagstat_pct_mapped
"
```

If `samtools_flagstat_done` is NULL despite NF reporting success, walk back through the §7 pitfalls in `apptainer-hpc-lessons.md`:
- #6: filename mismatch (3-place check)
- #7: `nf_process` mismatch in casetrack.toml

If `qc_status` is `warn` or `fail` for any specimen, that's casetrack's autoflag firing on the `qc_pass=false` / `qc_warn` columns from your summarize module — exactly what you want.

## Step 8 — Add to `nextflow.config` if needed

If your new tool requires a specific container override under `apptainer`, add it:

```groovy
apptainer {
    process {
        withName: 'SAMTOOLS_FLAGSTAT_TRACKED:SAMTOOLS_FLAGSTAT' {
            container = '/data1/greenbab/users/ahunos/apps/containers/onttools_latest.sif'
            // (samtools is in onttools — no separate sif needed)
        }
    }
}
```

For tools that produce a primary biological output you want persisted (sorted BAM, called VCF), also set `publishDir` here (see SKILL.md §6 and `samtools_sort_tracked` for the pattern). flagstat produces a text report only, so no publishDir is needed.

## Step 9 — Commit and document

PR title: `feat: SAMTOOLS_FLAGSTAT_TRACKED — flagstat with casetrack registration`

PR description must include:
- The `[analyses.samtools_flagstat]` TOML block users need to add
- The summary TSV column names produced (so users know what to expect in the DB after `column_prefix` is prepended)
- Any container override needed
- Whether QC autoflag is enabled, and at what thresholds
- The `nf_process` value (this is non-obvious for sniffles-style cases where module name ≠ subworkflow name)
