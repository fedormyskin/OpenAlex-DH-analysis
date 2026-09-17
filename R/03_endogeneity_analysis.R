###############################################################################
# DH Citation Endogeneity Study
# Phase 3: Endogeneity analysis, bridge scholars, temporal trends
#
# Reads the DH corpus and cited works data from Phases 1-2, then:
#   - Builds citing → cited country pairs
#   - Computes endogeneity under two definitions (any overlap, majority)
#   - Computes diversity metrics (Shannon entropy, HHI)
#   - Computes null model with permutation testing
#   - Identifies bridge scholars
#   - Analyses temporal trends with convergence/divergence testing
###############################################################################

library(tidyverse)

# --- Configuration -----------------------------------------------------------

# Sensitivity analysis: filter corpus by journal tier
# Options: "all" (default), "exclusively", "core" (excl + keyword, no Significantly)
CORPUS_FILTER <- Sys.getenv("DH_CORPUS_FILTER", unset = "all")
OUTPUT_SUFFIX <- switch(CORPUS_FILTER,
  "exclusively" = "_exclusively",
  "core"        = "_core",
  ""  # default: no suffix
)

# Thresholds
MIN_CITATIONS_THRESHOLD <- 100
TOP_N_COUNTRIES         <- 15
TEMPORAL_START_YEAR     <- 2007
TEMPORAL_END_YEAR       <- 2025
BRIDGE_MIN_WORKS        <- 3
BRIDGE_MIN_CITATIONS    <- 10
N_PERMUTATIONS          <- as.integer(Sys.getenv("N_PERMUTATIONS", unset = "1000"))

cat("================================================================\n")
cat("   DH CITATION ENDOGENEITY ANALYSIS\n")
cat("   Corpus filter:", CORPUS_FILTER, "\n")
cat("================================================================\n\n")

# --- 1. Load data -------------------------------------------------------------

dh_corpus   <- readRDS("data/02_dh_corpus_full.rds")
cited_works <- read_csv("data/04_cited_works.csv", show_col_types = FALSE)

cat("DH corpus (raw):", nrow(dh_corpus), "works\n")
cat("Cited works:", nrow(cited_works), "works\n")

# Apply corpus filter for sensitivity analysis
if (CORPUS_FILTER == "exclusively") {
  cat("\n*** SENSITIVITY: Restricting to 'Exclusively' DH journals ***\n")
  dh_corpus <- dh_corpus |> filter(dh_level == "Exclusively")
} else if (CORPUS_FILTER == "core") {
  cat("\n*** SENSITIVITY: Restricting to 'Exclusively' + keyword_only ***\n")
  dh_corpus <- dh_corpus |> filter(dh_level %in% c("Exclusively", "keyword_only"))
}

cat("DH corpus (filtered):", nrow(dh_corpus), "works\n")
cat("  dh_level breakdown:\n")
print(table(dh_corpus$dh_level))

# --- 2. Build citation-level dataset -----------------------------------------

cat("\n--- Building citation-level dataset ---\n")

citations <- dh_corpus |>
  select(citing_id = id, citing_year = publication_year,
         citing_countries = countries_str,
         citing_n_countries = n_countries,
         citing_is_multicountry = is_multicountry,
         citing_has_country = has_country,
         source_journal, source_keyword, dh_level,
         referenced_works) |>
  filter(citing_has_country) |>

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
  filter(!is.na(cited_countries))

cat("Citation-level records (with country data on both sides):", nrow(citations), "\n")

# --- 3. Compute endogeneity per citation --------------------------------------

cat("\n--- Computing endogeneity ---\n")

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
citation_by_citing_country <- citations |>
  select(citing_id, cited_id, citing_year, citing_countries_list,
         cited_countries_list, endogenous_any, endogenous_majority) |>
  unnest(citing_countries_list) |>
  rename(citing_country = citing_countries_list) |>
  mutate(citing_country = as.character(citing_country)) |>
  filter(!is.na(citing_country), citing_country != "")

cat("  Citation-by-country records:", nrow(citation_by_citing_country), "\n")
cat("  Unique citing countries:", n_distinct(citation_by_citing_country$citing_country), "\n")
cat("  citing_country class:", class(citation_by_citing_country$citing_country), "\n")
cat("  Sample values:", paste(head(unique(citation_by_citing_country$citing_country), 10), collapse = ", "), "\n")

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

cat("\n  Country stats: ", nrow(country_stats), "countries\n")
cat("  Top 5 by citations:\n")
print(country_stats |> head(5) |> select(citing_country, n_citations))
cat("  Countries with >=", MIN_CITATIONS_THRESHOLD, "citations:",
    sum(country_stats$n_citations >= MIN_CITATIONS_THRESHOLD), "\n")

# Citation diversity: where does each country cite?
citation_country_pairs <- citation_by_citing_country |>
  unnest(cited_countries_list) |>
  rename(cited_country = cited_countries_list) |>
  mutate(cited_country = as.character(cited_country)) |>
  filter(!is.na(cited_country), cited_country != "") |>
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

# --- 5. Expected endogeneity (null model) + permutation test ------------------

cat("\n--- Null model: expected endogeneity ---\n")

# Simple null: expected SCR = country's share of the cited works pool
cited_country_share <- cited_works |>
  filter(!is.na(countries_str), countries_str != "") |>
  mutate(countries_list = str_split(countries_str, ";")) |>
  unnest(countries_list) |>
  mutate(countries_list = as.character(countries_list)) |>
  filter(!is.na(countries_list), countries_list != "") |>
  count(country = countries_list, name = "n_cited_works") |>
  mutate(share_in_cited = n_cited_works / sum(n_cited_works))

country_stats <- country_stats |>
  left_join(
    cited_country_share |> select(citing_country = country, expected_scr = share_in_cited),
    by = "citing_country"
  ) |>
  mutate(
    excess_endogeneity_any = scr_any - expected_scr,
    excess_endogeneity_maj = scr_majority - expected_scr,
    # Endogeneity ratio: how many times more endogenous than expected by chance
    endogeneity_ratio_any = ifelse(expected_scr > 0, scr_any / expected_scr, NA_real_),
    endogeneity_ratio_maj = ifelse(expected_scr > 0, scr_majority / expected_scr, NA_real_),
    # Citation threshold flag
    meets_threshold = n_citations >= MIN_CITATIONS_THRESHOLD
  )

# --- Permutation test for significance (countries with 100+ citations) ---

cat("Running permutation test (", N_PERMUTATIONS, "iterations) ...\n")

# Pool of cited country strings for resampling
cited_pool <- citations$cited_countries

# Countries that meet threshold
perm_countries <- country_stats |>
  filter(meets_threshold) |>
  pull(citing_country)

set.seed(42)

cat("  Countries meeting threshold:", length(perm_countries), "\n")

if (length(perm_countries) > 0) {
  perm_results <- map_dfr(perm_countries, function(cc) {
    # Get this country's actual citations
    country_data <- citation_by_citing_country |>
      filter(citing_country == cc)
    n <- nrow(country_data)
    observed_scr <- mean(country_data$endogenous_any)

    # Simulate: resample cited works from the global pool
    simulated_scrs <- replicate(N_PERMUTATIONS, {
      sampled <- sample(cited_pool, n, replace = TRUE)
      sampled_list <- str_split(sampled, ";")
      overlaps <- map_lgl(sampled_list, ~ cc %in% .x)
      mean(overlaps)
    })

    tibble(
      citing_country = cc,
      z_score_any    = (observed_scr - mean(simulated_scrs)) / sd(simulated_scrs),
      p_value_any    = mean(simulated_scrs >= observed_scr)
    )
  }, .progress = "Permutation test")

  country_stats <- country_stats |>
    left_join(perm_results, by = "citing_country")
} else {
  cat("  WARNING: No countries meet the", MIN_CITATIONS_THRESHOLD,
      "citation threshold. Skipping permutation test.\n")
  country_stats <- country_stats |>
    mutate(z_score_any = NA_real_, p_value_any = NA_real_)
}

cat("Permutation test complete.\n\n")

# Print: lead with excess endogeneity and ratio (base-rate adjusted)
cat("Top 20 countries by EXCESS endogeneity (min", MIN_CITATIONS_THRESHOLD, "citations):\n")
print(
  country_stats |>
    filter(meets_threshold) |>
    arrange(desc(excess_endogeneity_any)) |>
    head(20) |>
    select(citing_country, n_citations, scr_any, expected_scr,
           excess_endogeneity_any, endogeneity_ratio_any, z_score_any, p_value_any) |>
    mutate(across(where(is.numeric), ~ round(.x, 3)))
)

write_csv(country_stats, paste0("data/05_country_endogeneity", OUTPUT_SUFFIX, ".csv"))

# --- 6. Temporal analysis ------------------------------------------------------

cat("\n--- Temporal analysis ---\n")

# Endogeneity by year (overall), focused window
temporal_overall <- citations |>
  group_by(citing_year) |>
  summarise(
    n_citations     = n(),
    scr_any         = mean(endogenous_any),
    scr_majority    = mean(endogenous_majority),
    .groups = "drop"
  ) |>
  filter(citing_year >= TEMPORAL_START_YEAR, citing_year <= TEMPORAL_END_YEAR)

cat("Endogeneity over time (", TEMPORAL_START_YEAR, "-", TEMPORAL_END_YEAR, "):\n")
print(temporal_overall |> mutate(across(starts_with("scr"), ~ round(.x, 3))))

write_csv(temporal_overall, paste0("data/06_temporal_overall", OUTPUT_SUFFIX, ".csv"))

# Endogeneity by year and country.
# We build the per-country temporal table for the FULL set of countries clearing
# the citation threshold (all of them), then write that to 07 so the figure (fig3)
# can draw every analysable country and an equal-weight mean over the full set.
# The downstream convergence slopes (10) and the mixed-effects model are kept on
# the original TOP_N_COUNTRIES subset for continuity with published results, via
# the separate `temporal_by_country_topn` table below.
threshold_countries <- country_stats |>
  filter(meets_threshold) |>
  pull(citing_country)

top_countries <- country_stats |>
  filter(meets_threshold) |>
  slice_head(n = TOP_N_COUNTRIES) |>
  pull(citing_country)

cat("\nCountries >= threshold for temporal table (full):",
    length(threshold_countries), "\n")
cat("Top", TOP_N_COUNTRIES, "countries for slopes/model:",
    paste(top_countries, collapse = ", "), "\n")

# FULL >= threshold table -> written to 07 (drives fig3)
temporal_by_country_full <- citation_by_citing_country |>
  filter(citing_country %in% threshold_countries) |>
  group_by(citing_country, citing_year) |>
  summarise(
    n_citations  = n(),
    scr_any      = mean(endogenous_any),
    scr_majority = mean(endogenous_majority),
    .groups = "drop"
  ) |>
  filter(citing_year >= TEMPORAL_START_YEAR, citing_year <= TEMPORAL_END_YEAR) |>
  left_join(
    country_stats |> select(citing_country, expected_scr),
    by = "citing_country"
  ) |>
  mutate(excess_scr_any = scr_any - expected_scr)

write_csv(temporal_by_country_full,
          paste0("data/07_temporal_by_country", OUTPUT_SUFFIX, ".csv"))

# TOP-N subset -> feeds the convergence slopes (10) and the mixed model below,
# unchanged from the original analysis.
temporal_by_country <- temporal_by_country_full |>
  filter(citing_country %in% top_countries)

# --- 6b. Convergence / divergence testing ------------------------------------

cat("\n--- Convergence / divergence testing ---\n")

# Per-country OLS: excess endogeneity ~ year
temporal_slopes <- temporal_by_country |>
  filter(!is.na(excess_scr_any)) |>
  group_by(citing_country) |>
  filter(n() >= 5) |>  # Need enough data points for regression
  summarise(
    n_years   = n(),
    slope     = tryCatch(coef(lm(excess_scr_any ~ citing_year))[2], error = function(e) NA_real_),
    r_squared = tryCatch(summary(lm(excess_scr_any ~ citing_year))$r.squared, error = function(e) NA_real_),
    p_value   = tryCatch(summary(lm(excess_scr_any ~ citing_year))$coefficients[2, 4], error = function(e) NA_real_),
    .groups = "drop"
  ) |>
  arrange(slope)

cat("\nPer-country endogeneity trends (slope = annual change in excess SCR):\n")
print(
  temporal_slopes |>
    mutate(
      direction = case_when(
        p_value < 0.05 & slope < 0 ~ "CONVERGING",
        p_value < 0.05 & slope > 0 ~ "DIVERGING",
        TRUE ~ "no sig. trend"
      )
    ) |>
    mutate(across(where(is.numeric), ~ round(.x, 4)))
)

write_csv(temporal_slopes, paste0("data/10_temporal_slopes", OUTPUT_SUFFIX, ".csv"))

# Mixed-effects model (if lme4 is available)
if (requireNamespace("lme4", quietly = TRUE)) {
  cat("\nFitting mixed-effects model: excess_scr ~ year + (year | country)\n")
  library(lme4)

  model_data <- temporal_by_country |>
    filter(!is.na(excess_scr_any)) |>
    mutate(
      year_scaled = (citing_year - 2016) / 10,  # Scale to ~[-0.9, 0.9]
      log_weight  = log1p(n_citations)           # Dampen extreme weight variance
    )

  cat("  Model data:", nrow(model_data), "obs,",
      n_distinct(model_data$citing_country), "countries\n")
  cat("  year_scaled range:", round(range(model_data$year_scaled), 2), "\n")
  cat("  log_weight range:", round(range(model_data$log_weight), 2), "\n")

  ctrl <- lmerControl(optimizer = "bobyqa", optCtrl = list(maxfun = 50000))
  convergence_model <- NULL

  # Attempt 1: Full random slopes with bobyqa
  convergence_model <- tryCatch({
    m <- lmer(excess_scr_any ~ year_scaled + (year_scaled | citing_country),
              data = model_data, weights = log_weight, control = ctrl)
    if (length(m@optinfo$conv$lme4$messages) > 0) {
      cat("  Full model had convergence warnings, trying uncorrelated RE...\n")
      stop("convergence warnings")
    }
    cat("  Full random slopes model converged.\n")
    m
  }, error = function(e) NULL)

  # Attempt 2: Uncorrelated random effects (no intercept-slope correlation)
  if (is.null(convergence_model)) {
    convergence_model <- tryCatch({
      m <- lmer(excess_scr_any ~ year_scaled + (year_scaled || citing_country),
                data = model_data, weights = log_weight, control = ctrl)
      if (length(m@optinfo$conv$lme4$messages) > 0) {
        cat("  Uncorrelated RE model had warnings, trying intercepts only...\n")
        stop("convergence warnings")
      }
      cat("  Uncorrelated random effects model converged.\n")
      m
    }, error = function(e) NULL)
  }

  # Attempt 3: Random intercepts only
  if (is.null(convergence_model)) {
    convergence_model <- tryCatch({
      m <- lmer(excess_scr_any ~ year_scaled + (1 | citing_country),
                data = model_data, weights = log_weight, control = ctrl)
      cat("  Random intercepts only model converged.\n")
      m
    }, error = function(e) {
      cat("  All mixed models failed:", conditionMessage(e), "\n")
      NULL
    })
  }

  if (!is.null(convergence_model)) {
    cat("\nMixed-effects model summary:\n")
    print(summary(convergence_model))

    # Convergence diagnostics
    cat("\nConvergence diagnostics:\n")
    cat("  Optimizer:", convergence_model@optinfo$optimizer, "\n")
    cat("  Function evaluations:", convergence_model@optinfo$feval, "\n")
    msgs <- convergence_model@optinfo$conv$lme4$messages
    if (length(msgs) > 0) {
      cat("  Warnings:", paste(msgs, collapse = "\n    "), "\n")
    } else {
      cat("  No convergence warnings.\n")
    }

    # Note: coefficients are on scaled year; multiply by 10 for per-year effect
    fe <- fixef(convergence_model)
    cat("\n  Fixed effects (year_scaled = (year-2016)/10):\n")
    cat("    Intercept:", round(fe[1], 4), "\n")
    if ("year_scaled" %in% names(fe)) {
      cat("    year_scaled:", round(fe[2], 4),
          "(per-year effect:", round(fe[2] / 10, 5), ")\n")
    }

    saveRDS(convergence_model, paste0("data/11_convergence_model", OUTPUT_SUFFIX, ".rds"))
  }
} else {
  cat("Note: lme4 not installed, skipping mixed-effects model.\n")
}

# --- 7. Bridge scholars --------------------------------------------------------

cat("\n--- Identifying bridge scholars ---\n")

# Diagnostic: inspect authorships structure
cat("Authorship structure diagnostic:\n")
first_a <- dh_corpus$authorships[[1]]
cat("  Class:", paste(class(first_a), collapse = ", "), "\n")
cat("  Column names:", paste(names(first_a), collapse = ", "), "\n")

# Helper: extract author IDs from an authorships element
# Handles the openalexR tibble format: columns are id, display_name, affiliations, etc.
extract_author_ids <- function(a_list) {
  if (is.data.frame(a_list)) {
    # openalexR tibble format: author ID is in the "id" column directly
    if ("id" %in% names(a_list)) {
      return(a_list$id)
    }
    # Fallback: flattened au_id column
    if ("au_id" %in% names(a_list)) {
      return(a_list$au_id)
    }
    # Fallback: nested author sub-data-frame
    if ("author" %in% names(a_list) && is.data.frame(a_list$author)) {
      return(a_list$author$id %||% character(0))
    }
    return(character(0))
  } else if (is.list(a_list)) {
    map_chr(a_list, ~ .x$author$id %||% .x$id %||% NA_character_)
  } else {
    character(0)
  }
}

# Helper: extract author data (id, name, countries) from an authorships element
extract_author_data <- function(a_list) {
  if (is.data.frame(a_list)) {
    # openalexR tibble format
    ids <- if ("id" %in% names(a_list)) {
      a_list$id
    } else if ("au_id" %in% names(a_list)) {
      a_list$au_id
    } else if ("author" %in% names(a_list) && is.data.frame(a_list$author)) {
      a_list$author$id
    } else {
      rep(NA_character_, nrow(a_list))
    }

    display_names <- if ("display_name" %in% names(a_list)) {
      a_list$display_name
    } else if ("au_display_name" %in% names(a_list)) {
      a_list$au_display_name
    } else if ("author" %in% names(a_list) && is.data.frame(a_list$author)) {
      a_list$author$display_name
    } else {
      rep(NA_character_, nrow(a_list))
    }

    country_strs <- vapply(seq_len(nrow(a_list)), function(i) {
      a_countries <- character()
      # Check affiliations column (openalexR format: list of data frames with country_code)
      if ("affiliations" %in% names(a_list)) {
        aff <- a_list$affiliations[[i]]
        if (is.data.frame(aff) && "country_code" %in% names(aff)) {
          a_countries <- c(a_countries, aff$country_code)
        } else if (is.list(aff)) {
          for (item in aff) {
            if (!is.null(item$country_code)) a_countries <- c(a_countries, item$country_code)
          }
        }
      }
      # Check countries column (some formats)
      if ("countries" %in% names(a_list)) {
        a_countries <- c(a_countries, unlist(a_list$countries[[i]]))
      }
      # Check institutions column (some formats)
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
      a_countries <- unique(toupper(a_countries[!is.na(a_countries)]))
      paste(sort(a_countries), collapse = ";")
    }, character(1))

    tibble(author_id = ids, author_name = display_names, author_countries = country_strs)
  } else if (is.list(a_list)) {
    map_dfr(a_list, function(a) {
      a_countries <- character()
      if (!is.null(a$countries)) a_countries <- unlist(a$countries)
      if (!is.null(a$institutions)) {
        for (inst in a$institutions) {
          if (!is.null(inst$country_code)) a_countries <- c(a_countries, inst$country_code)
        }
      }
      if (!is.null(a$affiliations)) {
        for (aff in a$affiliations) {
          if (is.data.frame(aff) && "country_code" %in% names(aff)) {
            a_countries <- c(a_countries, aff$country_code)
          } else if (!is.null(aff$country_code)) {
            a_countries <- c(a_countries, aff$country_code)
          }
        }
      }
      tibble(
        author_id = a$author$id %||% a$id %||% NA_character_,
        author_name = a$author$display_name %||% a$display_name %||% NA_character_,
        author_countries = paste(sort(unique(toupper(a_countries))), collapse = ";")
      )
    })
  } else {
    tibble(author_id = character(), author_name = character(), author_countries = character())
  }
}

# Extract author-level citation data
author_citations <- dh_corpus |>
  filter(has_country) |>
  select(citing_id = id, citing_year = publication_year,
         authorships, referenced_works, citing_countries = countries_str) |>
  mutate(
    author_ids = map(authorships, extract_author_ids)
  ) |>
  select(citing_id, citing_year, author_ids, referenced_works, citing_countries) |>
  unnest(author_ids) |>
  mutate(author_ids = as.character(author_ids)) |>
  filter(!is.na(author_ids), author_ids != "") |>
  unnest(referenced_works) |>
  rename(cited_id = referenced_works) |>
  left_join(
    cited_works |> select(cited_id = id, cited_countries = countries_str),
    by = "cited_id"
  ) |>
  filter(!is.na(cited_countries))

# Diagnostics
cat("  Author-citation records:", nrow(author_citations), "\n")
cat("  Unique authors:", n_distinct(author_citations$author_ids), "\n")

# Compute author-level citation diversity
author_diversity <- author_citations |>
  mutate(cited_countries_list = str_split(cited_countries, ";")) |>
  unnest(cited_countries_list) |>
  rename(cited_country = cited_countries_list) |>
  mutate(cited_country = as.character(cited_country)) |>
  filter(!is.na(cited_country), cited_country != "") |>
  group_by(author_id = author_ids) |>
  summarise(
    n_citations_total = n(),
    n_works           = n_distinct(citing_id),
    n_countries_cited  = n_distinct(cited_country),
    .groups = "drop"
  )

cat("  Authors with >= 1 work:", sum(author_diversity$n_works >= 1), "\n")
cat("  Authors with >= 3 works:", sum(author_diversity$n_works >= 3), "\n")
cat("  Authors with >= 5 works:", sum(author_diversity$n_works >= 5), "\n")
cat("  Meeting thresholds (", BRIDGE_MIN_WORKS, "+ works,",
    BRIDGE_MIN_CITATIONS, "+ citations):",
    nrow(author_diversity |> filter(n_works >= BRIDGE_MIN_WORKS,
                                     n_citations_total >= BRIDGE_MIN_CITATIONS)), "\n")

# Compute entropy per author
author_entropy <- author_citations |>
  mutate(cited_countries_list = str_split(cited_countries, ";")) |>
  unnest(cited_countries_list) |>
  rename(cited_country = cited_countries_list) |>
  mutate(cited_country = as.character(cited_country)) |>
  filter(!is.na(cited_country), cited_country != "") |>
  count(author_id = author_ids, cited_country) |>
  group_by(author_id) |>
  mutate(p = n / sum(n)) |>
  reframe(
    shannon_entropy   = -sum(p * log(p)),
    hhi               = sum(p^2),
    top_country       = if (length(n) > 0) cited_country[which.max(n)] else NA_character_,
    top_country_share = if (length(p) > 0) max(p) else NA_real_
  )

# Author's own country
author_own_country <- dh_corpus |>
  filter(has_country) |>
  select(authorships, countries_str) |>
  mutate(
    author_data = map(authorships, function(a) {
      result <- extract_author_data(a)
      # Ensure consistent column types even for empty results
      if (nrow(result) == 0) {
        return(tibble(author_id = character(), author_name = character(),
                      author_countries = character()))
      }
      result
    })
  ) |>
  select(author_data) |>
  unnest(author_data)

# Filter after unnest — check column exists
if ("author_id" %in% names(author_own_country) && nrow(author_own_country) > 0) {
  author_own_country <- author_own_country |>
    filter(!is.na(author_id), author_id != "", author_countries != "") |>
    distinct(author_id, .keep_all = TRUE)
} else {
  cat("  WARNING: No author data extracted. Creating empty author_own_country.\n")
  author_own_country <- tibble(author_id = character(), author_name = character(),
                                author_countries = character())
}

cat("  Authors with country data:", nrow(author_own_country), "\n")

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
  filter(n_works >= BRIDGE_MIN_WORKS,
         n_citations_total >= BRIDGE_MIN_CITATIONS) |>
  mutate(
    # Normalized entropy: H / ln(k), 0 = all citations to one country, 1 = perfectly uniform
    max_entropy = log(n_countries_cited),
    entropy_norm = ifelse(max_entropy > 0, shannon_entropy / max_entropy, 0)
  ) |>
  arrange(desc(shannon_entropy))

cat("\nBridge scholar candidates (min", BRIDGE_MIN_WORKS, "works,",
    BRIDGE_MIN_CITATIONS, "citations):", nrow(bridge_scholars), "\n")

cat("\nTop 20 bridge scholars by citation entropy:\n")
print(
  bridge_scholars |>
    head(20) |>
    select(author_name, author_countries, n_works, n_countries_cited,
           shannon_entropy, self_cite_rate, top_country, top_country_share) |>
    mutate(across(where(is.numeric), ~ round(.x, 3)))
)

write_csv(bridge_scholars, paste0("data/08_bridge_scholars", OUTPUT_SUFFIX, ".csv"))

# --- 7b. Bridge scholars: temporal trends --------------------------------------

cat("\n--- Bridge scholars: temporal trends ---\n")

# For each year, count how many unique authors active that year
# qualify as bridge scholars (based on their full-career metrics)
bridge_ids <- bridge_scholars$author_id

bridge_temporal <- author_citations |>
  filter(citing_year >= TEMPORAL_START_YEAR, citing_year <= TEMPORAL_END_YEAR) |>
  group_by(citing_year) |>
  summarise(
    n_total_authors   = n_distinct(author_ids),
    n_bridge_scholars = n_distinct(author_ids[author_ids %in% bridge_ids]),
    .groups = "drop"
  ) |>
  mutate(
    pct_bridge = n_bridge_scholars / n_total_authors
  )

cat("  Bridge scholar temporal data:", nrow(bridge_temporal), "years\n")
cat("  Year range:", min(bridge_temporal$citing_year), "-",
    max(bridge_temporal$citing_year), "\n")
print(bridge_temporal |> mutate(pct_bridge = round(pct_bridge, 4)))

write_csv(bridge_temporal, paste0("data/12_bridge_temporal", OUTPUT_SUFFIX, ".csv"))

# --- 8. Country-pair citation matrix -------------------------------------------

cat("\n--- Building country-pair citation matrix ---\n")

flow_matrix <- citation_country_pairs |>
  pivot_wider(
    names_from  = cited_country,
    values_from = n_cites,
    values_fill = 0
  )

write_csv(flow_matrix, paste0("data/09_citation_flow_matrix", OUTPUT_SUFFIX, ".csv"))

cat("Citation flow matrix:", nrow(flow_matrix), "×",
    ncol(flow_matrix) - 1, "countries\n")

# --- 9. Summary report --------------------------------------------------------

cat("\n")
cat("================================================================\n")
cat("   DH CITATION ENDOGENEITY - ANALYSIS COMPLETE\n")
if (CORPUS_FILTER != "all") cat("   Corpus filter:", CORPUS_FILTER, "\n")
cat("================================================================\n")
cat("\nCorpus: ", nrow(dh_corpus), "DH works\n")
cat("Citations analysed:", nrow(citations), "\n")
cat("Countries represented:", n_distinct(citation_by_citing_country$citing_country), "\n")
cat("Countries meeting", MIN_CITATIONS_THRESHOLD, "citation threshold:",
    sum(country_stats$meets_threshold, na.rm = TRUE), "\n")
cat("\nOverall endogeneity:\n")
cat("  Any overlap:  ", round(100 * mean(citations$endogenous_any), 1), "%\n")
cat("  Majority rule:", round(100 * mean(citations$endogenous_majority), 1), "%\n")
cat("\nBridge scholars identified:", nrow(bridge_scholars), "\n")
cat("\nConvergence testing:", sum(temporal_slopes$p_value < 0.05 & temporal_slopes$slope < 0, na.rm = TRUE),
    "countries converging,", sum(temporal_slopes$p_value < 0.05 & temporal_slopes$slope > 0, na.rm = TRUE),
    "diverging (p < 0.05)\n")
cat("\nOutput files in data/ (suffix:", ifelse(OUTPUT_SUFFIX == "", "none", OUTPUT_SUFFIX), "):\n")
cat("  05_country_endogeneity  - Country-level metrics + null model + permutation\n")
cat("  06_temporal_overall     - Endogeneity over time\n")
cat("  07_temporal_by_country  - Endogeneity by country × year\n")
cat("  08_bridge_scholars      - Bridge scholar rankings\n")
cat("  09_citation_flow_matrix - Country × country citation flows\n")
cat("  10_temporal_slopes      - Per-country endogeneity trends\n")
if (exists("convergence_model") && !is.null(convergence_model))
  cat("  11_convergence_model    - Mixed-effects model (RDS)\n")
cat("  12_bridge_temporal      - Bridge scholars per year\n")
