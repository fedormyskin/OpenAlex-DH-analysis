# =============================================================================
# 13_load_conference_data.R
# -----------------------------------------------------------------------------
# Load the Index of DH Conferences data extract (CMU) and build tidy tables that
# are COMPARABLE to the OpenAlex corpus used in scripts 01-12.
#
# WHAT THIS SCRIPT DOES (in plain terms):
#   The conference dataset is a relational database split across many CSV files.
#   A person, their institution, and that institution's country are stored in
#   SEPARATE files that must be joined together with shared ID columns. This
#   script performs those joins once and saves two clean tables:
#
#     1. conf_authorships  -> one row per (author on a work), with name + country
#     2. conf_works        -> one row per conference work, with year + host info
#
#   Nothing here touches the network or the OpenAlex API. It is fully
#   reproducible from the local CSVs in data/dh_conferences_data/.
#
# INPUT  : data/dh_conferences_data/*.csv       (the CMU extract)
#          data/tgn_to_iso.csv                  (country-name -> ISO crosswalk)
# OUTPUT : data/output/13_conf_authorships.csv
#          data/output/13_conf_works.csv
#          data/output/13_conf_load_report.txt  (coverage diagnostics)
#
# Run from the project root:  Rscript R/13_load_conference_data.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

# --- Paths -------------------------------------------------------------------
conf_dir   <- file.path("data", "dh_conferences_data")
out_dir    <- file.path("data", "output")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

read_conf <- function(name) {
  readr::read_csv(file.path(conf_dir, name), show_col_types = FALSE,
                  progress = FALSE)
}

# --- 1. Read the raw relational tables ---------------------------------------
works        <- read_conf("works.csv")
authorships  <- read_conf("authorships.csv")
appellations <- read_conf("appellations.csv")
aff_link     <- read_conf("authorship_affiliation.csv")  # authorship <-> affiliation
affiliations <- read_conf("affiliations.csv")            # affiliation -> institution
institutions <- read_conf("institutions.csv")            # institution -> country
countries    <- read_conf("countries.csv")               # country id -> pref_name
conferences  <- read_conf("conferences.csv")

# Country-name -> ISO alpha-2 crosswalk (built in a separate, auditable step).
# We join on the conference country *id* to avoid any name-spelling mismatch.
tgn_iso <- readr::read_csv(file.path("data", "tgn_to_iso.csv"),
                           show_col_types = FALSE) %>%
  select(country_id, iso2)

# --- 2. Author name per authorship -------------------------------------------
# Each authorship points to ONE appellation (the name as given on that abstract).
auth_named <- authorships %>%
  left_join(appellations, by = c("appellation" = "id")) %>%
  transmute(
    authorship_id   = id,
    author_id       = author,          # internal CMU author id (NOT OpenAlex)
    work_id         = work,
    authorship_order,
    first_name,
    last_name,
    # A single display name used later for OpenAlex matching.
    full_name = str_squish(paste(coalesce(first_name, ""),
                                 coalesce(last_name, "")))
  )

# --- 3. Country per authorship (via affiliation -> institution -> country) ----
# An authorship may carry 0, 1, or several affiliations. We keep them all
# (full counting), mirroring the OpenAlex convention used in this project.
authorship_country <- aff_link %>%
  left_join(affiliations, by = c("affiliation" = "id")) %>%
  left_join(institutions, by = c("institution" = "id"),
            suffix = c("", "_inst")) %>%
  left_join(tgn_iso, by = c("country" = "country_id")) %>%
  left_join(countries %>% select(id, pref_name),
            by = c("country" = "id")) %>%
  transmute(
    authorship_id    = authorship,
    institution_id   = institution,
    institution_name = name,
    country_name     = pref_name,
    country_iso2     = iso2
  ) %>%
  filter(!is.na(authorship_id)) %>%
  distinct()

# --- 4. conf_authorships: name + (possibly multiple) countries ---------------
# One row per (authorship x affiliation-country). Authorships with no resolved
# affiliation still appear once, with NA country, so coverage is transparent.
conf_authorships <- auth_named %>%
  left_join(authorship_country, by = "authorship_id")

# --- 5. conf_works: work-level metadata + conference host country ------------
conf_host <- conferences %>%
  left_join(tgn_iso, by = c("country" = "country_id")) %>%
  left_join(countries %>% select(id, pref_name),
            by = c("country" = "id")) %>%
  transmute(
    conference_id    = id,
    conf_year        = year,
    conf_short_title = short_title,
    conf_country     = pref_name,
    conf_country_iso2 = iso2
  )

# --- Venue grouping: ADHO-GLOBAL lineage vs REGIONAL/other -------------------
# The Index of DH Conferences mixes the global ADHO annual conference (and the
# predecessor series that merged into it) with many regional/national/thematic
# conferences. A national conference (e.g. DHd in German-speaking countries) is
# geographically concentrated BY DESIGN, so lumping it with the global venue
# would mechanically inflate self-country citation. We tag each conference's
# venue_group so endogeneity can be computed separately:
#   "ADHO-global" = series 1 (ADHO) + its predecessors 2 (ACH/ICCH),
#                   3 (ALLC/EADH), 4 (ACH/ALLC) — the same international annual
#                   conference across eras.
#   "regional"    = every other series (national/regional/thematic), plus
#                   conferences with no series membership.
ADHO_SERIES <- c(1, 2, 3, 4)
series_mem   <- read_conf("conference_series_membership.csv")  # conference <-> series
series_names <- read_conf("conference_series.csv") %>%         # series id -> label
  transmute(series = id, series_abbr = abbreviation)

# A conference can belong to several series (co-branding). Treat it as ADHO-global
# if ANY of its series is in the ADHO lineage.
conf_is_adho <- series_mem %>%
  mutate(is_adho = series %in% ADHO_SERIES) %>%
  group_by(conference) %>%
  summarise(any_adho = any(is_adho), .groups = "drop")

# --- venue_series (finer granularity, B1 rule) -------------------------------
# Unlike the binary venue_group, venue_series keeps each regional series SEPARATE
# (regional conferences are not interchangeable), assigning each conference to a
# single series label by the B1 precedence:
#   1. If the conference is in any ADHO-lineage series (1-4) -> "ADHO-global".
#   2. Else assign its MOST-SPECIFIC regional series (the series with the FEWEST
#      member conferences); ties broken by lowest series id for determinism.
#   3. No series membership at all -> "unaffiliated".
# (Empirically only ONE non-ADHO conference belongs to >1 series, so the
#  most-specific tiebreak affects a single conference; the rule is documented
#  here for reproducibility regardless.)
series_size <- series_mem %>% count(series, name = "series_n_conf")

# regional (non-ADHO) membership only, ranked most-specific first
regional_pick <- series_mem %>%
  filter(!series %in% ADHO_SERIES) %>%
  left_join(series_size, by = "series") %>%
  group_by(conference) %>%
  arrange(series_n_conf, series, .by_group = TRUE) %>%   # fewest members, then id
  slice(1) %>%
  ungroup() %>%
  left_join(series_names, by = "series") %>%
  transmute(conference, regional_series = coalesce(series_abbr, as.character(series)))

conf_venue_series <- conf_is_adho %>%
  left_join(regional_pick, by = "conference") %>%
  mutate(venue_series = case_when(
    any_adho                      ~ "ADHO-global",
    !is.na(regional_series)       ~ regional_series,
    TRUE                          ~ "unaffiliated"
  )) %>%
  select(conference, venue_series)

conf_works <- works %>%
  transmute(
    work_id      = id,
    conference_id = conference,
    title,
    work_type,
    parent_session
  ) %>%
  left_join(conf_host, by = "conference_id") %>%
  left_join(conf_is_adho, by = c("conference_id" = "conference")) %>%
  left_join(conf_venue_series, by = c("conference_id" = "conference")) %>%
  mutate(
    venue_group  = ifelse(coalesce(any_adho, FALSE), "ADHO-global", "regional"),
    # conferences with no series row at all land here as NA -> "unaffiliated"
    venue_series = coalesce(venue_series, "unaffiliated")
  ) %>%
  select(-any_adho)

# --- 6. Write outputs --------------------------------------------------------
readr::write_csv(conf_authorships, file.path(out_dir, "13_conf_authorships.csv"))
readr::write_csv(conf_works,       file.path(out_dir, "13_conf_works.csv"))

# --- 7. Coverage report (so limitations are explicit, per open-science aims) --
n_authorships      <- nrow(auth_named)
n_with_country     <- conf_authorships %>%
  filter(!is.na(country_iso2)) %>% distinct(authorship_id) %>% nrow()
n_conf             <- nrow(conferences)
n_conf_country     <- conf_host %>% filter(!is.na(conf_country_iso2)) %>% nrow()
n_unique_names     <- auth_named %>% distinct(first_name, last_name) %>% nrow()
n_unique_authors   <- auth_named %>% distinct(author_id) %>% nrow()

report <- c(
  "=== 13_load_conference_data.R coverage report ===",
  sprintf("Generated: %s", Sys.time()),
  "",
  sprintf("Works (abstracts):                 %d", nrow(works)),
  sprintf("Authorships:                       %d", n_authorships),
  sprintf("  with a resolved country (ISO2):  %d (%.1f%%)",
          n_with_country, 100 * n_with_country / n_authorships),
  sprintf("Conferences:                       %d", n_conf),
  sprintf("  with a resolved host country:    %d (%.1f%%)",
          n_conf_country, 100 * n_conf_country / n_conf),
  "",
  sprintf("Distinct internal author IDs:      %d", n_unique_authors),
  sprintf("Distinct (first,last) name pairs:  %d", n_unique_names),
  "  -> ~this many OpenAlex /authors queries in script 15 (after dedup).",
  "",
  "NOTE: internal author IDs are abstract-scoped, NOT OpenAlex A-IDs.",
  "      Cross-dataset author identity is resolved probabilistically in 15-16."
)
writeLines(report, file.path(out_dir, "13_conf_load_report.txt"))
cat(paste(report, collapse = "\n"), "\n")
