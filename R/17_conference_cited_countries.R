# =============================================================================
# 17_conference_cited_countries.R   (OFFLINE — reads the local parquet index)
# -----------------------------------------------------------------------------
# For every cited work that the matcher (script 21) resolved to an OpenAlex ID,
# get the COUNTRY of its authors. The OpenAlex API title/batch endpoints were
# unusable (timeouts), so we resolved everything offline against the snapshot
# index — and that SAME index already carries a `countries` column per work. So
# we get cited-work countries with a LOCAL DuckDB join, no API calls at all.
#
# OUTPUT (schema unchanged, so script 18 runs as-is):
#   data/output/17_conf_cited_works.csv     (unique cited works + country)
#   data/output/17_conf_citation_edges.csv  (conf work -> cited country)
#
# INPUT  : data/output/16_reference_matches.csv     (accepted matches)
#          $OA_INDEX_DIR/works_index_parquet/        (the snapshot index)
# Run:  Rscript R/17_conference_cited_countries.R
#       (on Habrok with OA_INDEX_DIR=/scratch/$USER/openalex_index)
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(duckdb)
  library(DBI)
})

out_dir   <- file.path("data", "output")
index_dir <- Sys.getenv("OA_INDEX_DIR",
  unset = "/Users/fedor/Library/CloudStorage/SynologyDrive-sync/openalex_index")

# DuckDB read_parquet() glob (directory of parts), with single-file fallback.
parquet_dir  <- file.path(index_dir, "works_index_parquet")
parquet_file <- file.path(index_dir, "works_index.parquet")
if (dir.exists(parquet_dir)) {
  parquet_glob <- file.path(parquet_dir, "*.parquet")
} else if (file.exists(parquet_file)) {
  parquet_glob <- parquet_file
} else {
  stop("No parquet index found: ", parquet_dir, "/ or ", parquet_file)
}

matches <- readr::read_csv(file.path(out_dir, "16_reference_matches.csv"),
                           show_col_types = FALSE) %>%
  filter(!is.na(openalex_id))
cat("Accepted matches:", nrow(matches),
    "| unique cited works:", dplyr::n_distinct(matches$openalex_id), "\n")

# --- pull cited-work country + year from the parquet index (LOCAL join) -------
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA temp_directory='%s'",
                       Sys.getenv("TMPDIR", unset = tempdir())))
duckdb::duckdb_register(con, "ids",
                        data.frame(id = unique(matches$openalex_id)))

# The index column is `countries` (';'-joined ISO codes, full counting) and
# `year`. We rename to match the project's schema (countries_str, publication_year).
cited_works <- dbGetQuery(con, sprintf("
  SELECT w.id,
         TRY_CAST(NULLIF(w.year, '') AS INTEGER) AS publication_year,
         NULLIF(w.countries, '')                 AS countries_str
  FROM read_parquet('%s') w
  JOIN ids ON w.id = ids.id", parquet_glob)) %>%
  distinct(id, .keep_all = TRUE)

readr::write_csv(cited_works, file.path(out_dir, "17_conf_cited_works.csv"))

# --- build conference citation edges -----------------------------------------
# One row per (conference work -> cited work) carrying the cited work's country.
# Works with no country in the index are dropped (reported as coverage below).
edges <- matches %>%
  select(work_id, openalex_id, ref_quality, confidence) %>%
  left_join(cited_works %>% select(openalex_id = id,
                                   cited_countries = countries_str,
                                   cited_year = publication_year),
            by = "openalex_id") %>%
  filter(!is.na(cited_countries))

readr::write_csv(edges, file.path(out_dir, "17_conf_citation_edges.csv"))

# --- report / coverage -------------------------------------------------------
n_cited      <- nrow(cited_works)
n_with_cc    <- sum(!is.na(cited_works$countries_str))
cat("\n=== 17 (offline) done ===\n")
cat("Cited works resolved in index:        ", n_cited, "\n")
cat("  with country data:                  ", n_with_cc,
    sprintf("(%.1f%%)\n", 100 * n_with_cc / max(1, n_cited)))
cat("Citation edges (with cited country):  ", nrow(edges), "\n")
cat("Conference works with >=1 usable edge:", dplyr::n_distinct(edges$work_id), "\n")
cat("\nNOTE: edges without a cited country are dropped (no affiliation data in\n")
cat("      OpenAlex). This is a coverage limitation, not an error.\n")
