---
name: casetrack-nf-subworkflows
description: Use this skill whenever the user works with **casetrack-nf-subworkflows** — the Nextflow DSL2 wrappers that pair stock nf-core modules (samtools sort, dorado basecaller, modkit pileup/callmods, sniffles2, …) with `casetrack` bookkeeping via the `CASETRACK_REGISTER` process. Trigger this skill when the user is: authoring a new tracked subworkflow (wrapping any nf-core or local module to add casetrack registration); debugging a `CASETRACK_REGISTER` failure; setting up the publishDir convention for `data/processed/{genome}/{patient}/{assay}/`; configuring Apptainer/Singularity containers for these subworkflows on HPC (cacheDir, container overrides, GPU `--nv`, `--bind /usr/bin/ps`); choosing SLURM resource patterns (`mem_mb_per_cpu` vs `mem_mb`, GPU partition selection); writing a `SUMMARIZE_<TOOL>.nf` module; or troubleshooting `casetrack append --infer-from-path` mismatches between subworkflow filenames and `casetrack.toml` declarations. Trigger even when the user says "tracked subworkflow", "wrap modkit/dorado/etc with casetrack", "my Nextflow casetrack pipeline", or "how do I add a new TOOL_TRACKED" — those all map here. For pure casetrack CLI questions (init, add-metadata, append, query, censor) use the `casetrack` skill instead.
---

# casetrack-nf-subworkflows skill

Nextflow DSL2 wrappers that pair stock nf-core modules with **casetrack** bookkeeping. One thin wrapper per module — no fork of the upstream module, so `nf-core modules update` keeps working.

This skill teaches the contract for **authoring** new tracked subworkflows and **debugging** the existing ones on HPC. For pure casetrack CLI questions (init, add-metadata, append, query, censor), use the **casetrack** skill instead.

## 1. The 3-process contract

Every tracked subworkflow has the same shape:

```
TOOL_PROCESS                  ← stock nf-core or local; produces biological output
  ↓
SUMMARIZE_TOOL                ← local; reduces output to a one-row TSV
  ↓
CASETRACK_REGISTER            ← shared local process; runs `casetrack append --infer-from-path --overwrite`
```

Why three processes and not two:
- **Separation**: `TOOL_PROCESS` stays untouched (nf-core compatible); summarize/register live in your repo.
- **Replaceability**: swap a tool implementation without rewriting bookkeeping.
- **Resumability**: NF `-resume` skips completed `CASETRACK_REGISTER` invocations naturally.

## 2. Skeleton of a new TOOL_TRACKED subworkflow

To add `MYTOOL_TRACKED`:

```groovy
// subworkflows/local/mytool_tracked.nf
include { MYTOOL              } from '../../modules/nf-core/mytool/main'   // or modules/local/
include { SUMMARIZE_MYTOOL    } from '../../modules/local/summarize_mytool'
include { CASETRACK_REGISTER  } from '../../modules/local/casetrack_register'

workflow MYTOOL_TRACKED {
    take:
    ch_input    // [ meta, input_files... ]

    main:
    MYTOOL(ch_input, ...)

    SUMMARIZE_MYTOOL(MYTOOL.out.results)

    ch_register = SUMMARIZE_MYTOOL.out.summary
        .map { meta, tsv -> tuple(meta, 'mytool', 'mytool_summary.tsv', tsv) }
    //                                ^^^^^^^^   ^^^^^^^^^^^^^^^^^^^^^
    //                                tool name  summary filename
    //                                — both MUST match casetrack.toml (§4)

    CASETRACK_REGISTER(ch_register)

    emit:
    output         = MYTOOL.out.results
    summary        = SUMMARIZE_MYTOOL.out.summary
    casetrack_done = CASETRACK_REGISTER.out.ok
}
```

That's it for the workflow. The two new artifacts you also need:
- `modules/local/summarize_mytool.nf` (§3)
- `[analyses.mytool]` block in the consuming project's `casetrack.toml` (§4)

## 3. The `SUMMARIZE_<TOOL>` module contract

A summarize module emits one TSV row per entity (at the analysis's level: assay/specimen/patient). The first column must be the level's key column — `assay_id`, `specimen_id`, or `patient_id`.

Use the `_resolve_key` helper (copy from `summarize_sort.nf`) so the same summarize module works at every level — the user picks the level via `params.casetrack_level`:

```groovy
process SUMMARIZE_MYTOOL {
    tag "${meta.id}"
    label 'process_single'
    container 'https://depot.galaxyproject.org/singularity/python:3.12'   // or whatever has your parser

    input:
    tuple val(meta), path(results)

    output:
    tuple val(meta), path("mytool_summary.tsv"), emit: summary
    //                     ^^^^^^^^^^^^^^^^^^^
    //                     name MUST match the value in [analyses.mytool].summary_tsv

    script:
    def (id_col, id_value) = _resolve_key(meta, params.casetrack_level ?: 'assay')
    """
    # parse, distill, write one row keyed on id_value:
    printf '${id_col}\\tmy_metric_a\\tmy_metric_b\\toutput_path\\n' > mytool_summary.tsv
    printf '%s\\t...\\t...\\t...\\n' '${id_value}' >> mytool_summary.tsv
    """
}

def _resolve_key(meta, level) {
    if (level == 'assay')    return ['assay_id',    meta.assay_id]
    if (level == 'specimen') return ['specimen_id', meta.specimen]
    if (level == 'patient')  return ['patient_id',  meta.patient]
    error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
```

**Optional QC autoflag columns:** include `qc_pass` (boolean) and/or `qc_fail_reason` / `qc_warn` columns in your output TSV. `casetrack append` consumes them and emits `qc_events` rows in the same transaction — no separate `casetrack censor` call needed. Use this when the summarize step can detect the assay is unusable (e.g. zero reads, contamination, wrong chemistry).

## 4. The `casetrack.toml` declaration users need

Each tracked subworkflow requires the consuming casetrack project to declare the analysis. Document this at the top of your subworkflow file:

```toml
[analyses.mytool]
level         = "specimen"             # or "assay" / "patient" — match summary granularity
column_prefix = "mt"                   # every result column gets prefixed: mt_my_metric_a
summary_tsv   = "mytool_summary.tsv"   # MUST match SUMMARIZE_MYTOOL output filename exactly
nf_process    = "MYTOOL"               # NF process name as it appears in trace.txt — for L2 trace import
```

**Three things must agree** or `casetrack append --infer-from-path` will fail (see §7 pitfall #6/#7):
- The 2nd element of the tuple in your subworkflow (`'mytool'`) ↔ the TOML key (`[analyses.mytool]`)
- The 3rd element of the tuple (`'mytool_summary.tsv'`) ↔ `summary_tsv` in TOML ↔ the `path()` output name in `SUMMARIZE_MYTOOL`
- `nf_process = "MYTOOL"` ↔ the actual process name in `trace.txt` (caps matter; nf-core's sniffles module is named `SNIFFLES`, not `SNIFFLES2`)

## 5. The `CASETRACK_REGISTER` process

Already shipped as `modules/local/casetrack_register.nf`. Do **not** fork it casually. Its behavior is:

```groovy
process CASETRACK_REGISTER {
    tag "${tool}:${meta.id}"
    executor 'local'         // SQLite WAL is concurrent-safe but local serializes provenance
    maxForks 1               // one writer at a time → readable provenance.jsonl
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(meta), val(tool), val(summary_name), path(summary_tsv)

    script:
    def leaf = "${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}/${meta.assay_id}"   // for level=assay
    """
    LEAF="${leaf}"
    mkdir -p "\$LEAF"
    cp -f "${summary_tsv}" "\$LEAF/${summary_name}"
    cd "\$LEAF"
    casetrack append --infer-from-path --overwrite
    """
}
```

Three load-bearing details:
- **`executor 'local'` + `maxForks 1`**: SQLite WAL is concurrent-safe, but serializing the registration step keeps `provenance.jsonl` line-readable and avoids SLURM queue overhead for a sub-second task.
- **`--overwrite`**: mandatory. Without it, fill-only is the default and a rerun with corrected stats silently no-ops (the #1 silent failure mode in casetrack).
- **`--infer-from-path`**: recovers `--analysis`, `--column-prefix`, `--results`, and `--level` from the leaf path and the project's `[layout.path_templates]` + `[analyses.<tool>]` blocks. The leaf must be at the right depth for the level.

## 6. publishDir convention — `data/processed/`

Primary biological outputs (BAMs, VCFs) must live outside the NF work dir so they survive cleanup and the DB can index stable absolute paths. The convention:

```
{casetrack_project_dir}/data/processed/{genome}/{patient_id}/{assay_id}/
   {assay_id}.{genome}.sorted.bam
   {assay_id}.{genome}.basecalled.bam
   {assay_id}.{genome}.sniffles.vcf.gz
```

In `nextflow.config` apptainer profile, override the upstream nf-core module to publish:

```groovy
process {
    withName: 'SAMTOOLS_SORT_TRACKED:SAMTOOLS_SORT' {
        container  = '/data1/greenbab/users/ahunos/apps/containers/onttools_latest.sif'
        publishDir = [
            path:   { "${params.casetrack_project_dir}/data/processed/${meta.genome}/${meta.patient}/${meta.id}" },
            mode:   'copy',
            saveAs: { fn -> fn.endsWith('.bam') ? "${meta.id}.${meta.genome}.sorted.bam" : null }
        ]
    }
}
```

The `SUMMARIZE_*` module must record this *persistent* path (not a `readlink -f` of the work-dir symlink) in its summary TSV. Otherwise the DB stores an ephemeral path that breaks after `nxf_work/` cleanup.

## 7. HPC + Apptainer survival guide

Eight hard-won fixes for running these subworkflows on MSKCC IRIS (RHEL 8, Apptainer, SLURM). Each one cost real debugging time — read `references/apptainer-hpc-lessons.md` for the longer story.

| # | Symptom | Fix |
|---|---|---|
| 1 | Apptainer re-pulls images every run, fills home quota | Set `apptainer.cacheDir = '/data1/greenbab/users/ahunos/apptainer_cache'` in nextflow.config |
| 2 | nf-core module fails: `community.wave.seqera.io ... 401 Unauthorized` | nf-core checks `workflow.containerEngine == 'singularity'` — under apptainer it's `'apptainer'` → falls to Wave/Docker. Override containers per-process to local `.sif` in the apptainer profile |
| 3 | `Command 'ps' not found in container` | Bind from host: `apptainer.runOptions = '--bind /data1/greenbab --bind /usr/bin/ps:/usr/bin/ps'` (NF probes ps for task metrics) |
| 4 | GPU container: `Failed to load NVML` / cuda init fails | Add `--nv` to apptainer.runOptions in the gpu profile |
| 5 | Process killed silently mid-sort/merge ("terminated by external system") | Move `NXF_WORK` off `/tmp` to `/data1/greenbab/...` — `/tmp` size varies by node |
| 6 | `--infer-from-path` errors with "no such file" | TSV filename in subworkflow ≠ `summary_tsv` in casetrack.toml. Check both ends match exactly |
| 7 | L2 trace import (`bin/trace_to_casetrack.py`) silently misses rows | `nf_process` in casetrack.toml ≠ process name in `trace.txt`. Caps matter; nf-core's sniffles is `SNIFFLES`, not `SNIFFLES2` |
| 8 | GPU job submitted to wrong partition / no GPUs visible | Set `queue = 'componc_gpu_batch'` in `withLabel: 'process_high_gpu'` (default `componc_cpu` has no GPUs) |

## 8. SLURM resources — `mem_mb_per_cpu` not `mem_mb`

Snakemake 9 with `snakemake-executor-plugin-slurm` wraps each rule's shell in `srun` inside `sbatch`. If both have memory directives they conflict (`SLURM_MEM_PER_NODE` vs `SLURM_MEM_PER_CPU` fatal). The same risk exists in Nextflow when an `sbatch`-submitted coordinator uses `--mem` and child processes inherit it. Fixes:

```groovy
process {
    withLabel: 'process_high' {
        cpus     = 8
        memory   = '32 GB'        // safe — Nextflow SLURM executor translates to --mem-per-cpu
        time     = '8h'
    }
    withLabel: 'process_high_gpu' {
        cpus           = 8
        memory         = '0'      // mem=0 → all node memory; avoids the conflict on GPU nodes
        queue          = 'componc_gpu_batch'
        clusterOptions = '--gres=gpu:1'
        time           = '24h'
    }
}
```

If you submit the NF coordinator itself as a SLURM job: use `#SBATCH --mem-per-cpu=XXXX`, never `--mem=XG`. And `unset SLURM_MEM_PER_NODE` at the top of the submit script.

## 9. Required pipeline params

Every NF run that uses any tracked subworkflow must provide:

```
--casetrack_project_dir   absolute path to the casetrack project (must live OUTSIDE NF work dir)
--run_tag                 {YYYYMMDD}_{genome}_{description} e.g. 20260421_hg38_normal_basecalling
--casetrack_level         assay | specimen | patient — must match [analyses.<tool>].level
--casetrack_bin           optional — defaults to `casetrack` on PATH
```

The `run_tag` shows up in the results path, in `{prefix}_run_tag` columns in the DB, and in NF trace files — that's how you trace which pipeline run produced a given DB row six months from now.

## 10. Existing subworkflows — copy from these

When in doubt, follow the patterns in the repo:

| Subworkflow | Tool | Level | Notes |
|---|---|---|---|
| `samtools_sort_tracked.nf` | nf-core SAMTOOLS_SORT | specimen | simplest pass-through wrapper |
| `dorado_basecaller_tracked.nf` | local DORADO_BASECALLER | assay | GPU; uses `process_high_gpu` |
| `modkit_callmods_tracked.nf` | nf-core MODKIT_CALLMODS | specimen | per-read methylation tags |
| `modkit_pileup_tracked.nf` | nf-core MODKIT_PILEUP | specimen | bedMethyl per-site |
| `modkit_merged_tracked.nf` | local MODKIT (merged BAM) | specimen | post-merge methylation |
| `sniffles2_tracked.nf` | nf-core SNIFFLES | specimen | SV calling; `nf_process="SNIFFLES"` (not SNIFFLES2!) |

## 11. Testing a new subworkflow

```bash
# Stub-mode smoke test — no real tools, just the channel topology
nextflow run main.nf -profile test -stub -with-trace

# Real-data smoke test (one sample, local executor)
nextflow run main.nf -profile test --input test/samplesheet.csv

# Validation against project_17424 cohort (real data, SLURM, GPU)
sbatch validation/run_<tag>.sh
```

After a successful run, verify the DB picked up the registration:

```bash
casetrack query --project-dir <proj> --sql "
  SELECT specimen_id, mytool_done, mt_my_metric_a
  FROM specimens WHERE mytool_done IS NOT NULL
"
```

If `mytool_done` is NULL despite the NF job completing, walk back through §7 pitfall #6 (filename mismatch) and #7 (nf_process name).

## 12. When to read the references

Default to handling requests directly from this SKILL.md. Read reference files when:

- User wants the full Apptainer + HPC story with examples → `references/apptainer-hpc-lessons.md`
- User wants a complete worked example of a new tracked subworkflow → `references/authoring-walkthrough.md`
- User asks about the `CASETRACK_REGISTER` module internals or wants to fork it → `references/casetrack-register-internals.md`
