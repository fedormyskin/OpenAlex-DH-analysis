###############################################################################
# DH Citation Endogeneity Study
# Phase 2: Retrieve country data for all cited works
#
# Reads the referenced_work_ids from Phase 1, batch-fetches them from OpenAlex
# (50 IDs per request), and extracts country information.
# Supports checkpointing: safe to interrupt and resume.
###############################################################################

library(openalexR)
library(tidyverse)
library(httr2)

# --- Configuration -----------------------------------------------------------

api_key <- Sys.getenv("OPENALEX_API_KEY")
email   <- Sys.getenv("OPENALEX_EMAIL")

if (api_key == "" || api_key == "your_key_here") {
  stop("OPENALEX_API_KEY not set. Copy .Renviron.example to .Renviron and add your key.")
}

options(openalexR.apikey = api_key)
if (email != "" && email != "your.email@example.com") {
  options(openalexR.mailto = email)
}

BATCH_SIZE  <- 50   # Max IDs per request (OpenAlex limit)
SLEEP_SECS  <- 0.1  # Pause between requests to respect rate limits
SAVE_EVERY  <- 100  # Save checkpoint every N batches

dir.create("data", showWarnings = FALSE)

# --- 1. Load referenced work IDs from Phase 1 --------------------------------

ref_ids <- readLines("data/03_referenced_work_ids.txt")
cat("Total unique referenced works to fetch:", length(ref_ids), "\n")

# Check for checkpoint from previous run
checkpoint_file <- "data/04_cited_works_checkpoint.rds"
if (file.exists(checkpoint_file)) {
  cat("Found checkpoint file, loading...\n")
  cited_works_done <- readRDS(checkpoint_file)
  done_ids <- cited_works_done$id
  ref_ids <- setdiff(ref_ids, done_ids)
  cat("  Already fetched:", length(done_ids), "\n")
  cat("  Remaining:", length(ref_ids), "\n")
} else {
  cited_works_done <- tibble()
}

if (length(ref_ids) == 0) {
  cat("All referenced works already fetched. Skipping.\n")
  cited_works <- cited_works_done
} else {

# --- 2. Batch fetch cited works -----------------------------------------------

shorten_id <- function(x) gsub("https://openalex.org/", "", x)

batches <- split(ref_ids, ceiling(seq_along(ref_ids) / BATCH_SIZE))
cat("Number of batches:", length(batches), "\n")

get_countries_from_authorships <- function(authorships) {
  if (is.null(authorships) || length(authorships) == 0) return(NA_character_)

  all_countries <- character()
  for (a in authorships) {
    if (!is.null(a$countries)) {
      all_countries <- c(all_countries, unlist(a$countries))
    }
    if (!is.null(a$institutions)) {
      for (inst in a$institutions) {
        if (!is.null(inst$country_code)) {
          all_countries <- c(all_countries, inst$country_code)
        }
      }
    }
  }

  unique_countries <- unique(toupper(all_countries))
  if (length(unique_countries) == 0) return(NA_character_)
  paste(sort(unique_countries), collapse = ";")
}

fetch_batch <- function(ids) {
  short_ids <- shorten_id(ids)

  tryCatch({
    # Use output = "list" to get raw JSON — avoids oa2df() column name
    # differences across openalexR versions (e.g., "authorships" vs
    # "authorship", nested lists vs pre-flattened tibbles).
    result <- oa_fetch(
      entity = "works",
      openalex = short_ids,
      options = list(
        select = c("id", "publication_year", "authorships", "type")
      ),
      output = "list",
      per_page = 200,
      paging = "page",
      abstract = FALSE,
      verbose = FALSE
    )

    if (is.null(result) || length(result) == 0) return(tibble())

    # Parse each raw work record into a one-row tibble
    map_dfr(result, function(w) {
      tibble(
        id               = w$id %||% NA_character_,
        publication_year  = w$publication_year %||% NA_integer_,
        type             = w$type %||% NA_character_,
        countries_str    = get_countries_from_authorships(w$authorships)
      )
    }) |>
      mutate(
        n_countries = ifelse(
          is.na(countries_str), 0L,
          str_count(countries_str, ";") + 1L
        )
      )
  }, error = function(e) {
    message("  Batch error: ", e$message)
    tibble()
  })
}

# Main fetching loop
cat("\n--- Starting batch retrieval ---\n")
cat("Estimated time:", round(length(batches) * (SLEEP_SECS + 0.5) / 60, 1), "minutes\n\n")

new_results <- list()
errors <- 0

for (i in seq_along(batches)) {
  if (i %% 50 == 0 || i == 1) {
    cat(sprintf("  Batch %d / %d (%.1f%%)\n", i, length(batches),
                100 * i / length(batches)))
  }

  result <- fetch_batch(batches[[i]])

  if (nrow(result) > 0) {
    new_results[[length(new_results) + 1]] <- result
  } else {
    errors <- errors + 1
  }

  # Checkpoint
  if (i %% SAVE_EVERY == 0) {
    cat("    Saving checkpoint at batch", i, "...\n")
    checkpoint <- bind_rows(cited_works_done, bind_rows(new_results))
    saveRDS(checkpoint, checkpoint_file)
  }

  Sys.sleep(SLEEP_SECS)
}

cited_works_new <- bind_rows(new_results)
cited_works <- bind_rows(cited_works_done, cited_works_new) |>
  distinct(id, .keep_all = TRUE)

} # end if (length(ref_ids) > 0)

# --- 3. Save results ----------------------------------------------------------

cat("\n=== Phase 2 Summary ===\n")
cat("Cited works fetched:", nrow(cited_works), "\n")
cat("  With country data:", sum(!is.na(cited_works$countries_str)), "\n")
cat("  Without country data:", sum(is.na(cited_works$countries_str)), "\n")

write_csv(cited_works, "data/04_cited_works.csv")
saveRDS(cited_works, "data/04_cited_works.rds")

if (file.exists(checkpoint_file)) file.remove(checkpoint_file)

cat("\nFiles saved:\n")
cat("  data/04_cited_works.csv - Country data for all cited works\n")
cat("  data/04_cited_works.rds - Same, as RDS\n")
cat("\nNext: Run 03_endogeneity_analysis.R\n")

# --- 4. Quick stats -----------------------------------------------------------

cat("\n=== Cited Works Stats ===\n")

coverage <- mean(!is.na(cited_works$countries_str))
cat("Country coverage:", round(100 * coverage, 1), "%\n")

if (any(!is.na(cited_works$countries_str))) {
  top_cited_countries <- cited_works |>
    filter(!is.na(countries_str)) |>
    pull(countries_str) |>
    str_split(";") |>
    unlist() |>
    table() |>
    sort(decreasing = TRUE) |>
    head(20)
  cat("\nTop 20 countries in cited works (full counting):\n")
  print(top_cited_countries)
}

cat("\nYear range of cited works:",
    min(cited_works$publication_year, na.rm = TRUE), "-",
    max(cited_works$publication_year, na.rm = TRUE), "\n")
