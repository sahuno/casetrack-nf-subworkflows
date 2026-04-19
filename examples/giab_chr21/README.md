# GIAB chr21 worked example

Runs `MODKIT_PILEUP_TRACKED` on a single GIAB HG006 chr21 ONT BAM and lands
the results in a casetrack project. This is the real pipeline from the v0.2.0
pilot (see [proposal 0004 §Pilot](https://github.com/sahuno/casetrack/blob/main/docs/proposals/0004-nextflow-integration.md#pilot--giab-hg006-chr21-2026-04-19)).

## Prerequisites

- `casetrack` ≥ 0.5.0 on PATH
- Nextflow ≥ 24.04
- Apptainer / Singularity
- MSKCC IRIS access with the `greenbab` SLURM account (edit paths for your site)
- Read access to:
  - `/data1/greenbab/projects/GIAB_ont/GIAB_data/giab_2025.01/data/processed/hg38/chr21_bams/HG006_PAY77227.hg38.chr21.bam`
  - `/data1/greenbab/database/hg38/v0/Homo_sapiens_assembly38.fasta`

## Quick start

```bash
# 1. One-time project setup (30 seconds)
bash 00_init_project.sh

# 2. Launch the pipeline (real modkit run, ~30–60 min on SLURM with Prolog)
bash run.sh
```

## Files in this directory

| File | Purpose |
|---|---|
| `00_init_project.sh`  | creates the casetrack project + `[analyses.modkit_pileup]` + registers HG006 hierarchy |
| `samplesheet.csv`     | one row for HG006_PAY77227; edit paths for your site |
| `custom.config`       | pins the Galaxy depot singularity URL, sizes the summarize process to 4 GB |
| `run.sh`              | the `nextflow run` invocation |

## Expected casetrack row after a successful run

```
assay_id         | modkit_mean_meth | modkit_n_cpgs | modkit_mean_cov
HG006_PAY77227   | 0.0424           | 14406945      | 16.64

modkit_slurm_job_id | modkit_realtime_sec | modkit_peak_rss_bytes | modkit_exit_status | modkit_queue
19512075            | 155                 | 9985798963 (~10 GB)   | 0                  | componc_cpu
```

See [docs/TUTORIAL.md](../../docs/TUTORIAL.md) for the full walkthrough.
