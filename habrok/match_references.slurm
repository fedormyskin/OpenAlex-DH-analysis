#!/bin/bash
# =============================================================================
# match_references.slurm — Habrok job: offline reference matching
# -----------------------------------------------------------------------------
# Runs script 21 (DOI + exact-title + fuzzy matching) against the local index
# built by build_index.slurm. CPU+RAM job, no GPU.
#
# PREREQS: build_index.slurm has produced $OA_INDEX_DIR/works_index_parquet/ (a
# directory of parquet parts), and the reference inputs (15_conf_references.csv,
# 15b_parsed_references.csv) are in $PROJECT_DIR/data/output/.
#
# Submit:  sbatch habrok/match_references.slurm
#   or chain after the build:  sbatch --dependency=afterok:<build_jobid> ...
# =============================================================================
#SBATCH --job-name=oa-match-refs
#SBATCH --time=06:00:00              # fuzzy join vs ~459M-row index is heavy; generous
#SBATCH --partition=regular
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G                    # DuckDB capped at 40G (DUCKDB_MEM_LIMIT) + R/OS overhead
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err

set -euo pipefail

PROJECT_DIR="/home4/p306511/ondemand/data/sys/myjobs/projects/default/4/OpenAlex-DH-analysis"
export OA_INDEX_DIR="/scratch/$USER/openalex_index"
# Arrow module = R 4.3.2 + arrow together (match the build_index job). Don't mix
# R versions.
R_MODULE="arrow-R/14.0.1-foss-2023a-R-4.3.2"

cd "${PROJECT_DIR}"
mkdir -p logs

module purge
module load "${R_MODULE}"
# Use the SAME personal R library you installed the packages into. (Must include
# duckdb, DBI, arrow, data.table, stringi, stringdist, tidyverse.)
export R_LIBS_USER="$HOME/R/habrok-library"

# DuckDB spills large intermediates to TMPDIR — put it on /scratch (big), not the
# small home filesystem, or the all-works fuzzy join can fill the disk.
export TMPDIR="/scratch/$USER/duckdb_tmp"
mkdir -p "$TMPDIR"

echo "=== offline reference matching (DuckDB, all-works scale) ==="
Rscript R/21_match_references_duckdb.R

echo "=== done. Outputs in data/output/ ==="
ls -la data/output/16_reference_matches*.csv data/output/21_offline_match_report.txt || true
echo "Copy data/output/16_reference_matches*.csv back to your laptop, then run 17-18."
