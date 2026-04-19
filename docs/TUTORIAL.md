# Tutorial — Track Nextflow pipelines with casetrack

This walkthrough takes you from **nothing** to **"every sample in my cohort is registered in a SQLite DB with per-tool methylation metrics + SLURM runtime stats"**, using one real GIAB ONT BAM and the nf-core `MODKIT_PILEUP` module.

**~45 minutes**, assuming casetrack and Nextflow are already installed.

## What you'll build

```
results/
├── modkit_pileup/
│   └── 20260419_hg38_modkit_v1/
│       └── HG006/HG006_gDNA/HG006_PAY77227/
│           ├── HG006_PAY77227.bed.gz          ← real tool output
│           └── modkit_summary.tsv             ← one-row summary
├── _nextflow/
│   └── 20260419_hg38_modkit_v1/
│       ├── execution_trace.txt                ← consumed by L2
│       ├── execution_report.html
│       └── pipeline_dag.html
└── casetrack.db                               ← one row per assay
    modkit_mean_meth      0.0424
    modkit_n_cpgs         14,406,945
    modkit_mean_cov       16.64
    modkit_pileup_done    2026-04-19T01:28:47
    modkit_slurm_job_id   19512075
    modkit_realtime_sec   155
    modkit_peak_rss_bytes 9,985,798,963
    modkit_exit_status    0
```

## Prerequisites

```bash
casetrack --help        # v0.5.0+ with --infer-from-path
nextflow -version       # >= 24.04
apptainer --version     # or singularity
sqlite3 --version
```

And a casetrack-nf-subworkflows clone:

```bash
git clone https://github.com/sahuno/casetrack-nf-subworkflows.git
```

## Step 1 — Set up a casetrack project

The project is a separate directory from the pipeline code. One casetrack project per cohort; the same subworkflows work across many cohorts.

```bash
casetrack init \
    --project-dir /abs/path/to/cohort_X \
    --from-template giab_ont \
    --bare
```

Templates: `blank`, `hgsoc`, `giab_ont`. Each ships a default `[layout.path_templates]` block — the tool-first convention `{tool}/{run_tag}/{patient_id}/{specimen_id}/{assay_id}` is already there.

## Step 2 — Declare tools in `casetrack.toml`

Open `/abs/path/to/cohort_X/casetrack.toml` and add one block per tool you plan to run:

```toml
[analyses.modkit_pileup]
level         = "assay"
column_prefix = "modkit"
summary_tsv   = "modkit_summary.tsv"
```

- `level` = which table the columns go on (`patient`, `specimen`, or `assay`).
- `column_prefix` = what gets prepended to each column from the summary TSV. `mean_meth` → `modkit_mean_meth`.
- `summary_tsv` = filename the custom wrapper's summarize step produces (ignored if you use the trace-only pattern — see Step 3).

**This is the single source of truth** that both L1 (data columns) and L2 (trace columns) consult.

## Step 3 — Choose a tracking pattern

### Pattern A — Trace-only (zero custom code)

Works with **any** stock nf-core module, no wrapper needed. You get one row per assay with:

| Column | Value |
|---|---|
| `{prefix}_slurm_job_id` | the SLURM job id |
| `{prefix}_realtime_sec` | wallclock seconds on the compute node |
| `{prefix}_peak_rss_bytes` | peak memory |
| `{prefix}_exit_status` | 0 on success |
| `{prefix}_attempts`, `_queue` | retries + queue name |
| `{tool}_trace_done` | auto-timestamp when L2 imported this |

All you do: declare `[analyses.<tool>]` in `casetrack.toml` (Step 2 above), import the stock module in your own pipeline, ensure the `meta` map carries `assay_id`. The L2 trace parser matches trace rows to declared tools automatically.

**Use this when**: you just want a progress dashboard and failure triage. You don't need tool-specific metrics in the DB.

### Pattern B — Data columns (custom wrapper)

Adds tool-specific metrics (e.g. `modkit_mean_meth`, `modkit_n_cpgs`, `modkit_mean_cov`). Requires:

1. A `SUMMARIZE_<TOOL>` Nextflow process that reduces the tool's output to a one-row TSV keyed on `assay_id`. Ship the distillation script under `bin/`.
2. A wrapper subworkflow that composes the stock module + `SUMMARIZE_<TOOL>` + `CASETRACK_REGISTER`.

This is what `MODKIT_PILEUP_TRACKED` already ships. Follow the same shape for any tool.

**Use this when**: you want to query biology from the DB — "give me all samples with `modkit_mean_meth > 0.7`", not just "show me jobs that exited 0."

You get **both L1 + L2 columns**, which is what the rest of this tutorial builds.

## Step 4 — Register your samples

casetrack needs to know who exists before you can append results. Register patient → specimen → assay:

```bash
PROJ=/abs/path/to/cohort_X

casetrack register --project-dir "$PROJ" --level patient \
    --id HG006 --meta 'sex=M,trio_role=proband'

casetrack register --project-dir "$PROJ" --level specimen \
    --id HG006_gDNA --parent HG006 \
    --meta 'specimen_type=whole_genome_dna,cell_line=GM24694'

casetrack register --project-dir "$PROJ" --level assay \
    --id HG006_PAY77227 --parent HG006_gDNA \
    --meta 'assay_type=ONT_WGS,flowcell_id=PAY77227,chemistry=R10.4.1'
```

## Step 5 — Write the samplesheet

One row per assay. The column schema is enforced by `assets/schema_input.json`:

```csv
patient,specimen,assay_id,genome,bam,bai
HG006,HG006_gDNA,HG006_PAY77227,hg38,/abs/path/HG006_PAY77227.hg38.chr21.bam,/abs/path/HG006_PAY77227.hg38.chr21.bam.bai
```

`assay_id` doubles as `meta.id` so stock nf-core modules keep their `tag "${meta.id}"` working unchanged.

## Step 6 — Write `custom.config`

Pipeline code (casetrack-nf-subworkflows) and run data (your casetrack project) stay separate. Put per-run tweaks in a `custom.config` next to your samplesheet:

```groovy
/*
 * custom.config — for this run.
 *
 * Lesson from the pilot: the nf-core module's container ternary falls
 * through to docker.io when Nextflow's containerEngine isn't literally
 * 'singularity'. Pin the Galaxy depot URL for Apptainer to avoid that.
 */
apptainer.cacheDir = '/data1/greenbab/users/ahunos/apptainer_cache'

process {
    withName: 'MODKIT_PILEUP_TRACKED:MODKIT_PILEUP' {
        container = 'https://depot.galaxyproject.org/singularity/ont-modkit:0.6.1--hcdda2d0_0'
        cpus      = 4
        memory    = '16 GB'
        time      = '4h'
    }
    withName: 'MODKIT_PILEUP_TRACKED:SUMMARIZE_MODKIT' {
        cpus   = 1
        memory = '4 GB'     // 2 GB OOMs on WGS-scale bedMethyl
        time   = '30m'
    }
}
```

## Step 7 — Run the pipeline

```bash
nextflow run /path/to/casetrack-nf-subworkflows/main.nf \
    -profile slurm,apptainer \
    -c custom.config \
    --input                 samplesheet.csv \
    --fasta                 /data1/greenbab/database/hg38/v0/Homo_sapiens_assembly38.fasta \
    --fai                   /data1/greenbab/database/hg38/v0/Homo_sapiens_assembly38.fasta.fai \
    --casetrack_project_dir "$PROJ" \
    --run_tag               20260419_hg38_modkit_v1 \
    -ansi-log false
```

What each step does:
1. Nextflow parses the samplesheet, submits `MODKIT_PILEUP` to SLURM.
2. On completion, `SUMMARIZE_MODKIT` distills the bedMethyl into a one-row TSV.
3. `CASETRACK_REGISTER` (`executor='local'`) stages the TSV at `results/modkit_pileup/<run_tag>/<patient>/<specimen>/<assay_id>/` and runs `casetrack append --infer-from-path` — that one flag walks up to `casetrack.toml`, matches the path against `[layout.path_templates.assay]`, infers the column prefix, and writes the L1 data columns.
4. `workflow.onComplete` fires `trace_to_casetrack.py`, which parses `results/_nextflow/<run_tag>/execution_trace.txt` and writes the L2 trace columns via `casetrack append --analysis <tool>_trace`.

## Step 8 — Query the results

```bash
sqlite3 -header -separator ' | ' "$PROJ/casetrack.db" \
    "SELECT assay_id, modkit_mean_meth, modkit_n_cpgs, modkit_mean_cov,
            modkit_slurm_job_id, modkit_realtime_sec, modkit_peak_rss_bytes,
            modkit_exit_status
     FROM assays;"
```

Or via casetrack's DuckDB-backed query:

```bash
casetrack query --project-dir "$PROJ" \
    "SELECT assay_id, modkit_mean_meth, modkit_realtime_sec/60 AS minutes, modkit_peak_rss_bytes/1e9 AS gb_rss FROM assays"
```

## Common gotchas (from the live pilot)

### 1. Local SIF version mismatch
The nf-core `modkit/pileup` module uses `--bgzf` / `--bgzf-threads` flags that don't exist before modkit 0.6.1. If you point the module at an older local SIF, it exits 1 with no modkit stderr — just Apptainer warnings. **Fix**: pin the Galaxy depot URL in `custom.config` (see Step 6).

### 2. Nextflow `containerEngine != 'singularity'` under Apptainer
Recent Nextflow versions report `containerEngine = 'apptainer'`, which fails the nf-core module's ternary check and falls through to `biocontainers/...` on docker.io (requires auth). **Fix**: same container pin as above.

### 3. OOM on your summarize script
`SUMMARIZE_MODKIT` on a chr21 WGS bedMethyl processes ~55 million rows. Your summarize script **must** be single-pass streaming — never accumulate per-site arrays. `bin/summarize_modkit.py` is the reference shape: `for row in iter_bedmethyl(path): sum_pct += row.pct; n += 1`. Size the process memory to 4 GB even for streaming scripts.

### 4. Trace import says "kept=0 dropped=N"
Your trace isn't matching any `[analyses.<tool>]`. Check:
- Is `nextflow.config` emitting the extended trace fields (`process`, `tag`, `queue`, `attempt`)? Confirm with `head execution_trace.txt`.
- Does the tool name case match? Trace parser uppercases and matches against upper-cased TOML keys. `[analyses.modkit_pileup]` maps to `MODKIT_PILEUP` in the trace.
- Is `meta.id == meta.assay_id`? That's how trace `tag` gets the right join key.

## Adding a new tracked tool

Recipe for Pattern B (data columns):

1. **Vendor the module**: `nf-core modules install <tool>` into `modules/nf-core/<tool>/`, or copy from a local nf-core/modules clone.
2. **Write `bin/summarize_<tool>.py`** (or .R) — single-pass streaming, output a one-row TSV keyed on `assay_id`. Include a `--mod-code` / `--min-*` / `--max-*` style filter convention.
3. **Write `modules/local/summarize_<tool>.nf`** — process with `input tuple(meta, path(tool_output))`, output `tuple(meta, path("<tool>_summary.tsv"))`. Include a `stub:` block that emits a shape-correct placeholder.
4. **Write `subworkflows/local/<tool>_tracked.nf`** modeled on `modkit_pileup_tracked.nf`. Call `CASETRACK_REGISTER(tuple(meta, '<tool>', '<tool>_summary.tsv', summary_tsv))`.
5. **Add `[analyses.<tool>]` block to every target casetrack project's TOML** with `level`, `column_prefix`, `summary_tsv` matching your filename.
6. **Extend `test/run_test.sh`** with a stub assertion for the new tool's columns.

Nothing in the stock nf-core module gets modified.

## Troubleshooting

### "Error: unknown tool 'X' — add [analyses.X] to casetrack.toml"
From `casetrack append --infer-from-path`. Means the inferred tool name from the path doesn't have a matching `[analyses.<tool>]` block. Add one.

### "Error: expected summary TSV not found"
The wrapper process didn't land a `<tool>_summary.tsv` at the leaf directory. Check the `CASETRACK_REGISTER` process work dir (`.command.err`) for why the `cp` failed.

### `[SLURM] queue ... cannot be fetched, exit status 143`
Transient — Nextflow's periodic `squeue` poll got SIGTERMed by the kernel on a busy login node. Not fatal.

### "Command 'ps' required by nextflow to collect task metrics cannot be found"
The container doesn't ship `ps` (`procps`). Harmless warning; Nextflow falls back to the trace file's built-in measurements. If you want the extra metrics, install `procps` in your container or switch to one that has it (most biocontainers do).

## Where to go from here

- **Query your whole cohort** with `casetrack dashboard` — self-contained HTML, one row per assay.
- **Scale out**: add more samples to `samplesheet.csv`. Each assay runs in parallel on SLURM; `CASETRACK_REGISTER` throttles to `maxForks=1` automatically so SQLite WAL doesn't contend.
- **Add more tools**: see "Adding a new tracked tool" above.
- **Integrate with nf-core pipelines**: you can run `nf-core/methylseq` and still use the Pattern A (trace-only) tracking by just declaring its modules in your `casetrack.toml`.
