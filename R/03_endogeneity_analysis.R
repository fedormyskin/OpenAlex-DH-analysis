###############################################################################
# DH Citation Endogeneity Study
# Phase 3: Endogeneity analysis, bridge scholars, temporal trends
#
# Reads the DH corpus and cited works data from Phases 1-2, then:
#   - Builds citing → cited country pairs
#   - Computes endogeneity under two definitions (any overlap, majority)
#   - Computes diversity metrics (Shannon entropy, HHI)
#   - Identifies bridge scholars
#   - Analyses temporal trends
###############################################################################

library(tidyverse)

# --- 1. Load data -------------------------------------------------------------

dh_corpus   <- readRDS("data/02_dh_corpus_full.rds")
cited_works <- read_csv("data/04_cited_works.csv", show_col_types = FALSE)

cat("DH corpus:", nrow(dh_corpus), "works\n")
cat("Cited works:", nrow(cited_works), "works\n")

# --- 2. Build citation-level dataset -----------------------------------------

# For each DH work, expand its referenced_works and join country data

cat("\n--- Building citation-level dataset ---\n")

citations <- dh_corpus |>
  select(citing_id = id, citing_year = publication_year,
         citing_countries = countries_str,
         citing_n_countries = n_countries,
         citing_is_multicountry = is_multicountry,
         citing_has_country = has_country,
         source_journal, source_keyword, dh_level,
         referenced_works) |>
  filter(citing_has_country) |>  # Only works with known country

  # Unnest referenced works
  unnest(referenced_works) |>
  rename(cited_id = referenced_works) |>

  # Join country data of cited works
  left_join(
    cited_works |> select(cited_id = id,
                           cited_countries = countries_str,
                           cited_year = publication_year),
    by = "cited_id"
  ) |>
  filter(!is.na(cited_countries))  # Only citations where we know cited country

cat("Citation-level records (with country data on both sides):", nrow(citations), "\n")

# --- 3. Compute endogeneity per citation --------------------------------------

cat("\n--- Computing endogeneity ---\n")

# Parse country strings into lists for set operations
citations <- citations |>
  mutate(
    citing_countries_list = str_split(citing_countries, ";"),
    cited_countries_list  = str_split(cited_countries, ";"),

    # Approach 1: ANY overlap
    overlap = map2_int(citing_countries_list, cited_countries_list,
                        ~ length(intersect(.x, .y))),
    endogenous_any = overlap > 0,

    # Approach 2: MAJORITY of citing countries are in cited countries
    majority_share = map2_dbl(citing_countries_list, cited_countries_list,
                               ~ length(intersect(.x, .y)) / length(.x)),
    endogenous_majority = majority_share > 0.5
  )

cat("Endogeneity rates (overall):\n")
cat("  Any overlap:  ", round(100 * mean(citations$endogenous_any), 1), "%\n")
cat("  Majority rule:", round(100 * mean(citations$endogenous_majority), 1), "%\n")

# --- 4. Country-level endogeneity ---------------------------------------------

cat("\n--- Country-level endogeneity ---\n")

# Expand to citing-country level (full counting)
# Each citation contributes once per citing country
citation_by_citing_country <- citations |>
  select(citing_id, cited_id, citing_year, citing_countries_list,
         cited_countries_list, endogenous_any, endogenous_majority) |>
  unnest(citing_countries_list) |>
  rename(citing_country = citing_countries_list)

# For each citing_country, compute endogeneity and diversity
country_stats <- citation_by_citing_country |>
  group_by(citing_country) |>
  summarise(
    n_citations       = n(),
    n_citing_works    = n_distinct(citing_id),
    endogenous_any_n  = sum(endogenous_any),
    endogenous_maj_n  = sum(endogenous_majority),
    scr_any           = endogenous_any_n / n_citations,
    scr_majority      = endogenous_maj_n / n_citations,
    .groups = "drop"
  ) |>
  arrange(desc(n_citations))

# Citation diversity: where does each country cite?
# Expand cited countries too
citation_country_pairs <- citation_by_citing_country |>
  unnest(cited_countries_list) |>
  rename(cited_country = cited_countries_list) |>
  count(citing_country, cited_country, name = "n_cites")

# Shannon entropy and HHI per citing country
diversity_stats <- citation_country_pairs |>
  group_by(citing_country) |>
  mutate(
    total = sum(n_cites),
    p     = n_cites / total
  ) |>
  summarise(
    n_countries_cited = n(),
    shannon_entropy   = -sum(p * log(p)),
    hhi               = sum(p^2),
    .groups = "drop"
  )

country_stats <- country_stats |>
  left_join(diversity_stats, by = "citing_country")

cat("\nTop 20 countries by citation volume:\n")
print(
  country_stats |>
    head(20) |>
    select(citing_country, n_citations, n_citing_works,
           scr_any, scr_majority, shannon_entropy, n_countries_cited) |>
    mutate(across(where(is.numeric), ~ round(.x, 3)))
)

write_csv(country_stats, "data/05_country_endogeneity.csv")

# --- 5. Expected endogeneity (null model) -------------------------------------

cat("\n--- Null model: expected endogeneity ---\n")

# Under random citation, the probability of a citation from country c
# being endogenous = share of cited works from country c in the cited pool
# (i.e., if US produces 40% of cited works, US self-citation by chance = 40%)

cited_country_share <- cited_works |>
  filter(!is.na(countries_str)) |>
  mutate(countries_list = str_split(countries_str, ";")) |>
  unnest(countries_list) |>
  count(country = countries_list, name = "n_cited_works") |>
  mutate(share_in_cited = n_cited_works / sum(n_cited_works))

country_stats <- country_stats |>
  left_join(
    cited_country_share |> select(citing_country = country, expected_scr = share_in_cited),
    by = "citing_country"
  ) |>
  mutate(
    excess_endogeneity_any = scr_any - expected_scr,
    excess_endogeneity_maj = scr_majority - expected_scr
  )

cat("Countries with highest excess endogeneity (any overlap, min 50 citations):\n")
print(
  country_stats |>
    filter(n_citations >= 50) |>
    arrange(desc(excess_endogeneity_any)) |>
    head(15) |>
    select(citing_country, n_citations, scr_any, expected_scr, excess_endogeneity_any) |>
    mutate(across(where(is.numeric), ~ round(.x, 3)))
)

write_csv(country_stats, "data/05_country_endogeneity.csv")

# --- 6. Temporal analysis ------------------------------------------------------

cat("\n--- Temporal analysis ---\n")

# Endogeneity by year (overall)
temporal_overall <- citations |>
  group_by(citing_year) |>
  summarise(
    n_citations     = n(),
    scr_any         = mean(endogenous_any),
    scr_majority    = mean(endogenous_majority),
    .groups = "drop"
  ) |>
  filter(citing_year >= 2000, citing_year <= 2025)

cat("Endogeneity over time (overall):\n")
print(temporal_overall |> mutate(across(starts_with("scr"), ~ round(.x, 3))))

write_csv(temporal_overall, "data/06_temporal_overall.csv")

# Endogeneity by year and country (top countries)
top_countries <- country_stats |>
  filter(n_citations >= 100) |>
  pull(citing_country)

temporal_by_country <- citation_by_citing_country |>
  filter(citing_country %in% top_countries) |>
  group_by(citing_country, citing_year) |>
  summarise(
    n_citations  = n(),
    scr_any      = mean(endogenous_any),
    scr_majority = mean(endogenous_majority),
    .groups = "drop"
  ) |>
  filter(citing_year >= 2000, citing_year <= 2025)

write_csv(temporal_by_country, "data/07_temporal_by_country.csv")

# --- 7. Bridge scholars --------------------------------------------------------

cat("\n--- Identifying bridge scholars ---\n")

# Extract author-level data from DH corpus
# For each author, aggregate the countries of their cited works

author_citations <- dh_corpus |>
  filter(has_country) |>
  select(citing_id = id, authorships, referenced_works, citing_countries = countries_str) |>
  # Extract author IDs
  # openalexR may return authorships as a data frame or list of lists
  mutate(
    author_ids = map(authorships, function(a_list) {
      if (is.data.frame(a_list)) {
        # Data frame format: author column is a nested df/list-column
        if ("author" %in% names(a_list) && is.data.frame(a_list$author)) {
          a_list$author$id %||% character(0)
        } else if ("au_id" %in% names(a_list)) {
          a_list$au_id %||% character(0)
        } else {
          character(0)
        }
      } else if (is.list(a_list)) {
        # List-of-lists format
        map_chr(a_list, ~ .x$author$id %||% NA_character_)
      } else {
        character(0)
      }
    })
  ) |>
  select(citing_id, author_ids, referenced_works, citing_countries) |>
  unnest(author_ids) |>
  filter(!is.na(author_ids)) |>
  unnest(referenced_works) |>
  rename(cited_id = referenced_works) |>
  left_join(
    cited_works |> select(cited_id = id, cited_countries = countries_str),
    by = "cited_id"
  ) |>
  filter(!is.na(cited_countries))

# Compute author-level citation diversity
author_diversity <- author_citations |>
  mutate(cited_countries_list = str_split(cited_countries, ";")) |>
  unnest(cited_countries_list) |>
  rename(cited_country = cited_countries_list) |>
  group_by(author_id = author_ids) |>
  summarise(
    n_citations_total = n(),
    n_works           = n_distinct(citing_id),
    n_countries_cited  = n_distinct(cited_country),
    .groups = "drop"
  )

# Compute entropy per author
author_entropy <- author_citations |>
  mutate(cited_countries_list = str_split(cited_countries, ";")) |>
  unnest(cited_countries_list) |>
  rename(cited_country = cited_countries_list) |>
  count(author_id = author_ids, cited_country) |>
  group_by(author_id) |>
  mutate(p = n / sum(n)) |>
  summarise(
    shannon_entropy = -sum(p * log(p)),
    hhi             = sum(p^2),
    top_country     = cited_country[which.max(n)],
    top_country_share = max(p),
    .groups = "drop"
  )

# Author's own country
author_own_country <- dh_corpus |>
  filter(has_country) |>
  select(authorships, countries_str) |>
  mutate(
    author_data = map2(authorships, countries_str, function(a_list, c_str) {
      if (is.data.frame(a_list)) {
        # Data frame format from openalexR
        ids <- if ("author" %in% names(a_list) && is.data.frame(a_list$author)) {
          a_list$author$id
        } else if ("au_id" %in% names(a_list)) {
          a_list$au_id
        } else {
          rep(NA_character_, nrow(a_list))
        }
        display_names <- if ("author" %in% names(a_list) && is.data.frame(a_list$author)) {
          a_list$author$display_name
        } else if ("au_display_name" %in% names(a_list)) {
          a_list$au_display_name
        } else {
          rep(NA_character_, nrow(a_list))
        }
        country_strs <- vapply(seq_len(nrow(a_list)), function(i) {
          a_countries <- character()
          if ("countries" %in% names(a_list)) {
            a_countries <- c(a_countries, unlist(a_list$countries[[i]]))
          }
          if ("institutions" %in% names(a_list)) {
            inst <- a_list$institutions[[i]]
            if (is.data.frame(inst) && "country_code" %in% names(inst)) {
              a_countries <- c(a_countries, inst$country_code)
            } else if (is.list(inst)) {
              for (item in inst) {
                if (!is.null(item$country_code)) a_countries <- c(a_countries, item$country_code)
              }
            }
          }
          paste(sort(unique(toupper(a_countries))), collapse = ";")
        }, character(1))
        tibble(author_id = ids, author_name = display_names, author_countries = country_strs)
      } else if (is.list(a_list)) {
        # List-of-lists format
        map_dfr(a_list, function(a) {
          a_countries <- character()
          if (!is.null(a$countries)) a_countries <- unlist(a$countries)
          if (!is.null(a$institutions)) {
            for (inst in a$institutions) {
              if (!is.null(inst$country_code)) a_countries <- c(a_countries, inst$country_code)
            }
          }
          tibble(
            author_id = a$author$id %||% NA_character_,
            author_name = a$author$display_name %||% NA_character_,
            author_countries = paste(sort(unique(toupper(a_countries))), collapse = ";")
          )
        })
      } else {
        tibble(author_id = character(), author_name = character(), author_countries = character())
      }
    })
  ) |>
  select(author_data) |>
  unnest(author_data) |>
  filter(!is.na(author_id), author_countries != "") |>
  distinct(author_id, .keep_all = TRUE)

# Self-citation rate per author
author_self_cite <- author_citations |>
  mutate(
    citing_countries_list = str_split(citing_countries, ";"),
    cited_countries_list  = str_split(cited_countries, ";"),
    endogenous = map2_lgl(citing_countries_list, cited_countries_list,
                           ~ length(intersect(.x, .y)) > 0)
  ) |>
  group_by(author_id = author_ids) |>
  summarise(
    self_cite_rate = mean(endogenous),
    .groups = "drop"
  )

# Combine
bridge_scholars <- author_diversity |>
  left_join(author_entropy, by = "author_id") |>
  left_join(author_self_cite, by = "author_id") |>
  left_join(author_own_country, by = "author_id") |>
  filter(n_works >= 5, n_citations_total >= 20) |>  # Minimum thresholds
  arrange(desc(shannon_entropy))

cat("\nBridge scholar candidates (min 5 works, 20 citations):", nrow(bridge_scholars), "\n")

cat("\nTop 20 bridge scholars by citation entropy:\n")
print(
  bridge_scholars |>
    head(20) |>
    select(author_name, author_countries, n_works, n_countries_cited,
           shannon_entropy, self_cite_rate, top_country, top_country_share) |>
    mutate(across(where(is.numeric), ~ round(.x, 3)))
)

write_csv(bridge_scholars, "data/08_bridge_scholars.csv")

# --- 8. Country-pair citation matrix -------------------------------------------

cat("\n--- Building country-pair citation matrix ---\n")

# Full citation flow matrix: citing_country → cited_country
flow_matrix <- citation_country_pairs |>
  pivot_wider(
    names_from  = cited_country,
    values_from = n_cites,
    values_fill = 0
  )

# Save as CSV (for inspection) and as a matrix (for network analysis)
write_csv(flow_matrix, "data/09_citation_flow_matrix.csv")

cat("Citation flow matrix:", nrow(flow_matrix), "×",
    ncol(flow_matrix) - 1, "countries\n")

# --- 9. Summary report --------------------------------------------------------

cat("\n")
cat("================================================================\n")
cat("   DH CITATION ENDOGENEITY - ANALYSIS COMPLETE\n")
cat("================================================================\n")
cat("\nCorpus: ", nrow(dh_corpus), "DH works\n")
cat("Citations analysed:", nrow(citations), "\n")
cat("Countries represented:", n_distinct(citation_by_citing_country$citing_country), "\n")
cat("\nOverall endogeneity:\n")
cat("  Any overlap:  ", round(100 * mean(citations$endogenous_any), 1), "%\n")
cat("  Majority rule:", round(100 * mean(citations$endogenous_majority), 1), "%\n")
cat("\nBridge scholars identified:", nrow(bridge_scholars), "\n")
cat("\nOutput files in data/:\n")
cat("  05_country_endogeneity.csv   - Country-level metrics\n")
cat("  06_temporal_overall.csv      - Endogeneity over time\n")
cat("  07_temporal_by_country.csv   - Endogeneity by country × year\n")
cat("  08_bridge_scholars.csv       - Bridge scholar rankings\n")
cat("  09_citation_flow_matrix.csv  - Country × country citation flows\n")
