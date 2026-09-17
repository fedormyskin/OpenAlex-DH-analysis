#!/bin/bash
# =============================================================================
# build_index.slurm — Habrok job: TSV -> Parquet -> title index
# -----------------------------------------------------------------------------
# Runs the memory-heavy offline-index steps on Habrok, where RAM is plentiful
# (the 7M-row inverted index OOM'd on an 8 GB laptop). This is a CPU+RAM job —
# NO GPU needed.
#
# Pipeline: 20a (TSV -> Parquet) then 20 (Parquet -> works_index.rds).
#
# BEFORE SUBMITTING:
#   1. Put the project code under $HOME/OpenAlex-DH-analysis (edit PROJECT_DIR).
#   2. Put works_index.tsv (from script 19) under /scratch/$USER/openalex_index.
#   3. Install the R packages ONCE into your personal library (see README/skill):
#        arrow, data.table, stringi, stringdist, dplyr, readr
#      (arrow may need:  LIBARROW_BINARY=true  to fetch a prebuilt binary)
#   4. Confirm an R module name with:  module avail R   (edit R_MODULE below).
#
# Submit:  sbatch habrok/build_index.slurm
# =============================================================================
#SBATCH --job-name=oa-build-index
#SBATCH --time=08:00:00              # ~484M rows chunked ~5h; resumable if it overruns
#SBATCH --partition=regular           # CPU partition (no GPU)
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G                      # 20a now converts in row-chunks (memory-safe);
                                       # peak is one chunk, not the whole TSV.
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err

set -euo pipefail

# --- paths (EDIT for your setup) ---------------------------------------------
PROJECT_DIR="/home4/p306511/ondemand/data/sys/myjobs/projects/default/4/OpenAlex-DH-analysis"
export OA_INDEX_DIR="/scratch/$USER/openalex_index"
# Load the ARROW module, which brings R 4.3.2 + a working arrow together. (The
# arrow R package must match the R version; this module pairs them. Do NOT also
# load a separate R/4.5.x module — versions must not be mixed.)
R_MODULE="arrow-R/14.0.1-foss-2023a-R-4.3.2"

cd "${PROJECT_DIR}"
mkdir -p logs

module purge
module load "${R_MODULE}"

# Personal R library — KEEP IT R-VERSION-SPECIFIC so packages built for R 4.3.2
# don't collide with any built for another R. The other packages (data.table,
# stringi, stringdist, dplyr, readr) must be installed here under R 4.3.2.
export R_LIBS_USER="$HOME/R/habrok-library"
mkdir -p "$R_LIBS_USER"

# ALL-WORKS pipeline: convert TSV -> Parquet only. The DuckDB matcher
# (21_match_references_duckdb.R) queries the Parquet directly, so the old
# in-RAM index build (script 20) is NOT used at this scale — it would OOM on a
# ~250M-row index. DuckDB streams from the Parquet and spills to disk instead.
echo "=== TSV -> Parquet (20a) ==="
Rscript R/20a_tsv_to_parquet.R

echo "=== done. Parquet index DIRECTORY at $OA_INDEX_DIR/works_index_parquet/ ==="
ls -la "$OA_INDEX_DIR"/works_index_parquet/ | head || true
echo "parts: $(ls "$OA_INDEX_DIR"/works_index_parquet/*.parquet 2>/dev/null | wc -l)"
echo "Next: sbatch habrok/match_references.slurm  (runs 21_match_references_duckdb.R)"
