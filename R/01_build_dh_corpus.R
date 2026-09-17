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

# --- 1. Define the DH journal list -------------------------------------------

# From Spinaci et al. (2022): "Exclusively" DH (19 journals) and
# "Significantly" DH (17 journals).
# Plus 5 additional "Exclusively" DH journals added post-Spinaci (2022).
# We use both E-ISSN and P-ISSN to maximize matching.

dh_journals <- tribble(
  ~id, ~title, ~e_issn, ~p_issn, ~dh_level,
  # --- Exclusively DH (19 journals from Spinaci + 11 added) ---
  1,  "Umanistica Digitale",                              "2532-8816", NA,          "Exclusively",
  2,  "Frontiers in Digital Humanities",                   "2297-2668", NA,          "Exclusively",
  3,  "Digital Scholarship in the Humanities (DSH)",       "2055-768X", "2055-7671", "Exclusively",
  4,  "Digital Humanities Quarterly (DHQ)",                "1938-4122", NA,          "Exclusively",
  5,  "Digital Studies / Le champ numérique",              "1918-3666", NA,          "Exclusively",
  6,  "Journal of Digital Humanities",                     "2165-6673", NA,          "Exclusively",
  7,  "Journal of Cultural Analytics",                     "2371-4549", NA,          "Exclusively",
  8,  "Journal of Digital Archives and Digital Humanities", "2616-5732", NA,         "Exclusively",
  9,  "Digitális Bölcsészet / Digital Humanities",         "2630-9696", NA,          "Exclusively",
  10, "Revista de humanidades digitales",                  "2531-1786", NA,          "Exclusively",
  11, "Journal of the Japanese Association for DH",        "2188-7276", NA,          "Exclusively",
  12, "Journal of Data Mining and Digital Humanities",     "2416-5999", NA,          "Exclusively",
  13, "International Journal of Digital Humanities",       "2524-7840", "2524-7832", "Exclusively",
  14, "Journal on Computing and Cultural Heritage (JOCCH)","1556-4711", "1556-4673", "Exclusively",
  15, "Literary and Linguistics Computing",                "1477-4615", "0268-1145", "Exclusively",
  16, "Journal of the Text Encoding Initiative",           "2162-5603", NA,          "Exclusively",
  17, "Computers and the Humanities",                      "1572-8412", "0010-4817", "Exclusively",
  18, "Int. J. of Humanities and Arts Computing",          "1755-1706", "1753-8548", "Exclusively",
  19, "Digital Medievalist",                               "1715-0736", NA,          "Exclusively",
  # --- Exclusively DH (additional, post-Spinaci 2022) ---
  20, "Korean Journal of Digital Humanities",               "3058-311X", NA,          "Exclusively",
  21, "Journal of Computational Literary Studies",          "2940-1348", NA,          "Exclusively",
  22, "Computational Humanities Research",                  "2977-8158", NA,          "Exclusively",
  23, "Humanités numériques",                               "2736-2337", NA,          "Exclusively",
  24, "Zeitschrift für digitale Geisteswissenschaften",     "2510-1358", NA,          "Exclusively",
  25, "J. of the DH Association of Southern Africa",       "3006-6492", NA,          "Exclusively",
  26, "Journal of Digital Art & Humanities",               "2712-8148", NA,          "Exclusively",
  27, "DH in the Nordic and Baltic Countries Publications","2704-1441", NA,          "Exclusively",
  28, "Digital humanities",                                "2628-4995", "2703-0415", "Exclusively",
  29, "Infotheca - Journal for Digital Humanities",        "2217-9461", "1450-9687", "Exclusively",
  30, "magazén",                                           "2724-3923", NA,          "Exclusively",
  # --- Significantly DH (17 journals, Spinaci et al. 2022) ---
  31, "Digital Library Perspectives",                      "2059-5824", "2059-5816", "Significantly",
  32, "Journal of Library Metadata",                       "1937-5034", "1938-6389", "Significantly",
  33, "Journal of Quantitative Linguistics",               "1744-5035", "0929-6174", "Significantly",
  34, "Language Resources and Evaluation",                 "1574-0218", "1574-020X", "Significantly",
  35, "Virtual Archaeology Review",                        "1989-9947", NA,          "Significantly",
  36, "D-Lib Magazine",                                    "1082-9873", NA,          "Significantly",
  37, "Computational Linguistics",                         "1530-9312", "0891-2017", "Significantly",
  38, "AI & SOCIETY",                                      "1435-5655", "0951-5666", "Significantly",
  39, "Int. J. on Digital Libraries",                      "1432-1300", "1432-5012", "Significantly",
  40, "ENTHYMEMA",                                         "2037-2426", NA,          "Significantly",
  41, "Italiano LinguaDue",                                "2037-3597", NA,          "Significantly",
  42, "Lingue e culture dei media",                        "2532-1803", NA,          "Significantly",
  43, "JLIS",                                              "2038-1026", "2038-5366", "Significantly",
  44, "Doctor virtualis",                                  "2035-7362", NA,          "Significantly",
  45, "Int. J. of Digital Curation",                       "1746-8256", NA,          "Significantly",
  46, "J. of Interactive Technology and Pedagogy",         "2166-6245", NA,          "Significantly",
  47, "Code4Lib Journal",                                  "1940-5758", NA,          "Significantly"
)

cat("DH journals to search:", nrow(dh_journals), "\n")
cat("  Exclusively:", sum(dh_journals$dh_level == "Exclusively"), "\n")
cat("  Significantly:", sum(dh_journals$dh_level == "Significantly"), "\n")

# --- 2. Find OpenAlex Source IDs for each journal ----------------------------

# Collect all ISSNs (both electronic and print) with their dh_level
issn_level_map <- dh_journals |>
  pivot_longer(cols = c(e_issn, p_issn), values_to = "issn") |>
  filter(!is.na(issn)) |>
  select(issn, dh_level) |>
  # Trim any whitespace from ISSNs (some entries in CSV have trailing spaces)
  mutate(issn = str_trim(issn))

all_issns <- issn_level_map$issn

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

# Add dh_level from the ISSN mapping
source_lookup <- source_lookup |>
  left_join(issn_level_map, by = c("issn_queried" = "issn"))

# Deduplicate: some journals have both E-ISSN and P-ISSN pointing to the same source
# Keep the dh_level (prioritise "Exclusively" if both match)
source_ids <- source_lookup |>
  filter(!is.na(source_id)) |>
  arrange(source_id, dh_level) |>  # "Exclusively" sorts before "Significantly"
  distinct(source_id, .keep_all = TRUE)

cat("\nFound", nrow(source_ids), "unique OpenAlex sources for",
    nrow(dh_journals), "journals\n")

# Report any journals not found
found_issns <- source_lookup |> filter(!is.na(source_id)) |> pull(issn_queried)
missing_issns <- setdiff(all_issns, found_issns)
if (length(missing_issns) > 0) {
  cat("WARNING: ISSNs not found in OpenAlex:", paste(missing_issns, collapse = ", "), "\n")
  missing_journals <- dh_journals |>
    filter(e_issn %in% missing_issns | p_issn %in% missing_issns) |>
    # Only report journals where NONE of their ISSNs were found
    filter(!(e_issn %in% found_issns | p_issn %in% found_issns))
  if (nrow(missing_journals) > 0) {
    cat("  Journals not found in OpenAlex:\n")
    print(missing_journals |> select(id, title, e_issn, p_issn))

    # Write log file
    log_lines <- c(
      paste("Journals not found in OpenAlex — generated", Sys.time()),
      "",
      sprintf("%-3s  %-55s  %-10s  %-10s", "ID", "Title", "E-ISSN", "P-ISSN"),
      paste(rep("-", 85), collapse = ""),
      purrr::pmap_chr(missing_journals |> select(id, title, e_issn, p_issn), function(id, title, e_issn, p_issn) {
        sprintf("%-3d  %-55s  %-10s  %-10s", id, title,
                ifelse(is.na(e_issn), "—", e_issn),
                ifelse(is.na(p_issn), "—", p_issn))
      })
    )
    dir.create("data/output", showWarnings = FALSE, recursive = TRUE)
    writeLines(log_lines, "data/output/01_journals_not_found_in_openalex.txt")
    cat("  Log saved to: data/output/01_journals_not_found_in_openalex.txt\n")
  }
} else {
  cat("All journal ISSNs found in OpenAlex.\n")
}

write_csv(source_ids, "data/01_source_ids.csv")

# --- 3a. Retrieve works from DH journals ------------------------------------

cat("\n--- Phase 1a: Retrieving works from DH journals ---\n")

# Fetch works per source, carrying the dh_level
works_journal <- map_dfr(seq_len(nrow(source_ids)), function(i) {
  sid   <- source_ids$source_id[i]
  sname <- source_ids$source_name[i]
  level <- source_ids$dh_level[i]
  cat("  Fetching from:", sname, "(", level, ")\n")

  result <- tryCatch({
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

  if (nrow(result) > 0) {
    result$dh_level <- level
  }
  result
}, .progress = TRUE)

cat("Journal-based works retrieved:", nrow(works_journal), "\n")
cat("  Exclusively:", sum(works_journal$dh_level == "Exclusively", na.rm = TRUE), "\n")
cat("  Significantly:", sum(works_journal$dh_level == "Significantly", na.rm = TRUE), "\n")

works_journal <- works_journal |>
  mutate(source_journal = TRUE, source_keyword = FALSE)

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

# Journal works that also appear in keyword search: mark source_keyword = TRUE
# but keep the journal's dh_level (Exclusively or Significantly)
works_journal <- works_journal |>
  mutate(source_keyword = ifelse(id %in% overlap_ids, TRUE, source_keyword))

# Keyword works not in any journal
works_keyword_only <- works_keyword |>
  filter(!id %in% works_journal$id)

dh_corpus <- bind_rows(works_journal, works_keyword_only)

cat("\n=== DH Corpus Summary ===\n")
cat("Total unique works:", nrow(dh_corpus), "\n")
cat("  From DH journals:", sum(dh_corpus$source_journal), "\n")
cat("    Exclusively:", sum(dh_corpus$dh_level == "Exclusively"), "\n")
cat("    Significantly:", sum(dh_corpus$dh_level == "Significantly"), "\n")
cat("  From keyword search only:", sum(dh_corpus$dh_level == "keyword_only"), "\n")
cat("  In both journal + keyword:", sum(dh_corpus$source_journal & dh_corpus$source_keyword), "\n")
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
      # Format (b): tibble with columns like id, display_name, affiliations, ...
      # openalexR format: "affiliations" is a list column of data frames
      # with columns: id, display_name, ror, country_code, type, lineage
      if ("affiliations" %in% names(authorships)) {
        for (aff_df in authorships$affiliations) {
          if (is.data.frame(aff_df) && "country_code" %in% names(aff_df)) {
            all_countries <- c(all_countries, aff_df$country_code)
          } else if (is.list(aff_df)) {
            for (item in aff_df) {
              if (!is.null(item$country_code)) {
                all_countries <- c(all_countries, item$country_code)
              }
            }
          }
        }
      }
      # Fallback: some formats use "countries" column
      if ("countries" %in% names(authorships)) {
        all_countries <- c(all_countries, unlist(authorships$countries))
      }
      # Fallback: some formats use "institutions" column
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
        if (!is.null(a$affiliations)) {
          for (aff in a$affiliations) {
            if (is.data.frame(aff) && "country_code" %in% names(aff)) {
              all_countries <- c(all_countries, aff$country_code)
            } else if (!is.null(aff$country_code)) {
              all_countries <- c(all_countries, aff$country_code)
            }
          }
        }
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

cat("\nWorks by DH level:\n")
print(table(dh_corpus$dh_level))

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
