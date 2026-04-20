# ADR-001 — Level-aware L1 tracked wrappers

**Status**: accepted 2026-04-20
**Resolves**: proposal 0004 Q4 (patient/specimen-level tracked subworkflows — L1 half)
**Target**: casetrack-nf-subworkflows v0.5.0

## Context

`casetrack-nf-subworkflows` v0.1–v0.4 ships L1 wrappers (`*_tracked.nf`) that
assume one nextflow row = one assay. `CASETRACK_REGISTER` hardcodes the leaf
directory as `.../{patient}/{specimen}/{assay_id}/`, `input_check.nf` requires
`assay_id` in the samplesheet, `summarize_modkit.py` keys its output on
`assay_id`, and so on.

L2 (trace) and L3 (versions) importers became level-aware in v0.4.0 — they
accept `--level {patient,specimen,assay}`. L1 wrappers did not, so any tool
that naturally runs on a merged specimen-level BAM (MODKIT_MERGED,
downstream DMR callers, specimen-level QC) cannot use the tracked-wrapper
pattern today. Users fall back to local SLURM scripts + manual `casetrack
append`, which is exactly the friction the wrappers were designed to remove.

Concrete driver: `/data1/greenbab/users/ahunos/casetrack_projects/project_17424`
has a `modkit_merged` chain running on specimen-level merged BAMs. All of
the `modkit_merged_*` columns were populated by local SLURM scripts because
no specimen-level L1 wrapper exists.

## Decisions

### D1 — `level` is a pipeline param, not a per-row samplesheet column

`--casetrack_level {assay,specimen,patient}` is set once per nextflow run.
Every row in the samplesheet is processed at that level. Mixed-level runs
are expressed by invoking the pipeline twice with different samplesheets.

**Alternatives considered:**

- *Per-row `level` column*: maximum flexibility, but forces the samplesheet
  schema to carry a conditional-required `assay_id` and makes the L2/L3
  onComplete hook's "broadcast versions to all samplesheet rows" logic
  level-dependent per row. Complexity out of proportion to the value —
  real pipelines work on one biological granularity at a time.

- *Derive level from samplesheet column presence* (assay_id present → assay,
  absent → specimen): fragile; a blank cell silently changes behavior.

**Decided under ambiguity**: user accepted this under low conviction.
Revisit once a concrete mixed-level use case appears.

### D2 — `assay_id` column is absent from specimen-level samplesheets

When `level=specimen`, required columns are `patient, specimen, genome,
bam, bai`. `meta.id = meta.specimen_id`. Row lands in the `specimens`
SQLite table via `casetrack append --infer-from-path`.

**Alternatives considered:**

- *Keep `assay_id` optional, ignore at specimen level*: a silently-ignored
  column is a footgun. User adds a value expecting it to matter, nothing
  happens, and they debug a symptom two weeks later.

- *Keep `assay_id` as provenance* (comma-separated list of constituent
  assay_ids for the merged BAM): legitimate use case ("which flowcells
  went into this merged BAM?"), but belongs in a `source_assay_ids`
  column on the **summary TSV**, not in the samplesheet. The samplesheet
  names inputs; provenance belongs with outputs.

**Decided under ambiguity**: user accepted this under low conviction.
Revisit if users frequently need constituent-assay provenance from the
specimens row — introduce `source_assay_ids` as a TEXT column populated
by the summarize script, not by re-adding `assay_id` to the samplesheet.

### D3 — Patient-level deferred to a concrete driver

`--casetrack_level patient` is accepted by the CLI plumbing but no L1
wrapper ships with patient-level semantics in v0.5.0. Trigger for adding
one: a tool that operates naturally on patient-pooled data (e.g. joint
variant calling across all specimens from a patient). Until that exists,
patient-level is L2/L3 only — the level-aware infrastructure is in place,
the consumer isn't.

### D4 — Path template already handles multi-level (no new config)

Project TOMLs already carry:

```toml
[layout.path_templates]
patient  = "{tool}/{run_tag}/{patient_id}"
specimen = "{tool}/{run_tag}/{patient_id}/{specimen_id}"
assay    = "{tool}/{run_tag}/{patient_id}/{specimen_id}/{assay_id}"
```

`CASETRACK_REGISTER` reads the level via `params.casetrack_level` and
builds the leaf by substituting `meta.{patient,specimen,assay_id}` into
the matching template. No new TOML keys. `casetrack append
--infer-from-path` recovers level from the path depth.

### D5 — `meta.id` follows the level

At assay level, `meta.id = meta.assay_id` (unchanged).
At specimen level, `meta.id = meta.specimen_id`.
At patient level, `meta.id = meta.patient_id`.

Stock nf-core modules do `tag "${meta.id}"` — this keeps their logs
readable under any level without module edits.

## Consequences

### Code changes in v0.5.0

1. `modules/local/casetrack_register.nf` — resolve leaf path from
   `params.casetrack_level` + `[layout.path_templates.<level>]`.
2. `subworkflows/local/input_check.nf` — split into
   `input_check_assay.nf` + `input_check_specimen.nf` (or single file
   with a level branch); `meta.id` resolution is level-aware.
3. `assets/schema_input.json` — a second schema file
   `schema_input_specimen.json` (or one schema with a `oneOf`).
4. `bin/summarize_modkit.py` — accept `--key-col` + `--key-value`,
   default to assay for back-compat. Emits `{key_col}` as first TSV column.
5. `modules/local/summarize_modkit.nf` — pass level-appropriate key.
6. `main.nf` — L3 versions hook reads the samplesheet at a level-aware
   column index (driven by `params.casetrack_level`).
7. `subworkflows/local/modkit_merged_tracked.nf` — new, specimen-level
   reference wrapper.
8. `test/run_test_merged.sh` — new stub smoke test, specimen-level
   samplesheet, asserts specimens-table columns.

### Back-compat

Default `--casetrack_level` is `assay` when unset. Every existing
MODKIT_PILEUP_TRACKED invocation keeps working without changes.

### Out of scope for v0.5.0

- Patient-level L1 wrappers (D3).
- Cross-level single-run pipelines (D1).
- Source-assay provenance on specimen rows (D2, if needed later).

## References

- Proposal 0004 §Open Questions Q4
- Memory: `project_nextflow_level_contract.md`
- Driver project: `/data1/greenbab/users/ahunos/casetrack_projects/project_17424`
