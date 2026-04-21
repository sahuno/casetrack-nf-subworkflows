# `CASETRACK_REGISTER` — internals and forking guide

The `CASETRACK_REGISTER` process at `modules/local/casetrack_register.nf` is the load-bearing bookkeeping step in every tracked subworkflow. Don't fork it casually — its current shape encodes several non-obvious decisions. This doc explains them so you can fork safely if you must.

## Full source

```groovy
process CASETRACK_REGISTER {
    tag "${tool}:${meta.id}"
    executor 'local'
    maxForks 1
    errorStrategy 'retry'
    maxRetries 2

    input:
    tuple val(meta), val(tool), val(summary_name), path(summary_tsv)

    output:
    tuple val(meta), val(tool), emit: ok

    when:
    task.ext.when == null || task.ext.when

    script:
    def bin     = params.casetrack_bin ?: 'casetrack'
    def proj    = params.casetrack_project_dir
    def run_tag = params.run_tag
    def level   = params.casetrack_level ?: 'assay'
    if (!proj)    error "params.casetrack_project_dir is required"
    if (!run_tag) error "params.run_tag is required"
    def leaf = _resolve_leaf(proj, tool, run_tag, level, meta)
    """
    set -euo pipefail
    LEAF="${leaf}"
    mkdir -p "\$LEAF"
    cp -f "${summary_tsv}" "\$LEAF/${summary_name}"
    cd "\$LEAF"
    ${bin} append --infer-from-path --overwrite
    """
}

def _resolve_leaf(proj, tool, run_tag, level, meta) {
    if (level == 'assay')
        return "${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}/${meta.assay_id}"
    else if (level == 'specimen')
        return "${proj}/results/${tool}/${run_tag}/${meta.patient}/${meta.specimen}"
    else if (level == 'patient')
        return "${proj}/results/${tool}/${run_tag}/${meta.patient}"
    else
        error "params.casetrack_level must be one of: assay, specimen, patient (got '${level}')"
}
```

## Why each load-bearing detail

### `executor 'local'`

casetrack writes go through SQLite WAL with `busy_timeout = 30000`. WAL is genuinely concurrent-safe, but:
- Submitting a sub-second SQLite write to SLURM wastes 30+s of queue time per assay
- Running on the head node keeps `provenance.jsonl` line-readable (no concurrent prefix interleaving)

If you have a strong reason to run on SLURM (e.g. the casetrack DB lives on a filesystem only mounted on compute nodes), keep `maxForks 1`.

### `maxForks 1`

Even though SQLite WAL is concurrent-safe, this serializes writes through one process at a time. Reasons:
- `provenance.jsonl` is append-only; serialization keeps each entry on its own line, intact and grep-able
- One process gets one error message per failure mode; concurrent processes can mask each other's errors
- The performance cost is negligible: each `casetrack append` is ~50ms

If you must remove this for a fan-in shape with thousands of assays, switch to a batch register pattern (collect summaries, single append at end) rather than parallelizing the SQLite writer.

### `errorStrategy 'retry'` + `maxRetries 2`

casetrack appends can fail transiently for two reasons:
- SQLite `busy` if another process holds the WAL write lock past the busy timeout
- Filesystem hiccup on the shared `/data1/greenbab` mount

Two retries cover both. If a register fails 3 times, the underlying issue is real (FK violation, schema drift, corrupted summary) — let NF fail loudly so you investigate.

### `cp -f` then `cd` then `casetrack append --infer-from-path`

This sequence is the canonical "stage at the leaf, append from the leaf" pattern. casetrack's `--infer-from-path` walks up to `casetrack.toml` and matches the cwd against `[layout.path_templates]` to recover tool/run_tag/patient/specimen/assay. Why the verbose form:

- `cp -f` (force) handles re-runs cleanly — old TSVs get overwritten
- `cd "$LEAF"` rather than `casetrack append --results "$LEAF/...tsv"` because `--infer-from-path` requires the cwd to match a path template
- `--overwrite` is mandatory for reruns (fill-only is the default; without `--overwrite` the rerun silently no-ops at the DB level)

### `set -euo pipefail`

Catches: any failed cp, any failed append, any unset var. Without `-u` a typo in `${meta.patient}` (e.g. `${meta.patien}`) silently produces `proj/results/tool/run_tag//specimen/assay` — the missing path component breaks `--infer-from-path` and the failure mode is confusing.

## Path template — keep in sync with `casetrack.toml`

The `_resolve_leaf` helper hardcodes the path shape per level. This must match what users have in their `casetrack.toml`:

```toml
[layout]
results_dir = "results"

[layout.path_templates]
patient  = "{tool}/{run_tag}/{patient_id}"
specimen = "{tool}/{run_tag}/{patient_id}/{specimen_id}"
assay    = "{tool}/{run_tag}/{patient_id}/{specimen_id}/{assay_id}"
```

If a user customizes their templates, `_resolve_leaf` will produce a path that doesn't match what `--infer-from-path` expects — register will fail.

**Future improvement**: read `casetrack schema show --fmt json` once at workflow init and use the actual templates. For now, this is a known limitation; the default templates are what the demo and real-world runs use.

## When forking is justified

Don't fork for cosmetic changes. Do fork if:

- You need to publish a different file from the leaf (e.g. multiple summary TSVs per analysis — split into separate analyses instead)
- You're running on a non-SQLite backend (DuckDB-native, postgres, etc.) — but at that point you're really writing a sibling process, not a fork
- You need pre/post hooks (e.g. recording figures to a separate dashboard) — wrap CASETRACK_REGISTER in your own subworkflow rather than forking the module

## Common register failures and what they mean

| Error message (from `casetrack append --infer-from-path`) | Cause | Fix |
|---|---|---|
| `Error: --analysis is required (or infer it with --infer-from-path)` | The cwd doesn't match any `[layout.path_templates]` entry, OR no analysis has a `summary_tsv` matching a file in the cwd | Check the leaf path; check the filename matches `summary_tsv` in TOML |
| `sqlite3.IntegrityError: FOREIGN KEY constraint failed` | The patient/specimen/assay row doesn't exist yet | Register the entity with `casetrack add-metadata` before running the pipeline |
| `Error: project at <path> is missing v0.6 identity wiring` | Casetrack project predates v0.6 and lacks `project_id` | Run `casetrack migrate-project-id --project-dir <path>` once |
| `database is locked` (after retries) | Another long-running write is holding the WAL lock past `busy_timeout` | Increase `[engine] busy_timeout_ms` in the project's TOML; or check for a stale `casetrack` process |
| Silent: NF says success but `<analysis>_done` is NULL | `summary_tsv` filename mismatch (between subworkflow output and TOML) | The 3-place check: subworkflow `path()`, subworkflow tuple element 3, TOML `summary_tsv` — all must match |

## Trace import side-channel

Independent of `CASETRACK_REGISTER`, the L2 trace import (`bin/trace_to_casetrack.py`, runs on `workflow.onComplete`) reads `trace.txt` and writes `<analysis>_realtime_sec`, `<analysis>_peak_rss_bytes`, `<analysis>_exit_status` etc. into the entity row. This uses `nf_process` from `casetrack.toml` to map a trace row to an analysis. If your subworkflow's underlying process name doesn't match `nf_process`, the data registration via `CASETRACK_REGISTER` still works but the trace columns stay NULL.
