###############################################################################
# DH Citation Endogeneity Study
# 00_setup.R — Run this ONCE to initialize the project environment
#
# This script:
#   1. Installs renv (if missing)
#   2. Initializes renv for this project
#   3. Installs all required packages
#   4. Creates a lockfile (renv.lock) that pins exact package versions
#
# After running this, anyone can reproduce the environment with:
#   renv::restore()
###############################################################################

# Step 1: Install renv if not available
if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

# Step 2: Initialize renv for this project
renv::init(bare = TRUE)

# Step 3: Install required packages
renv::install(c(
  "openalexR",
  "tidyverse",
  "httr2",
  "jsonlite"
))

# Step 4: Snapshot — creates renv.lock with exact versions
renv::snapshot()

cat("\n=== Setup complete ===\n")
cat("A renv.lock file has been created with pinned package versions.\n")
cat("To reproduce this environment on another machine, run: renv::restore()\n")
cat("\nNext steps:\n")
cat("  1. Copy .Renviron.example to .Renviron and add your API key\n")
cat("  2. Restart R\n")
cat("  3. Run the scripts in R/ in order (01, 02, 03)\n")
