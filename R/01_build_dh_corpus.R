###############################################################################
# DH Citation Endogeneity Study
# Phase 1: Build the DH corpus from OpenAlex
#
# Two-pronged approach:
#   1a. Works published in "Exclusively" DH journals (Spinaci et al. 2022 list)
#   1b. Works mentioning "digital humanities" in title/abstract (any venue)
#   1c. Deduplicate and flag sources
#
# Includes articles, books, and book chapters. From year 2000 onward.
###############################################################################

library(openalexR)
library(tidyverse)
library(jsonlite)

# --- Configuration -----------------------------------------------------------

# Timestamp this run for reproducibility
# OpenAlex data changes daily; recording the date lets others know
# which snapshot of the data was used.
run_timestamp <- Sys.time()
cat("=== Run started:", format(run_timestamp, "%Y-%m-%d %H:%M:%S %Z"), "===\n")
cat("R version:", R.version.string, "\n")
cat("openalexR version:", as.character(packageVersion("openalexR")), "\n")
cat("tidyverse version:", as.character(packageVersion("tidyverse")), "\n\n")

# API key and email are read from .Renviron
# (copy .Renviron.example to .Renviron and fill in your credentials)
# Note that .Renviron in the project root is only read automatically if you launch R from that directory 
# (e.g., by opening an .Rproj file or cd-ing there first). If you run R from elsewhere, 
# it reads ~/.Renviron instead.
api_key <- Sys.getenv("OPENALEX_API_KEY")
email   <- Sys.getenv("OPENALEX_EMAIL")

if (api_key == "" || api_key == "your_key_here") {
  stop("OPENALEX_API_KEY not set. Copy .Renviron.example to .Renviron and add your key.")
}

options(openalexR.apikey = api_key)
if (email != "" && email != "your.email@example.com") {
  options(openalexR.mailto = email)
}

# Output directory
dir.create("data", showWarnings = FALSE)

# --- 1. Define the DH journal list (Exclusively only) ------------------------

# From Spinaci et al. (2022), filtered to DH Level == "Exclusively"
# We use both E-ISSN and P-ISSN to maximize matching

dh_journals <- tribble(
  ~id, ~title, ~e_issn, ~p_issn,
  1,  "Umanistica Digitale",                              "2532-8816", NA,
  2,  "Frontiers in Digital Humanities",                   "2297-2668", NA,
  3,  "Digital Scholarship in the Humanities (DSH)",       "2055-768X", "2055-7671",
  4,  "Digital Humanities Quarterly (DHQ)",                "1938-4122", NA,
  5,  "Digital Studies / Le champ numérique",              "1918-3666", NA,
  6,  "Journal of Digital Humanities",                     "2165-6673", NA,
  7,  "Journal of Cultural Analytics",                     "2371-4549", NA,
  8,  "Journal of Digital Archives and Digital Humanities", "2616-5732", NA,
  9,  "Digitális Bölcsészet / Digital Humanities",         "2630-9696", NA,
  10, "Revista de humanidades digitales",                  "2531-1786", NA,
  11, "Journal of the Japanese Association for DH",        "2188-7276", NA,
  12, "Journal of Data Mining and Digital Humanities",     "2416-5999", NA,
  13, "International Journal of Digital Humanities",       "2524-7840", "2524-7832",
  14, "Journal on Computing and Cultural Heritage (JOCCH)","1556-4711", "1556-4673",
  15, "Literary and Linguistics Computing",                "1477-4615", "0268-1145",
  16, "Journal of the Text Encoding Initiative",           "2162-5603", NA,
  17, "Computers and the Humanities",                      "1572-8412", "0010-4817",
  18, "Int. J. of Humanities and Arts Computing",          "1755-1706", "1753-8548",
  19, "Digital Medievalist",                               "1715-0736", NA
)

cat("DH journals to search:", nrow(dh_journals), "\n")

# --- 2. Find OpenAlex Source IDs for each journal ----------------------------

# Collect all ISSNs (both electronic and print) into one lookup vector
all_issns <- dh_journals |>
  pivot_longer(cols = c(e_issn, p_issn), values_to = "issn") |>
  filter(!is.na(issn)) |>
  pull(issn)

cat("Looking up", length(all_issns), "ISSNs in OpenAlex...\n")

# Look up sources by ISSN
source_lookup <- map_dfr(all_issns, function(issn) {
  tryCatch({
    result <- oa_fetch(
      entity = "sources",
      issn = issn,
      verbose = FALSE
    )
    if (nrow(result) > 0) {
      tibble(
        issn_queried = issn,
        source_id    = result$id[1],
        source_name  = result$display_name[1],
        issn_l       = result$issn_l[1]
      )
    } else {
      tibble(issn_queried = issn, source_id = NA_character_,
             source_name = NA_character_, issn_l = NA_character_)
    }
  }, error = function(e) {
    message("  Error looking up ISSN ", issn, ": ", e$message)
    tibble(issn_queried = issn, source_id = NA_character_,
           source_name = NA_character_, issn_l = NA_character_)
  })
}, .progress = TRUE)

# Deduplicate: some journals have both E-ISSN and P-ISSN pointing to the same source
source_ids <- source_lookup |>
  filter(!is.na(source_id)) |>
  distinct(source_id, .keep_all = TRUE)

cat("\nFound", nrow(source_ids), "unique OpenAlex sources for",
    nrow(dh_journals), "journals\n")

# Report any journals not found
found_issns <- source_lookup |> filter(!is.na(source_id)) |> pull(issn_queried)
missing_issns <- setdiff(all_issns, found_issns)
if (length(missing_issns) > 0) {
  cat("WARNING: ISSNs not found in OpenAlex:", paste(missing_issns, collapse = ", "), "\n")
  missing_journals <- dh_journals |>
    filter(e_issn %in% missing_issns | p_issn %in% missing_issns)
  cat("  Journals possibly missing:\n")
  print(missing_journals |> select(id, title))
}

write_csv(source_ids, "data/01_source_ids.csv")

# --- 3a. Retrieve works from DH journals ------------------------------------

cat("\n--- Phase 1a: Retrieving works from DH journals ---\n")

works_journal <- map_dfr(source_ids$source_id, function(sid) {
  cat("  Fetching from:", source_ids$source_name[source_ids$source_id == sid], "\n")

  tryCatch({
    oa_fetch(
      entity = "works",
      primary_location.source.id = gsub("https://openalex.org/", "", sid),
      from_publication_date = "2000-01-01",
      type = c("article", "book", "book-chapter"),
      is_paratext = FALSE,
      options = list(
        select = c("id", "doi", "title", "display_name", "publication_year",
                    "type", "authorships", "referenced_works",
                    "cited_by_count", "primary_location")
      ),
      output = "tibble",
      paging = "cursor",
      abstract = FALSE,
      verbose = FALSE
    )
  }, error = function(e) {
    message("    Error fetching source ", sid, ": ", e$message)
    tibble()
  })
}, .progress = TRUE)

cat("Journal-based works retrieved:", nrow(works_journal), "\n")

works_journal <- works_journal |>
  mutate(source_journal = TRUE, source_keyword = FALSE, dh_level = "Exclusively")

# --- 3b. Retrieve works mentioning "digital humanities" ----------------------

cat("\n--- Phase 1b: Retrieving keyword-search works ---\n")

works_keyword <- oa_fetch(
  entity = "works",
  title_and_abstract.search = '"digital humanities"',
  from_publication_date = "2000-01-01",
  type = c("article", "book", "book-chapter"),
  is_paratext = FALSE,
  options = list(
    select = c("id", "doi", "title", "display_name", "publication_year",
                "type", "authorships", "referenced_works",
                "cited_by_count", "primary_location")
  ),
  output = "tibble",
  paging = "cursor",
  abstract = FALSE,
  verbose = TRUE
)

cat("Keyword-based works retrieved:", nrow(works_keyword), "\n")

works_keyword <- works_keyword |>
  mutate(source_journal = FALSE, source_keyword = TRUE, dh_level = "keyword_only")

# --- 4. Deduplicate and merge ------------------------------------------------

cat("\n--- Phase 1c: Deduplication ---\n")

overlap_ids <- intersect(works_journal$id, works_keyword$id)
cat("Works found in BOTH journal and keyword sets:", length(overlap_ids), "\n")

works_journal <- works_journal |>
  mutate(source_keyword = ifelse(id %in% overlap_ids, TRUE, source_keyword))

works_keyword_only <- works_keyword |>
  filter(!id %in% works_journal$id)

dh_corpus <- bind_rows(works_journal, works_keyword_only)

cat("\n=== DH Corpus Summary ===\n")
cat("Total unique works:", nrow(dh_corpus), "\n")
cat("  From DH journals:", sum(dh_corpus$source_journal), "\n")
cat("  From keyword search only:", sum(!dh_corpus$source_journal), "\n")
cat("  In both:", sum(dh_corpus$source_journal & dh_corpus$source_keyword), "\n")
cat("  Year range:", min(dh_corpus$publication_year, na.rm = TRUE), "-",
    max(dh_corpus$publication_year, na.rm = TRUE), "\n")

# --- 5. Extract country information from authorships -------------------------

cat("\n--- Extracting country information ---\n")

extract_countries <- function(authorships) {
  if (is.null(authorships) || length(authorships) == 0) return(NA_character_)

  countries <- tryCatch({
    all_countries <- character()

    # openalexR may return authorships as:
    #   (a) a list of lists (raw JSON style), or
    #   (b) a data frame / tibble with nested columns
    # We handle both.

    if (is.data.frame(authorships)) {
      # Format (b): tibble with columns like author, institutions, countries
      if ("countries" %in% names(authorships)) {
        all_countries <- unlist(authorships$countries)
      }
      if ("institutions" %in% names(authorships)) {
        for (inst_list in authorships$institutions) {
          if (is.data.frame(inst_list) && "country_code" %in% names(inst_list)) {
            all_countries <- c(all_countries, inst_list$country_code)
          } else if (is.list(inst_list)) {
            for (inst in inst_list) {
              if (!is.null(inst$country_code)) {
                all_countries <- c(all_countries, inst$country_code)
              }
            }
          }
        }
      }
    } else {
      # Format (a): list of lists
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
    }

    unique_countries <- unique(toupper(all_countries))
    unique_countries <- unique_countries[nchar(unique_countries) == 2]  # Sanity check: ISO alpha-2 only
    if (length(unique_countries) == 0) return(NA_character_)
    paste(sort(unique_countries), collapse = ";")
  }, error = function(e) NA_character_)

  return(countries)
}

# Diagnostic: inspect authorships structure
cat("Authorships column class:", class(dh_corpus$authorships), "\n")
if (nrow(dh_corpus) > 0) {
  cat("First element structure:\n")
  str(dh_corpus$authorships[[1]], max.level = 2)
}

# Extract country sets for each work
dh_corpus <- dh_corpus |>
  rowwise() |>
  mutate(
    countries_str = extract_countries(authorships)
  ) |>
  ungroup() |>
  mutate(
    countries_list = str_split(countries_str, ";"),
    n_countries    = map_int(countries_list, ~ sum(!is.na(.x))),
    is_multicountry = n_countries > 1,
    has_country    = !is.na(countries_str)
  )

cat("\n=== Country Coverage ===\n")
cat("Works with country data:", sum(dh_corpus$has_country),
    "(", round(100 * mean(dh_corpus$has_country), 1), "%)\n")
cat("Multi-country works:", sum(dh_corpus$is_multicountry, na.rm = TRUE),
    "(", round(100 * mean(dh_corpus$is_multicountry, na.rm = TRUE), 1), "%)\n")

# --- 6. Extract referenced works IDs ----------------------------------------

cat("\n--- Extracting referenced works ---\n")

dh_corpus <- dh_corpus |>
  mutate(
    n_references = map_int(referenced_works, ~ if (is.null(.x)) 0L else length(.x))
  )

cat("Total references to look up:", sum(dh_corpus$n_references), "\n")

all_ref_ids <- dh_corpus |>
  pull(referenced_works) |>
  unlist() |>
  unique()

cat("Unique referenced works:", length(all_ref_ids), "\n")

# --- 7. Save intermediate results --------------------------------------------

corpus_flat <- dh_corpus |>
  select(id, doi, title, publication_year, type, cited_by_count,
         source_journal, source_keyword, dh_level,
         countries_str, n_countries, is_multicountry, has_country,
         n_references)

write_csv(corpus_flat, "data/02_dh_corpus.csv")
writeLines(all_ref_ids, "data/03_referenced_work_ids.txt")
saveRDS(dh_corpus, "data/02_dh_corpus_full.rds")

cat("\n=== Phase 1 Complete ===\n")
cat("Files saved:\n")
cat("  data/01_source_ids.csv          - OpenAlex Source IDs for DH journals\n")
cat("  data/02_dh_corpus.csv           - DH corpus (flat)\n")
cat("  data/02_dh_corpus_full.rds      - DH corpus (full, with list columns)\n")
cat("  data/03_referenced_work_ids.txt - Unique IDs of all cited works\n")
cat("\nNext: Run 02_fetch_cited_works.R\n")

# --- 8. Quick descriptive overview -------------------------------------------

cat("\n=== Quick Descriptive Stats ===\n")

works_by_year <- dh_corpus |>
  count(publication_year) |>
  arrange(publication_year)
cat("\nWorks per year:\n")
print(works_by_year, n = 30)

if (any(dh_corpus$has_country)) {
  top_countries <- dh_corpus |>
    filter(has_country) |>
    pull(countries_list) |>
    unlist() |>
    table() |>
    sort(decreasing = TRUE) |>
    head(20)
  cat("\nTop 20 countries (full counting):\n")
  print(top_countries)
}

cat("\nWorks by type:\n")
print(table(dh_corpus$type))

cat("\nWorks by source method:\n")
cat("  Journal-only:", sum(dh_corpus$source_journal & !dh_corpus$source_keyword), "\n")
cat("  Keyword-only:", sum(!dh_corpus$source_journal & dh_corpus$source_keyword), "\n")
cat("  Both:", sum(dh_corpus$source_journal & dh_corpus$source_keyword), "\n")

# --- 9. Log session info for reproducibility ----------------------------------

cat("\n--- Session info ---\n")
session_log <- capture.output(sessionInfo())
writeLines(session_log, "data/00_session_info_phase1.txt")
writeLines(format(run_timestamp, "%Y-%m-%dT%H:%M:%S%z"),
           "data/00_retrieval_date.txt")
cat("Session info saved to data/00_session_info_phase1.txt\n")
cat("Retrieval date saved to data/00_retrieval_date.txt\n")
