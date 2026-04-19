# casetrack-nf-subworkflows

**Reusable Nextflow DSL2 subworkflows that wrap stock nf-core modules with
[`casetrack`](https://github.com/sahuno/casetrack) bookkeeping.**

One thin wrapper per nf-core module. Each wrapper adds a per-assay
summary step and a `casetrack append --infer-from-path` register step
— no edits to the underlying nf-core module, so `nf-core modules update`
keeps working.

- **Status**: v0.1.0 — pilot with MODKIT_PILEUP.
- **Requires**: Nextflow ≥ 24.04, `casetrack` ≥ 0.5.0 on `$PATH`.

## Why this repo exists

You can either fork nf-core modules to add tracking (bad — they rot on
every upstream update), or you can compose them in wrappers you own
(good). This repo is the second thing.

Each wrapper is a DSL2 `workflow` that:

1. Calls the stock nf-core module unchanged (imported from
   `modules/nf-core/`, kept in sync via `nf-core modules update`).
2. Runs a local `SUMMARIZE_<TOOL>` process that reduces the tool's output
   to a one-row TSV keyed on `assay_id`.
3. Calls `CASETRACK_REGISTER` which stages the TSV at the tool-first leaf
   path declared in the project's `casetrack.toml [layout]` and runs
   `casetrack append --infer-from-path` from that leaf.

The casetrack project — not this repo — owns the DB, provenance log, and
`[analyses.<tool>]` declarations that drive type inference and column
prefixes. Your pipeline code is separate from your data.

## Directory layout

```
casetrack-nf-subworkflows/
├── main.nf                               # demo pipeline (MODKIT_PILEUP_TRACKED on every row)
├── nextflow.config                       # params + profiles (standard/test/slurm/apptainer)
├── assets/
│   └── schema_input.json                 # samplesheet JSON Schema
├── subworkflows/local/
│   ├── input_check.nf                    # CSV → (meta, bam, bai) channel
│   └── modkit_pileup_tracked.nf          # MODKIT_PILEUP + SUMMARIZE + REGISTER
├── modules/
│   ├── local/
│   │   ├── summarize_modkit.nf           # bedMethyl → one-row TSV
│   │   └── casetrack_register.nf         # append --infer-from-path
│   └── nf-core/
│       └── modkit/pileup/                # vendored upstream; refresh with `nf-core modules update`
├── bin/
│   └── summarize_modkit.py               # distillation script (Nextflow auto-adds bin/ to PATH)
├── conf/
│   └── base.config                       # shared resource defaults
└── test/
    ├── samplesheet.csv                   # 1-row stub input
    ├── nextflow.config                   # local-executor test profile
    └── run_test.sh                       # end-to-end stub smoke test
```

## Samplesheet schema

Extended nf-core-style CSV. **Every row** is one assay:

```csv
patient,specimen,assay_id,genome,bam,bai
P01,P01_primary,P01_primary_ONT1,hg38,/abs/path/sample.bam,/abs/path/sample.bam.bai
```

Required columns: `patient`, `specimen`, `assay_id`, `genome`, `bam`.
Optional: `bai`. Schema enforced by `assets/schema_input.json` (JSON
Schema — `nf-validation` / `nf-schema` compatible).

Each row becomes a Nextflow `meta` map with `id` mirroring `assay_id`, so
stock nf-core modules (`tag "${meta.id}"`) keep working unchanged.

## casetrack project setup

Before running the pipeline, the casetrack project must declare every
tool you plan to run:

```bash
casetrack init --project-dir /abs/path/to/cohort --from-template hgsoc --bare
```

Then append a `[analyses.<tool>]` block to `casetrack.toml` for each
tracked tool. For the modkit pilot:

```toml
[analyses.modkit_pileup]
level         = "assay"
column_prefix = "modkit"
summary_tsv   = "modkit_summary.tsv"
```

The template's default `[layout]` section already declares the tool-first
path:

```toml
[layout]
results_dir = "results"

[layout.path_templates]
assay = "{tool}/{run_tag}/{patient_id}/{specimen_id}/{assay_id}"
```

Finally, register your patient/specimen/assay hierarchy:

```bash
casetrack register --project-dir /abs/path/to/cohort --level patient  --id P01
casetrack register --project-dir /abs/path/to/cohort --level specimen --id P01_primary   --parent P01
casetrack register --project-dir /abs/path/to/cohort --level assay    --id P01_primary_ONT1 --parent P01_primary --meta 'assay_type=ONT'
```

## Running the pipeline

```bash
nextflow run main.nf \
    -profile slurm,apptainer \
    --input                 samplesheet.csv \
    --fasta                 /path/to/hg38.fa \
    --fai                   /path/to/hg38.fa.fai \
    --casetrack_project_dir /abs/path/to/cohort \
    --run_tag               20260418_hg38_v1
```

After the run, the casetrack DB has one row per assay with columns
`modkit_mean_meth`, `modkit_n_cpgs`, `modkit_mean_cov`, `modkit_run_tag`,
and `modkit_pileup_done` — populated via a single
`casetrack append --infer-from-path` call per sample.

## Stub smoke test

```bash
bash test/run_test.sh
```

Creates a temp casetrack project, generates a 1-row stub samplesheet, runs
`nextflow -stub` (which short-circuits `modkit pileup` but exercises the
full wiring), and asserts the row landed in SQLite with the right values.
Completes in ~30s with no real inputs required.

## Adding a new tracked subworkflow (recipe)

1. **Vendor the nf-core module**: `nf-core modules install <name>` or
   `cp` from a local `nf-core/modules` clone into
   `modules/nf-core/<name>/`.
2. **Write `modules/local/summarize_<tool>.nf`** + matching Python script
   in `bin/`. Output a one-row TSV keyed on `assay_id`.
3. **Write `subworkflows/local/<tool>_tracked.nf`** modeled on
   `modkit_pileup_tracked.nf`. Invoke `CASETRACK_REGISTER` with
   `(meta, '<tool>', '<summary_filename>', summary_tsv)`.
4. **Add a `[analyses.<tool>]` block** to the casetrack project TOML with
   matching `level`, `column_prefix`, and `summary_tsv`.
5. **Append a stub assertion** to `test/run_test.sh` (or a sibling test).

No part of the stock nf-core module is modified.

## L2 — trace → manifest (shipped v0.2.0)

Every run ends with a `workflow.onComplete` hook that parses
`results/_nextflow/<run_tag>/execution_trace.txt` and writes per-assay
columns to casetrack via one `casetrack append --analysis <tool>_trace`
call per tool. This lets the DB answer "did this fail biologically or
did it run out of memory?" from a single query.

Columns added per tracked tool (`<prefix>` from `[analyses.<tool>].column_prefix`):

| Column | Type | Source |
|---|---|---|
| `{prefix}_slurm_job_id`    | TEXT    | Nextflow `native_id` (empty under local executor) |
| `{prefix}_realtime_sec`    | INTEGER | Nextflow `realtime` parsed from `"1h30m"` / `"5s"` |
| `{prefix}_peak_rss_bytes`  | INTEGER | Nextflow `peak_rss` parsed from `"500 MB"` / `"2 GB"` |
| `{prefix}_exit_status`     | INTEGER | Nextflow `exit` (0 on success) |
| `{prefix}_attempts`        | INTEGER | Nextflow `attempt` (last retry wins) |
| `{prefix}_queue`           | TEXT    | SLURM queue (empty under local executor) |
| `{prefix}_pileup_trace_done`| TEXT   | Timestamp of trace import (auto-added by `casetrack append`) |

Processes without a matching `[analyses.<tool>]` entry (e.g. our own
`SUMMARIZE_MODKIT` and `CASETRACK_REGISTER`) are automatically skipped.

Opt out via `--casetrack_import_trace=false` on the pipeline invocation.

## Roadmap

- **L3 — versions → manifest**: the nf-core `topic: versions` channel
  gets collected via `collectFile` and written as run-level metadata via
  `casetrack add-metadata`.
- **More wrappers**: `DORADO_BASECALLER`, `MODKIT_CALLMODS`,
  `CLAIR3_GERMLINE`, `SNIFFLES2`, `SAMTOOLS_SORT`.
- **nf-core pipeline integration**: drop-in `-c casetrack.config` for
  `nf-core/methylseq`, `nf-core/sarek`.

## License

MIT (same as casetrack).
