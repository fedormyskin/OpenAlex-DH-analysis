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
  # Core pipeline (scripts 01–03)
  "openalexR",
  "tidyverse",
  "httr2",
  "jsonlite",
  # Analysis (script 03)
  "lme4",
  "countrycode",
  # Comparator analysis (scripts 04–05)
  # (no extra packages — uses openalexR + tidyverse)
  # Conference linkage + endogeneity (scripts 13–18)
  "xml2",        # parse TEI/XML full text for references (script 15)
  "stringdist",  # title/name similarity for reference matching (script 16)
  "stringi",     # accent-stripping / transliteration (scripts 15–16)
  "cld3",        # language detection on reference titles (script 15b)
  # Visualization (script 06)
  "igraph",
  "ggraph",
  "tidygraph",
  "viridis",
  "patchwork",
  "scales"
))

# Step 4: Snapshot — creates renv.lock with exact versions
renv::snapshot()

cat("\n=== Setup complete ===\n")
cat("A renv.lock file has been created with pinned package versions.\n")
cat("To reproduce this environment on another machine, run: renv::restore()\n")
cat("\nNext steps:\n")
cat("  1. Copy .Renviron.example to .Renviron and add your API key\n")
cat("  2. Restart R\n")
cat("  3. Run the scripts in R/ in order (01, 02, 03, ...)\n")
cat("     Conference linkage/endogeneity: 13, then 15 -> 16 -> 17 -> 18\n")
