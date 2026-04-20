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

### ID format requirements (casetrack v0.6+)

`patient_id`, `specimen_id`, and `assay_id` must match the default regex:

```
\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z
```

ASCII alphanumeric start; then alphanumeric, underscore, hyphen, or dot; 1–64 chars. No whitespace, no shell metacharacters, no path separators. Case-insensitive duplicates within a level (e.g. `HG006` and `hg006`) are rejected by default.

Typos in the samplesheet fail loudly at `casetrack register`, before the Nextflow pipeline starts — which saves hours of debugging compared to a silent mismatch between samplesheet and DB. See [proposal 0005](https://github.com/sahuno/casetrack/blob/main/docs/proposals/0005-id-format-and-project-identity.md) for the full rule set.

**Escape hatch for legacy LIMS IDs.** Cohorts with pre-existing IDs that contain colons, or that have legitimate case-variants, can loosen the rules per-level via `casetrack.toml`:

```toml
[levels.patient]
key        = "patient_id"
id_pattern = "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$"   # allow colons, 80 chars
allow_case_variants = true                            # allow HG006 and hg006
```

Project-wide Unicode opt-in (e.g. for non-ASCII patient IDs) uses `[project] allow_unicode_ids = true`. Keep in mind most downstream bioinformatics tools mangle non-ASCII silently — opt in only when you have tested end-to-end.

## Step 5 — Write the samplesheet

One row per assay. The column schema is enforced by `assets/schema_input.json`:

```csv
patient,specimen,assay_id,genome,bam,bai
HG006,HG006_gDNA,HG006_PAY77227,hg38,/abs/path/HG006_PAY77227.hg38.chr21.bam,/abs/path/HG006_PAY77227.hg38.chr21.bam.bai
```

`assay_id` doubles as `meta.id` so stock nf-core modules keep their `tag "${meta.id}"` working unchanged.

IDs in the samplesheet must pass the same casetrack format rules noted in Step 4 — whitespace, path separators, and shell metacharacters will be rejected at `casetrack register` time.

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

### "Error: patient_id 'XYZ' is not a valid identifier"
Casetrack v0.6+ rejects malformed hierarchy IDs at `register` time — whitespace, shell metacharacters, path separators, leading hyphens, non-ASCII. Clean the offending ID in the samplesheet, or loosen per-level via `id_pattern` in `casetrack.toml` (see Step 4). See `test/run_test_malformed.sh` for worked examples of all three rejection modes.

### "patient_id 'hg006' conflicts with existing case-variant 'HG006'"
Case-insensitive duplicate check — `HG006` and `hg006` can't coexist in the same level by default (almost always a typo). If you need both, set `[levels.patient] allow_case_variants = true` in `casetrack.toml`.

### `[SLURM] queue ... cannot be fetched, exit status 143`
Transient — Nextflow's periodic `squeue` poll got SIGTERMed by the kernel on a busy login node. Not fatal.

### "Command 'ps' required by nextflow to collect task metrics cannot be found"
The container doesn't ship `ps` (`procps`). Harmless warning; Nextflow falls back to the trace file's built-in measurements. If you want the extra metrics, install `procps` in your container or switch to one that has it (most biocontainers do).

## Where to go from here

- **Query your whole cohort** with `casetrack dashboard` — self-contained HTML, one row per assay.
- **Scale out**: add more samples to `samplesheet.csv`. Each assay runs in parallel on SLURM; `CASETRACK_REGISTER` throttles to `maxForks=1` automatically so SQLite WAL doesn't contend.
- **Add more tools**: see "Adding a new tracked tool" above.
- **Track at the specimen level** (e.g. merged BAMs from multiple flowcells): see the MODKIT_MERGED_TRACKED pattern below.
- **Integrate with nf-core pipelines** (unmodified): use the drop-in config below.

## Pattern B' — specimen-level wrapper (MODKIT_MERGED_TRACKED)

Use this when the biological unit is the **specimen** (one merged BAM made
from all flowcells of that specimen), not individual flowcells. Typical
case: you've merged per-flowcell ONT BAMs with `samtools merge` and want
one `modkit pileup` row per specimen.

Two things change versus the default assay-level flow:

### Samplesheet — no `assay_id` column

The specimen is the unit, so the sheet has one row per specimen with
`patient, specimen, genome, bam, bai`:

```csv
patient,specimen,genome,bam,bai
HG006,HG006_gDNA,hg38,/path/to/HG006_gDNA.merged.bam,/path/to/HG006_gDNA.merged.bam.bai
HG007,HG007_gDNA,hg38,/path/to/HG007_gDNA.merged.bam,/path/to/HG007_gDNA.merged.bam.bai
```

JSON Schema: `assets/schema_input_specimen.json`.

### casetrack.toml — declare the analysis with an `nf_process` alias

Because the wrapper reuses the stock `MODKIT_PILEUP` nf-core module, the
nextflow trace and `versions.yml` both record it as `MODKIT_PILEUP`. Tell
the L2/L3 importers that those rows belong to your `modkit_merged`
analysis via `nf_process`:

```toml
[analyses.modkit_merged]
level         = "specimen"
column_prefix = "modkit_merged"
summary_tsv   = "modkit_merged_summary.tsv"
nf_process    = "MODKIT_PILEUP"   # trace/versions lookup alias
```

Without `nf_process`, the importers would look for `[analyses.modkit_pileup]`
and skip the row. If you run assay-level MODKIT_PILEUP *and* specimen-level
MODKIT_MERGED in the same project, give each its own `nf_process` — last
declaration wins per alias, so distinct wrapper names are required.

### Pipeline invocation

```bash
nextflow run /path/to/casetrack-nf-subworkflows/main.nf \
    --input                 specimens.csv \
    --fasta                 /path/to/reference.fa \
    --fai                   /path/to/reference.fa.fai \
    --casetrack_project_dir "${PROJ}" \
    --casetrack_level       specimen \
    --run_tag               20260420_hg38_merged_v1 \
    -profile                slurm,apptainer
```

Two differences from the assay-level call: `--casetrack_level specimen`
switches `main.nf` to `MODKIT_MERGED_TRACKED` and tells `INPUT_CHECK` to
accept the specimen-level schema.

### Resulting casetrack DB

```sql
SELECT specimen_id, modkit_merged_mean_meth, modkit_merged_n_cpgs,
       modkit_merged_slurm_job_id, modkit_merged_modkit_version
FROM specimens;
```

`assays` is empty (no `assay_id` was provided). All data, trace, and
versions columns land on `specimens`.

## Pattern C — drop-in config for an unmodified nf-core pipeline

If you want to run a stock nf-core pipeline (e.g. `nf-core/methylong`, `nf-core/sarek`, `nf-core/methylseq`) without forking it, use `conf/casetrack_dropin.config`. It adds L2 + L3 tracking via `-c` on the CLI.

```bash
nextflow run nf-core/methylong -r 2.0.0 \
    -c /path/to/casetrack-nf-subworkflows/conf/casetrack_dropin.config \
    -c /path/to/your/site.config \
    --input                         samplesheet.csv \
    --outdir                        "${PROJ}/results/_methylong_run/${RUN_TAG}" \
    --casetrack_project_dir         "${PROJ}" \
    --run_tag                       "${RUN_TAG}" \
    --casetrack_level               specimen \
    --casetrack_helper_dir          /path/to/casetrack-nf-subworkflows/bin \
    --casetrack_samplesheet_key_col sample \
    -profile                        apptainer
```

What the drop-in does:
- Enables extended Nextflow trace fields (process, tag, queue, attempt).
- On `workflow.onComplete`, invokes `bin/trace_to_casetrack.py` (L2) and `bin/versions_to_casetrack.py` (L3) against the declared `[analyses.*]` tools in your casetrack project.
- **Does not** add L1 data columns — those still require per-tool wrappers (Pattern B). With the drop-in you get trace metadata + versions for free, which is often all you need when using upstream pipelines.

You **must** declare the tools in your casetrack project's `casetrack.toml`:

```toml
[analyses.modkit_pileup]
level         = "specimen"   # methylong writes per-specimen outputs
column_prefix = "modkit"
summary_tsv   = "modkit_summary.tsv"

[analyses.samtools_flagstat]
level         = "specimen"
column_prefix = "flagstat"
summary_tsv   = "flagstat_summary.tsv"
```

Any tool whose uppercased name matches an `[analyses.*]` key gets tracked. Unknown tools in the trace file are silently skipped.
