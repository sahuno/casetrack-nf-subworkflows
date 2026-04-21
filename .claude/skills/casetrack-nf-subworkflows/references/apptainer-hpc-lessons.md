# Apptainer + HPC survival guide for casetrack-nf-subworkflows

Eight hard-won fixes from running these subworkflows on MSKCC IRIS (RHEL 8, Apptainer, SLURM). Each one shipped after a real debugging session — the symptoms below are exactly what you'll see, and the fixes are what we now do every time.

---

## 1. `apptainer.cacheDir` must be set explicitly

**Symptom**: Apptainer re-pulls the same images on every run; home directory quota fills up; pulls time out under shared filesystem load.

**Cause**: Without an explicit cacheDir, Apptainer stores pulled images under the NF work-dir's `/tmp` path (or `~/.apptainer/`), which is per-run ephemeral or quota-bound.

**Fix** in `nextflow.config`:
```groovy
apptainer {
    enabled    = true
    autoMounts = true
    cacheDir   = '/data1/greenbab/users/ahunos/apptainer_cache'   // <-- this
}
```

Use a path on `/data1/greenbab` that survives across runs. The cache directory holds the downloaded `.sif` files; subsequent runs reuse them.

---

## 2. nf-core modules break under apptainer — override containers

**Symptom**: nf-core module fails to start with one of:
- `community.wave.seqera.io/library/...: 401 Unauthorized`
- `Error pulling image from docker://...`
- `unable to retrieve manifest`

**Cause**: nf-core modules check `workflow.containerEngine == 'singularity'` to decide which container URI to use. Under Apptainer (newer Nextflow), `containerEngine` is `'apptainer'`, not `'singularity'`. The check fails, NF falls to the Docker pull branch (`docker://community.wave.seqera.io/...`), which requires Seqera Wave authentication you don't have.

**Fix**: in the `apptainer` profile of `nextflow.config`, override containers per-process to local `.sif` files:

```groovy
apptainer {
    process {
        withName: 'SAMTOOLS_SORT_TRACKED:SAMTOOLS_SORT' {
            container = '/data1/greenbab/users/ahunos/apps/containers/onttools_latest.sif'
        }
        withName: 'MODKIT_CALLMODS_TRACKED:MODKIT_CALLMODS' {
            container = '/data1/greenbab/users/ahunos/apps/containers/modkit_latest.sif'
        }
        withName: 'SNIFFLES2_TRACKED:SNIFFLES' {
            container = '/data1/greenbab/users/ahunos/apps/containers/sniffles_2.6.2.sif'
        }
    }
}
```

Use the full subworkflow:process selector (`SAMTOOLS_SORT_TRACKED:SAMTOOLS_SORT`) — this scopes the override to the tracked subworkflow's invocation only, so other uses of the same module elsewhere in your pipeline aren't affected.

**Long-term**: when nf-core modules drop the `containerEngine == 'singularity'` check (or recognize `apptainer` as equivalent), this workaround can be removed.

---

## 3. Minimal containers lack `ps` — bind it from the host

**Symptom**: NF logs show `Command 'ps' not found`. Task metrics (peak RSS, CPU%) come back as zero or missing in `trace.txt`.

**Cause**: Nextflow runs `ps` inside the container periodically to collect process metrics. Lean biocontainer-style images (modkit, sniffles, sometimes samtools) don't include `procps`. Fuller images (onttools) have `ps` and work without intervention.

**Fix**: bind the host's `ps` into every container:
```groovy
apptainer.runOptions = '--bind /data1/greenbab --bind /usr/bin/ps:/usr/bin/ps'
```

Works because `/usr/bin/ps` is a static binary on most distros, so it runs fine inside the container's userspace.

---

## 4. GPU containers need `--nv` flag

**Symptom**: Container that uses CUDA fails with `Failed to load NVML` or `cuda: device not found`. `nvidia-smi` inside the container says no devices.

**Cause**: Without `--nv`, Apptainer doesn't pass the host's NVIDIA driver libraries (libnvidia-ml.so, libcuda.so, etc.) into the container.

**Fix**: in the `gpu` profile (composed with apptainer):
```groovy
gpu {
    apptainer.runOptions = '--bind /data1/greenbab --nv'   // --nv enables NVIDIA passthrough
    process {
        withLabel: 'process_high_gpu' {
            queue          = 'componc_gpu_batch'           // see #8
            clusterOptions = '--gres=gpu:1'
            memory         = '0'
            cpus           = 8
            time           = '24h'
        }
    }
}
```

Use as `-profile slurm,apptainer,gpu`. The order matters — `gpu`'s `apptainer.runOptions` overrides the apptainer profile's, so don't drop `--bind /data1/greenbab` from the gpu version.

---

## 5. `NXF_WORK` must be on /data1/greenbab, not /tmp

**Symptom**: A process that handles multi-GB BAMs is killed silently with `terminated by external system` partway through. Logs show no Java stack trace, no OOM. Often the same workflow runs to completion on smaller inputs.

**Cause**: Compute nodes at MSKCC have variable `/tmp` sizes (some 4GB, some 100GB). When the NF work dir lives on `/tmp` and a sort/merge step needs to spill, it can fill `/tmp` and the kernel kills the process.

**Fix** in the SLURM submit script:
```bash
#!/bin/bash -l
#SBATCH ...
export NXF_WORK="/data1/greenbab/users/ahunos/casetrack_projects/<proj>/validation/nxf_work/${TAG}_${SLURM_JOB_ID}"
mkdir -p "$NXF_WORK"

nextflow run ... -work-dir "$NXF_WORK" ...
```

Putting `NXF_WORK` on `/data1/greenbab` (shared, ample storage) eliminates the silent-kill failure mode entirely. Trade-off: NF work dirs accumulate; clean up after successful runs (`rm -rf "$NXF_WORK"` once you've verified outputs are persisted in `data/processed/`).

---

## 6. `casetrack.toml` `summary_tsv` must match subworkflow output exactly

**Symptom**: Job runs to completion. NF says success. But `casetrack append --infer-from-path` errors with `Error: --analysis is required (or infer it with --infer-from-path)`, or the DB's `<analysis>_done` column stays NULL.

**Cause**: `--infer-from-path` walks up to `casetrack.toml`, finds the analysis whose `summary_tsv` matches the file in the cwd, and uses its `[analyses.<name>]` block. If no `summary_tsv` matches, inference fails.

**Verified filenames** (subworkflow output ↔ TOML `summary_tsv`):
- `samtools_sort` → `samtools_sort_summary.tsv` (NOT `sort_summary.tsv`)
- `dorado_basecaller` → `dorado_basecaller_summary.tsv` (NOT `dorado_summary.tsv`)
- `modkit_callmods` → `modkit_callmods_summary.tsv`
- `modkit_pileup` → `modkit_summary.tsv`
- `sniffles2` → `sniffles2_summary.tsv`

**Fix**: pick one canonical name per analysis, and use it in **three** places:
1. The `path("name.tsv")` output declaration in `SUMMARIZE_<TOOL>.nf`
2. The 3rd element of the tuple in the subworkflow's `CASETRACK_REGISTER` invocation
3. The `summary_tsv = "name.tsv"` value in the consuming project's `[analyses.<tool>]` block

When you add a new tracked subworkflow, paste this 3-place check into your PR description.

---

## 7. `nf_process` in `casetrack.toml` must match the actual NF process name

**Symptom**: L2 trace import (`bin/trace_to_casetrack.py`) runs without error but the `<analysis>_trace_done` column stays NULL on every entity. Or trace columns (`<analysis>_realtime_sec`, `<analysis>_peak_rss_bytes`) stay NULL.

**Cause**: `trace_to_casetrack.py` matches `casetrack.toml [analyses.<name>].nf_process` against the `process` field in `trace.txt`. If they don't match exactly, no rows get imported.

**Verified gotcha**: nf-core's sniffles module is named `SNIFFLES`, not `SNIFFLES2`. The wrapper subworkflow is `SNIFFLES2_TRACKED` but the underlying process is still `SNIFFLES`.

**Fix**: check `trace.txt` after a real run:
```bash
awk -F'\t' 'NR > 1 {print $4}' trace.txt | sort -u
```

Then set `nf_process = "<exact-name>"` in `casetrack.toml`. Caps matter; subworkflow prefix is implicit.

---

## 8. GPU partition is `componc_gpu_batch`

**Symptom**: GPU job either:
- Submits successfully but never starts (waits in queue forever)
- Starts but reports no GPU available
- Submits to the wrong partition entirely

**Cause**: The default `slurm` profile in nextflow.config sets `queue = 'componc_cpu'`, which has no GPUs. Just adding `--gres=gpu:1` is insufficient — you also have to pick a GPU-capable partition.

**Fix**: in the `gpu` profile:
```groovy
gpu {
    process {
        withLabel: 'process_high_gpu' {
            queue          = 'componc_gpu_batch'   // <-- the partition matters
            clusterOptions = '--gres=gpu:1'
            // ...
        }
    }
}
```

Other GPU partitions exist on IRIS (`componc_gpu_long`, `componc_gpu_a100_batch`) — check `sinfo -p componc_gpu_*` for the current options. `componc_gpu_batch` has the loosest time limits and is the default for ONT basecalling work.

---

## Bonus: container build pitfalls (Apptainer `%post`)

If you're building containers FROM scratch for these subworkflows (rather than using prebuilt `.sif` files):

- **Never `rm -rf /tmp/*` or `rm -rf /var/tmp/*` in `%post`.** Under `--fakeroot`, the container's `/tmp` is a bind mount of the host's `/tmp` — you'll delete other users' files and abort the build. Only remove files you explicitly created by name.
- **`condaforge/miniforge3` base requires `--ignore-fakeroot-command` on RHEL 8.** Their `fakeroot` binary is GLIBC ≥ 2.33; RHEL 8's GLIBC is 2.28. Use:
  ```
  apptainer build --fakeroot --ignore-fakeroot-command output.sif input.def
  ```
- **Never `apt-get` in `--fakeroot` builds on MSKCC HPC.** apt drops to the `_apt` user via `setgroups()`, which is blocked in root-mapped namespace. Use a conda-ready base and install via `mamba`.
- **Always `unset APPTAINER_BIND SINGULARITY_BIND` before building.** These env vars apply during `%post` and fail the build if a bind source path doesn't exist inside the base image.
