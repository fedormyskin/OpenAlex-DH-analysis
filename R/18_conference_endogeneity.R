# =============================================================================
# 18_conference_endogeneity.R
# -----------------------------------------------------------------------------
# Run the SAME citation-endogeneity analysis used for the journal corpus
# (script 03 -> 05_country_endogeneity.csv) on the CONFERENCE data, so results
# can be reported SIDE BY SIDE. Output columns match 05 exactly, with a
# "_conf" suffix on the filename.
#
# CITING side : a conference work's own author countries (from script 13).
# CITED  side : countries of the works it references (from script 17 edges).
#
# Metrics reproduced from script 03 (identical formulas):
#   * endogenous_any  / endogenous_majority   (per citation)
#   * scr_any / scr_majority                  (per citing country)
#   * shannon_entropy / hhi                   (citation diversity)
#   * expected_scr + excess + ratio           (null model)
#   * z_score_any / p_value_any               (permutation test)
#
# READ THIS BEFORE REPORTING (bias warning):
#   Conference endogeneity is computed only on works that had full text AND
#   parseable references AND whose cited works resolved to OpenAlex with country
#   data. That subset skews English-language / recent / well-formatted. The
#   coverage fraction is written to the report; report it alongside results.
#
# INPUT  : data/output/13_conf_authorships.csv       (citing countries)
#          data/output/13_conf_works.csv             (work -> year)
#          data/output/17_conf_citation_edges.csv    (cited countries)
#          data/output/17_conf_cited_works.csv       (null-model pool)
# OUTPUT : data/output/18_conf_country_endogeneity.csv   (mirror of 05)
#          data/output/18_conf_temporal_overall.csv
#          data/output/18_conf_citation_flow_matrix.csv
#          data/output/18_conf_endogeneity_report.txt
#
# Run:  Rscript R/18_conference_endogeneity.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

out_dir <- file.path("data", "output")

# Thresholds — kept identical to script 03 for comparability.
MIN_CITATIONS_THRESHOLD <- 100
# Separate, lower floor for the per-series breakdown only: regional series are
# small, so a 100-citation floor leaves just ADHO+DHd. 50 admits a few more
# series for the faceted figure WITHOUT weakening the country-level test above.
SERIES_MIN_CITATIONS    <- 50
N_PERMUTATIONS          <- 1000
TEMPORAL_START_YEAR     <- 2007
TEMPORAL_END_YEAR       <- 2025

# Venue subset (env var VENUE_GROUP): restrict the analysis to one venue group
# so the global ADHO conference is not confounded with mechanically-regional
# national conferences. Output files get a matching suffix.
#   "all"         -> every conference (default; original behaviour, no suffix)
#   "ADHO-global" -> only the international ADHO-lineage annual conference
#   "regional"    -> only regional/national/thematic conferences
VENUE_GROUP <- Sys.getenv("VENUE_GROUP", unset = "all")
SUFFIX <- switch(VENUE_GROUP,
                 "ADHO-global" = "_adho",
                 "regional"    = "_regional",
                 "")            # "all" -> no suffix
cat("Venue group:", VENUE_GROUP, "(output suffix:",
    ifelse(SUFFIX == "", "<none>", SUFFIX), ")\n")

# --- 1. Citing-side countries: one ';'-string per conference work ------------
conf_auth <- readr::read_csv(file.path(out_dir, "13_conf_authorships.csv"),
                             show_col_types = FALSE)
conf_works <- readr::read_csv(file.path(out_dir, "13_conf_works.csv"),
                              show_col_types = FALSE)

# Restrict to the chosen venue group (needs venue_group from the updated script 13).
if (VENUE_GROUP != "all") {
  if (!"venue_group" %in% names(conf_works)) {
    stop("conf_works has no 'venue_group' column — re-run the updated script 13.")
  }
  keep_works <- conf_works %>% filter(venue_group == VENUE_GROUP) %>% pull(work_id)
  conf_works <- conf_works %>% filter(work_id %in% keep_works)
  conf_auth  <- conf_auth  %>% filter(work_id %in% keep_works)
  cat("  works in this venue group:", length(keep_works), "\n")
}

citing_countries <- conf_auth %>%
  filter(!is.na(country_iso2), country_iso2 != "") %>%
  distinct(work_id, country_iso2) %>%
  group_by(work_id) %>%
  summarise(citing_countries = paste(sort(unique(country_iso2)), collapse = ";"),
            .groups = "drop")

# conference work year (the conference year) for temporal analysis
work_year <- conf_works %>% distinct(work_id, citing_year = conf_year)

# per-work venue series (finer than venue_group; written for the faceted figure)
work_series <- if ("venue_series" %in% names(conf_works)) {
  conf_works %>% distinct(work_id, venue_series)
} else {
  NULL
}

# --- 2. Citation edges with cited-country strings (from script 17) -----------
edges <- readr::read_csv(file.path(out_dir, "17_conf_citation_edges.csv"),
                         show_col_types = FALSE)

# --- 3. Citation-level dataset (mirror of script 03 section 2-3) -------------
citations <- edges %>%
  inner_join(citing_countries, by = "work_id") %>%
  left_join(work_year, by = "work_id") %>%
  rename(citing_id = work_id) %>%
  filter(!is.na(cited_countries)) %>%
  mutate(
    citing_countries_list = str_split(citing_countries, ";"),
    cited_countries_list  = str_split(cited_countries, ";"),
    overlap = map2_int(citing_countries_list, cited_countries_list,
                       ~ length(intersect(.x, .y))),
    endogenous_any = overlap > 0,
    majority_share = map2_dbl(citing_countries_list, cited_countries_list,
                              ~ length(intersect(.x, .y)) / length(.x)),
    endogenous_majority = majority_share > 0.5
  )

cat("Conference citation records:", nrow(citations), "\n")
cat("  Endogeneity (any overlap):  ",
    round(100 * mean(citations$endogenous_any), 1), "%\n")
cat("  Endogeneity (majority):     ",
    round(100 * mean(citations$endogenous_majority), 1), "%\n")

# --- 4. Country-level endogeneity (mirror of script 03 section 4) ------------
citation_by_citing_country <- citations %>%
  select(citing_id, citing_year, citing_countries_list,
         cited_countries_list, endogenous_any, endogenous_majority) %>%
  unnest(citing_countries_list) %>%
  rename(citing_country = citing_countries_list) %>%
  mutate(citing_country = as.character(citing_country)) %>%
  filter(!is.na(citing_country), citing_country != "")

country_stats <- citation_by_citing_country %>%
  group_by(citing_country) %>%
  summarise(
    n_citations      = n(),
    n_citing_works   = n_distinct(citing_id),
    endogenous_any_n = sum(endogenous_any),
    endogenous_maj_n = sum(endogenous_majority),
    scr_any          = endogenous_any_n / n_citations,
    scr_majority     = endogenous_maj_n / n_citations,
    .groups = "drop"
  ) %>%
  arrange(desc(n_citations))

# diversity (entropy / HHI)
citation_country_pairs <- citation_by_citing_country %>%
  unnest(cited_countries_list) %>%
  rename(cited_country = cited_countries_list) %>%
  mutate(cited_country = as.character(cited_country)) %>%
  filter(!is.na(cited_country), cited_country != "") %>%
  count(citing_country, cited_country, name = "n_cites")

diversity_stats <- citation_country_pairs %>%
  group_by(citing_country) %>%
  mutate(total = sum(n_cites), p = n_cites / total) %>%
  summarise(
    n_countries_cited = n(),
    shannon_entropy   = -sum(p * log(p)),
    hhi               = sum(p^2),
    .groups = "drop"
  )

country_stats <- country_stats %>% left_join(diversity_stats, by = "citing_country")

# --- 4b. Temporal outputs (written early so they're available even if the
#          permutation test below is slow or interrupted) ----------------------
temporal_overall <- citations %>%
  filter(!is.na(citing_year)) %>%
  group_by(citing_year) %>%
  summarise(n_citations  = n(),
            scr_any      = mean(endogenous_any),
            scr_majority = mean(endogenous_majority),
            .groups = "drop") %>%
  filter(citing_year >= TEMPORAL_START_YEAR, citing_year <= TEMPORAL_END_YEAR)
readr::write_csv(temporal_overall,
                 file.path(out_dir, paste0("18_conf_temporal_overall", SUFFIX, ".csv")))

temporal_by_country <- citation_by_citing_country %>%
  filter(!is.na(citing_year)) %>%
  group_by(citing_country, citing_year) %>%
  summarise(n_citations  = n(),
            scr_any      = mean(endogenous_any),
            scr_majority = mean(endogenous_majority),
            .groups = "drop") %>%
  filter(citing_year >= TEMPORAL_START_YEAR, citing_year <= TEMPORAL_END_YEAR)
readr::write_csv(temporal_by_country,
                 file.path(out_dir, paste0("18_conf_temporal_by_country", SUFFIX, ".csv")))

# --- 4c. Per-series endogeneity (B1 venue_series) ----------------------------
# Only meaningful on the full ("all") run, where every conference is present and
# venue_series keeps each regional series separate. Writes one row per series
# with the same metrics as the country table; 06b facets the series clearing the
# >=100-citation threshold.
if (VENUE_GROUP == "all" && !is.null(work_series)) {
  cit_series <- citations %>%
    select(citing_id, citing_year, endogenous_any, endogenous_majority) %>%
    left_join(work_series, by = c("citing_id" = "work_id")) %>%
    filter(!is.na(venue_series))

  series_stats <- cit_series %>%
    group_by(venue_series) %>%
    summarise(n_citations  = n(),
              n_works      = n_distinct(citing_id),
              scr_any      = mean(endogenous_any),
              scr_majority = mean(endogenous_majority),
              .groups = "drop") %>%
    mutate(meets_threshold = n_citations >= SERIES_MIN_CITATIONS) %>%
    arrange(desc(n_citations))
  readr::write_csv(series_stats,
                   file.path(out_dir, "18_conf_series_endogeneity.csv"))

  series_temporal <- cit_series %>%
    filter(!is.na(citing_year)) %>%
    group_by(venue_series, citing_year) %>%
    summarise(n_citations  = n(),
              scr_any      = mean(endogenous_any),
              scr_majority = mean(endogenous_majority),
              .groups = "drop") %>%
    filter(citing_year >= TEMPORAL_START_YEAR, citing_year <= TEMPORAL_END_YEAR)
  readr::write_csv(series_temporal,
                   file.path(out_dir, "18_conf_series_temporal.csv"))

  n_series_pass <- sum(series_stats$meets_threshold)
  cat("Per-series: ", nrow(series_stats), " series, ",
      n_series_pass, " clear >=", SERIES_MIN_CITATIONS, " citations\n", sep = "")
}

# --- 5. Null model + permutation test (mirror of script 03 section 5) --------
cited_pool <- citations$cited_countries

cited_country_share <- readr::read_csv(
    file.path(out_dir, "17_conf_cited_works.csv"), show_col_types = FALSE) %>%
  filter(!is.na(countries_str), countries_str != "") %>%
  mutate(countries_list = str_split(countries_str, ";")) %>%
  unnest(countries_list) %>%
  mutate(countries_list = as.character(countries_list)) %>%
  filter(!is.na(countries_list), countries_list != "") %>%
  count(country = countries_list, name = "n_cited_works") %>%
  mutate(share_in_cited = n_cited_works / sum(n_cited_works))

country_stats <- country_stats %>%
  left_join(cited_country_share %>%
              select(citing_country = country, expected_scr = share_in_cited),
            by = "citing_country") %>%
  mutate(
    excess_endogeneity_any = scr_any - expected_scr,
    excess_endogeneity_maj = scr_majority - expected_scr,
    endogeneity_ratio_any  = ifelse(expected_scr > 0, scr_any / expected_scr, NA_real_),
    endogeneity_ratio_maj  = ifelse(expected_scr > 0, scr_majority / expected_scr, NA_real_),
    meets_threshold        = n_citations >= MIN_CITATIONS_THRESHOLD
  )

perm_countries <- country_stats %>% filter(meets_threshold) %>% pull(citing_country)
set.seed(42)
cat("Countries meeting", MIN_CITATIONS_THRESHOLD, "citation threshold:",
    length(perm_countries), "\n")

if (length(perm_countries) > 0) {
  perm_results <- map_dfr(perm_countries, function(cc) {
    cd <- citation_by_citing_country %>% filter(citing_country == cc)
    n <- nrow(cd); observed <- mean(cd$endogenous_any)
    sim <- replicate(N_PERMUTATIONS, {
      s <- sample(cited_pool, n, replace = TRUE)
      mean(map_lgl(str_split(s, ";"), ~ cc %in% .x))
    })
    tibble(citing_country = cc,
           z_score_any = (observed - mean(sim)) / sd(sim),
           p_value_any = mean(sim >= observed))
  })
  country_stats <- country_stats %>% left_join(perm_results, by = "citing_country")
} else {
  cat("  WARNING: no country meets the threshold; skipping permutation test.\n")
  cat("  (Expected — conference citation volume is far smaller than journals.)\n")
  country_stats <- country_stats %>%
    mutate(z_score_any = NA_real_, p_value_any = NA_real_)
}

# Column order identical to 05_country_endogeneity.csv for easy side-by-side.
readr::write_csv(country_stats,
                 file.path(out_dir, paste0("18_conf_country_endogeneity", SUFFIX, ".csv")))

# --- 6. Citation flow matrix (mirror of 09) ----------------------------------
flow_matrix <- citation_country_pairs %>%
  pivot_wider(names_from = cited_country, values_from = n_cites, values_fill = 0)
readr::write_csv(flow_matrix,
                 file.path(out_dir, paste0("18_conf_citation_flow_matrix", SUFFIX, ".csv")))

# --- 7. Coverage / bias report -----------------------------------------------
total_works   <- nrow(conf_works)
works_in_anal <- dplyr::n_distinct(citations$citing_id)
report <- c(
  "=== 18_conference_endogeneity.R report ===",
  sprintf("Generated: %s", Sys.time()),
  "",
  sprintf("Conference works total:               %d", total_works),
  sprintf("Works entering endogeneity analysis:  %d (%.1f%%)",
          works_in_anal, 100 * works_in_anal / total_works),
  sprintf("Conference citation records:          %d", nrow(citations)),
  sprintf("Distinct citing countries:            %d",
          dplyr::n_distinct(citation_by_citing_country$citing_country)),
  sprintf("Countries >= %d citations:            %d",
          MIN_CITATIONS_THRESHOLD, length(perm_countries)),
  "",
  sprintf("Overall endogeneity (any overlap):    %.1f%%",
          100 * mean(citations$endogenous_any)),
  sprintf("Overall endogeneity (majority):       %.1f%%",
          100 * mean(citations$endogenous_majority)),
  "",
  "BIAS WARNING (report alongside results):",
  "  The analysed works are a SUBSET (full text + parseable refs + resolvable",
  "  cited works). This skews English-language / recent / well-formatted, which",
  "  cuts against the project's multilingual / Global-South aims. The journal",
  "  result in 05_country_endogeneity.csv is NOT subject to the same filter, so",
  "  any side-by-side comparison must foreground this coverage difference."
)
writeLines(report, file.path(out_dir, paste0("18_conf_endogeneity_report", SUFFIX, ".txt")))
cat(paste(report, collapse = "\n"), "\n")
