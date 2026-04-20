# ADR-002 — SAMTOOLS_SORT_TRACKED (workstream C, first wrapper)

**Status**: pending implementation (design locked 2026-04-20)
**Target**: casetrack-nf-subworkflows v0.5.1
**Driver**: proposal 0004 §Roadmap, workstream C.

## Context

First of four post-v0.5.0 `*_tracked.nf` wrappers (workstream C). Chosen
first because it is the simplest — SAMTOOLS_SORT is a pass-through step,
so the summarize script is trivial and exercises the full wrapper
pattern without tool-specific parsing.

## Resolved design points

### Summary TSV columns

Minimal, one row per input BAM:

```
<id_col>    sorted_bam_path    sorted_bam_size_bytes    n_reads
```

- `sorted_bam_path` — absolute path to the sorted BAM (TEXT).
- `sorted_bam_size_bytes` — file size in bytes (INTEGER).
- `n_reads` — total reads from the sorted BAM header. Parsed from
  `samtools view -c <bam>` in the summarize script (container already
  has samtools available, so shelling out is safe; stdlib-only
  constraint only applies to bin/ helpers that don't have access to
  a container).

### casetrack.toml declaration

```toml
[analyses.samtools_sort]
level         = "specimen"    # or "assay" — set per project
column_prefix = "sort"
summary_tsv   = "samtools_sort_summary.tsv"
nf_process    = "SAMTOOLS_SORT"
```

### nf-core module install

Once per repo:

```bash
cd /data1/greenbab/users/ahunos/apps/casetrack-nf-subworkflows
# First, add the required .nf-core.yml config
cat > .nf-core.yml <<YAML
repository_type: pipeline
nf_core_version: 3.5.2
YAML
# Then install (needs interactive tty; run from a real terminal)
nf-core modules install samtools/sort
```

After install, `modules/nf-core/samtools/sort/main.nf` is vendored.

### Subworkflow code (copy-paste ready)

Create `subworkflows/local/samtools_sort_tracked.nf`:

```groovy
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

include { SAMTOOLS_SORT     } from '../../modules/nf-core/samtools/sort/main.nf'
include { SUMMARIZE_SORT    } from '../../modules/local/summarize_sort.nf'
include { CASETRACK_REGISTER } from '../../modules/local/casetrack_register.nf'

workflow SAMTOOLS_SORT_TRACKED {
    take:
    ch_bam     // [ meta, bam ]

    main:
    SAMTOOLS_SORT(ch_bam, [[:], []])   // (meta+bam, fasta+fai stub; sort doesn't need ref)

    SUMMARIZE_SORT(SAMTOOLS_SORT.out.bam)

    ch_register = SUMMARIZE_SORT.out.summary
        .map { meta, tsv -> tuple(meta, 'samtools_sort', 'samtools_sort_summary.tsv', tsv) }

    CASETRACK_REGISTER(ch_register)

    emit:
    sorted_bam     = SAMTOOLS_SORT.out.bam
    summary        = SUMMARIZE_SORT.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
```

### Summarize process (modules/local/summarize_sort.nf)

```groovy
/*
 * summarize_sort.nf — emit a one-row TSV for samtools_sort.
 * Level-aware key via _resolve_key (same helper as summarize_modkit.nf).
 */

process SUMMARIZE_SORT {
    tag "${meta.id}"
    label 'process_single'

    container 'https://depot.galaxyproject.org/singularity/samtools:1.21--h50ea8bc_0'

    input:
    tuple val(meta), path(bam)

    output:
    tuple val(meta), path("samtools_sort_summary.tsv"), emit: summary

    when:
    task.ext.when == null || task.ext.when

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    N_READS=\$(samtools view -c "${bam}")
    SIZE=\$(stat -c %s "${bam}")
    ABS=\$(readlink -f "${bam}")
    printf '${id_col}\\tsorted_bam_path\\tsorted_bam_size_bytes\\tn_reads\\n' > samtools_sort_summary.tsv
    printf '%s\\t%s\\t%s\\t%s\\n' '${id_value}' "\$ABS" "\$SIZE" "\$N_READS" >> samtools_sort_summary.tsv
    """

    stub:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    printf '${id_col}\\tsorted_bam_path\\tsorted_bam_size_bytes\\tn_reads\\n' > samtools_sort_summary.tsv
    printf '%s\\t/stub/path.bam\\t1024\\t100\\n' '${id_value}' >> samtools_sort_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
```

### main.nf wiring

Extend the existing branch in `main.nf`:

```groovy
// Add to the include block:
include { SAMTOOLS_SORT_TRACKED } from './subworkflows/local/samtools_sort_tracked.nf'

// Inside the workflow {}, after the existing level branch, add a tool branch:
// (You'll want to promote 'which tool to run' from hardcoded to a param like
//  params.tool in {modkit_pileup,modkit_merged,samtools_sort,...}. Until then
//  running samtools_sort requires editing main.nf — acceptable for v0.5.1
//  because users mostly consume the library via `include { SAMTOOLS_SORT_TRACKED }`
//  from their own pipelines, not through this demo main.nf.)
```

Pragmatic for v0.5.1: add a `params.tool` switch in main.nf with default
`modkit_pileup`; SAMTOOLS_SORT_TRACKED branch runs when `params.tool =
'samtools_sort'`. MODKIT_MERGED_TRACKED gets the same treatment for
symmetry.

### Stub smoke test (test/run_test_sort.sh)

Mirror `test/run_test_merged.sh` but:
- `params.tool = samtools_sort`
- No `--fasta` needed (sort doesn't use reference)
- Assert `sort_sorted_bam_path`, `sort_sorted_bam_size_bytes`, `sort_n_reads`, `sort_samtools_sort_done` land on the right level
- Isolate `CASETRACK_REGISTRY` per run (same env-var trick as run_test_merged.sh)

## Consequences

- v0.5.1 bump after this lands. C2-C4 follow the same template.
- `params.tool` becomes the idiomatic way to flip the demo between
  wrappers. Not a breaking change — default stays `modkit_pileup`.

## Open questions

- Should the summarize script record `sort_order` (coordinate/queryname)
  by parsing the BAM header `@HD SO:` line? Probably yes for
  completeness — add in the first implementation.
- `sort_n_reads` duplicates what SAMTOOLS_FLAGSTAT would produce. If a
  downstream FLAGSTAT_TRACKED wrapper lands, consider dropping n_reads
  from sort's summary to avoid redundancy.

## References

- Memory `project_workstream_C_wrappers.md` — the overall C plan.
- `docs/ADR-001-level-aware-wrappers.md` — level contract.
- Proposal 0004 §Current state table.
