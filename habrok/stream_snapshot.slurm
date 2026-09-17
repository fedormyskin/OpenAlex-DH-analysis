#!/bin/bash
# =============================================================================
# stream_snapshot.slurm — Habrok job: stream + filter the OpenAlex works snapshot
# -----------------------------------------------------------------------------
# Runs script 19 on Habrok to stream the full works snapshot from S3 (free,
# --no-sign-request) and build the compact TSV index on /scratch. CPU + network
# job, NO GPU. The full snapshot is ~639 GB compressed across 2,128 parts; this
# streams one part at a time and deletes it, so peak disk is small — but the
# TRANSFER is large, so use MAX_PARTS to do it in batches across several jobs.
#
# BEFORE SUBMITTING:
#   1. Code under PROJECT_DIR (edit below to your actual path).
#   2. The AWS CLI comes from the awscli module (loaded below). Verify the exact
#      name with `module avail awscli`.
#   3. Decide ALL-WORKS (no filter, recommended) vs a subfield filter.
#
# Submit one batch:   sbatch habrok/stream_snapshot.slurm
# Re-submit until the log says "ALL parts processed" (it resumes via .done_parts).
# Chain batches:      sbatch --dependency=afterany:<prev_jobid> habrok/stream_snapshot.slurm
# =============================================================================
#SBATCH --job-name=oa-stream
#SBATCH --time=24:00:00              # whole snapshot in one run (overnight)
#SBATCH --partition=regular
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G                     # streaming is light on RAM
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err

set -euo pipefail

# --- paths (EDIT for your setup) ---------------------------------------------
# Use the SAME PROJECT_DIR as your other habrok/*.slurm scripts.
PROJECT_DIR="/home4/p306511/ondemand/data/sys/myjobs/projects/default/4/OpenAlex-DH-analysis"
cd "${PROJECT_DIR}"
mkdir -p logs

# All snapshot data lives on /scratch (large; $HOME is only ~20 GB).
export OA_TMP_DIR="/scratch/$USER/oa_tmp"            # transient .gz parts
export OA_INDEX_DIR="/scratch/$USER/openalex_index"  # the growing TSV index
export OA_ARCHIVE_DIR=""                             # no Synology on the cluster

# --- modules: aws CLI + a general python3 ------------------------------------
# The script needs BOTH `aws` (download) and `python3` (the per-line filter).
# The awscli module may not expose a general python3, so load Python too.
module purge
module load awscli/2.15.2-GCCcore-12.2.0
module load Python/3.11.3-GCCcore-12.3.0 2>/dev/null || \
  module load Python 2>/dev/null || true     # verify name: module avail Python
command -v aws     >/dev/null 2>&1 || { echo "ERROR: aws not on PATH after module load." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — load a Python module." >&2; exit 1; }
aws --version; python3 --version

# --- ALL-WORKS index (recommended): no subfield filter -----------------------
# (To build a narrow index instead, set SUBFIELD_FILTER, e.g. "1208,1203".)
unset SUBFIELD_FILTER || true

# Process the WHOLE snapshot in one run (MAX_PARTS=0 = no cap). The 24h limit
# above should cover all ~2,127 parts. Still resumable: if it does hit the wall,
# just resubmit and it continues from .done_parts.
export MAX_PARTS="${MAX_PARTS:-0}"

echo "=== streaming OpenAlex snapshot (all works) ==="
echo "TMP:   $OA_TMP_DIR"
echo "INDEX: $OA_INDEX_DIR"
echo "MAX_PARTS this job: $MAX_PARTS"

bash R/19_download_filter_snapshot.sh

echo "=== batch done. Re-submit until it reports ALL parts processed, then: ==="
echo "  sbatch habrok/build_index.slurm   (TSV -> Parquet via 20a)"
