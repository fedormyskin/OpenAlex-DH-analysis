# =============================================================================
# 15_extract_conference_references.R
# -----------------------------------------------------------------------------
# Recover the reference list of each conference abstract from works.full_text,
# so that conference citation endogeneity can be computed (scripts 16-18) and
# reported SIDE BY SIDE with the journal corpus.
#
# WHY THIS IS NEEDED:
#   The relational conference extract has NO work-to-work citation links. The
#   references only exist embedded in the abstract full text. full_text comes in
#   two very different formats, handled separately here:
#
#   * XML / TEI  -> references are in tags. Three tiers, best first:
#        (a) <biblStruct>  fully structured (author/title/date/idno)
#        (b) <bibl>        semi-structured
#        (c) any DOI       string anywhere in the text (highest precision)
#   * TXT        -> references are free text under a heading
#        ("References", "Bibliography", multilingual variants). We locate the
#        block and split it into individual reference strings.
#
# OUTPUT: one row per (conference work x extracted reference), with a
#   `ref_quality` flag so downstream scripts (and you) know how trustworthy each
#   reference is. Nothing here touches the network.
#
#   IMPORTANT: txt reference lists are heavily LINE-WRAPPED in the source PDFs,
#   so the naive line-split (`txt_line`) is noisy (~half the rows are fragments
#   or continuations). We therefore ALSO emit the raw reference BLOCK per txt
#   work (`15_conf_txt_blocks.csv`); script 15b feeds those blocks to the
#   AnyStyle reference parser, which handles wrapping properly. The `txt_line`
#   rows are kept only as a fallback.
#
# INPUT  : data/dh_conferences_data/works.csv
# OUTPUT : data/output/15_conf_references.csv     (xml refs + txt_line fallback)
#          data/output/15_conf_txt_blocks.csv     (raw txt blocks for AnyStyle)
#          data/output/15_extract_report.txt
#
# Run:  Rscript R/15_extract_conference_references.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(xml2)
})

conf_dir <- file.path("data", "dh_conferences_data")
out_dir  <- file.path("data", "output")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

works <- readr::read_csv(file.path(conf_dir, "works.csv"),
                         show_col_types = FALSE)

# Keep only works that actually have full text.
ft <- works %>%
  filter(!is.na(full_text), str_squish(full_text) != "") %>%
  select(work_id = id, full_text, full_text_type)

# A DOI regex used in several places (case-insensitive, trims trailing junk).
DOI_RE <- "10\\.\\d{4,9}/[^\\s\"'<>]+"

clean_doi <- function(x) {
  x <- str_extract(x, DOI_RE)
  x <- str_replace(x, "[\\.,;:)\\]]+$", "")  # strip trailing punctuation
  str_to_lower(x)
}

# -----------------------------------------------------------------------------
# XML / TEI extraction
# -----------------------------------------------------------------------------
extract_xml_refs <- function(work_id, text) {
  out <- list()

  # Some works are typed "xml" but contain plain text (no leading '<'). Passing
  # those to read_xml() makes xml2 treat the string as a FILE PATH and emit a
  # "path too long" warning. Only parse when the content actually looks like XML.
  looks_xml <- grepl("^\\s*<", text)

  # ~22% of XML works have malformed markup (e.g. a <hi> tag left unclosed before
  # </author>). read_xml() is STRICT and aborts the whole document on these, even
  # with RECOVER options (xml2 does not honour them here). read_html() IS lenient
  # and recovers the tree — the <bibl>/<biblStruct> CONTENT itself is fine, only
  # the surrounding markup is broken. So: try strict read_xml first (preserves
  # original case), and fall back to read_html() for malformed works. This
  # recovers ~7,500 references that would otherwise be lost to DOI-only.
  #
  # NOTE: read_html() lowercases tag names, so "biblStruct" becomes "biblstruct".
  # All xpaths below therefore match case-insensitively (bibl OR biblstruct).
  doc <- NULL
  if (looks_xml) {
    doc <- tryCatch(read_xml(text), error = function(e) NULL)
    if (is.null(doc)) {
      doc <- tryCatch(read_html(text), error = function(e) NULL)
    }
  }

  if (is.null(doc)) {
    # Truly unparseable (or plain text): fall back to DOI scraping on the raw string.
    dois <- unique(na.omit(clean_doi(unlist(str_extract_all(text, DOI_RE)))))
    if (length(dois)) {
      out[["doi"]] <- tibble(work_id = work_id, ref_text = NA_character_,
                             ref_doi = dois, ref_quality = "xml_doi_only")
    }
    return(bind_rows(out))
  }

  find_all <- function(xpath) {
    tryCatch(xml_find_all(doc, xpath), error = function(e) xml_nodeset())
  }

  # (a) <biblStruct> — structured (case-insensitive: biblStruct OR biblstruct)
  bs <- find_all("//*[local-name()='biblStruct' or local-name()='biblstruct']")
  if (length(bs)) {
    bs_tbl <- map_dfr(bs, function(node) {
      sur <- xml_text(xml_find_all(node, ".//*[local-name()='surname']"))
      tit <- xml_text(xml_find_all(node, ".//*[local-name()='title']"))
      yr  <- xml_text(xml_find_all(node, ".//*[local-name()='date']"))
      idno <- xml_text(xml_find_all(node, ".//*[local-name()='idno']"))
      raw  <- str_squish(xml_text(node))
      doi  <- clean_doi(paste(c(idno, raw), collapse = " "))
      tibble(
        work_id  = work_id,
        ref_text = str_squish(paste(c(paste(sur, collapse = ", "),
                                       paste(tit, collapse = ". "),
                                       paste(yr, collapse = " ")),
                                     collapse = " ")),
        ref_doi  = doi,
        ref_quality = "xml_biblstruct"
      )
    })
    out[["biblstruct"]] <- bs_tbl
  }

  # (b) <bibl> — semi-structured (only those NOT already inside biblStruct)
  bl <- find_all("//*[local-name()='bibl']")
  if (length(bl)) {
    bl_tbl <- map_dfr(bl, function(node) {
      raw <- str_squish(xml_text(node))
      if (raw == "") return(NULL)
      tibble(work_id = work_id, ref_text = raw,
             ref_doi = clean_doi(raw), ref_quality = "xml_bibl")
    })
    out[["bibl"]] <- bl_tbl
  }

  # (c) bare DOIs anywhere (catches references not in bibl/biblStruct tags)
  dois <- unique(na.omit(clean_doi(unlist(str_extract_all(text, DOI_RE)))))
  if (length(dois)) {
    already <- unique(na.omit(unlist(lapply(out, function(d) d$ref_doi))))
    new_dois <- setdiff(dois, already)
    if (length(new_dois)) {
      out[["doi"]] <- tibble(work_id = work_id, ref_text = NA_character_,
                             ref_doi = new_dois, ref_quality = "xml_doi_only")
    }
  }

  bind_rows(out)
}

# -----------------------------------------------------------------------------
# TXT extraction
# -----------------------------------------------------------------------------
# Heading labels that mark the start of a reference list (multilingual).
HEAD_RE <- paste0(
  "(?im)^[\\s>]*(",
  paste(c("references", "reference list", "bibliography",
          "selected bibliography", "works cited", "works consulted",
          "literature", "sources", "notes and references",
          "bibliographie", "bibliografia", "bibliografía",
          "referencias", "literatur"), collapse = "|"),
  ")\\s*:?\\s*$"
)

# Returns the raw reference BLOCK (everything after the last heading) for a txt
# work, or NA if no heading is found. This block is the clean input for AnyStyle.
extract_txt_block <- function(text) {
  m <- str_locate_all(text, HEAD_RE)[[1]]
  if (nrow(m) == 0) return(NA_character_)
  start <- m[nrow(m), "end"]
  blk <- substr(text, start + 1, nchar(text))
  blk <- str_trim(blk)
  if (blk == "") NA_character_ else blk
}

# Fallback line-split (noisy; used only if AnyStyle is unavailable).
extract_txt_refs <- function(work_id, text) {
  block <- extract_txt_block(text)
  if (is.na(block)) return(tibble())

  lines <- str_split(block, "\n")[[1]] %>% str_squish()
  lines <- lines[lines != ""]
  lines <- lines[nchar(lines) >= 8]
  if (!length(lines)) return(tibble())

  tibble(
    work_id     = work_id,
    ref_text    = lines,
    ref_doi     = clean_doi(lines),
    ref_quality = "txt_line"
  )
}

# -----------------------------------------------------------------------------
# Run extraction
# -----------------------------------------------------------------------------
cat("Extracting references from", nrow(ft), "full-text works...\n")

txt_blocks <- list()   # collect raw txt reference blocks for AnyStyle (script 15b)

# Collect per-work results in a list and bind once at the end (much faster than
# map_dfr, which re-binds the growing frame on every iteration).
refs_list <- vector("list", nrow(ft))
for (i in seq_len(nrow(ft))) {
  row <- ft[i, ]
  if (identical(row$full_text_type, "xml")) {
    refs_list[[i]] <- extract_xml_refs(row$work_id, row$full_text)
  } else {
    blk <- extract_txt_block(row$full_text)
    if (!is.na(blk)) txt_blocks[[as.character(row$work_id)]] <- blk
    refs_list[[i]] <- extract_txt_refs(row$work_id, row$full_text)
  }
  if (i %% 500 == 0) cat(sprintf("  ...%d / %d\n", i, nrow(ft)))
}
refs <- bind_rows(refs_list)

# Write the raw txt blocks (one row per work) — clean input for AnyStyle.
txt_block_tbl <- tibble(
  work_id   = as.integer(names(txt_blocks)),
  ref_block = unlist(txt_blocks, use.names = FALSE)
)
readr::write_csv(txt_block_tbl, file.path(out_dir, "15_conf_txt_blocks.csv"))

# Add a stable per-reference id and de-duplicate exact repeats within a work.
refs <- refs %>%
  filter(!(is.na(ref_text) & is.na(ref_doi))) %>%
  distinct(work_id, ref_text, ref_doi, ref_quality) %>%
  group_by(work_id) %>%
  mutate(ref_index = row_number()) %>%
  ungroup() %>%
  mutate(ref_id = paste0(work_id, "_r", ref_index)) %>%
  select(ref_id, work_id, ref_index, ref_text, ref_doi, ref_quality)

readr::write_csv(refs, file.path(out_dir, "15_conf_references.csv"))

# -----------------------------------------------------------------------------
# Coverage tables (for the article's methods / limitations section)
# -----------------------------------------------------------------------------
# We distinguish THREE states per work, because "no references" is ambiguous:
#   (1) no full text at all          -> cannot extract references (data gap)
#   (2) full text but no references  -> short formats, or undetected ref list
#   (3) >=1 reference extracted
# All percentages are reported against an explicit denominator so the numbers
# can be quoted unambiguously in the paper.
work_types  <- readr::read_csv(file.path(conf_dir, "work_types.csv"),
                               show_col_types = FALSE)
conferences <- readr::read_csv(file.path(conf_dir, "conferences.csv"),
                               show_col_types = FALSE)

works_cov <- works %>%
  mutate(has_full_text = !is.na(full_text) & str_squish(full_text) != "") %>%
  mutate(has_references = id %in% refs$work_id) %>%
  left_join(work_types %>% select(id, work_type_label = title),
            by = c("work_type" = "id")) %>%
  left_join(conferences %>% select(id, year), by = c("conference" = "id"))

# --- coverage by work type ---
coverage_by_type <- works_cov %>%
  group_by(work_type_label) %>%
  summarise(
    n_works          = n(),
    n_no_full_text   = sum(!has_full_text),
    n_ft_no_refs     = sum(has_full_text & !has_references),
    n_with_refs      = sum(has_references),
    .groups = "drop"
  ) %>%
  mutate(
    pct_no_full_text = round(100 * n_no_full_text / n_works, 1),
    pct_with_refs    = round(100 * n_with_refs / n_works, 1)
  ) %>%
  arrange(desc(n_works))
readr::write_csv(coverage_by_type,
                 file.path(out_dir, "15_coverage_by_type.csv"))

# --- coverage by conference year ---
# median_full_text_chars is computed over FULL-TEXT works only (NA for years
# with none). It flags whether a year holds full papers vs. bare abstracts:
# a low value (e.g. ~2,000 in 2020) means abstract-only deposits, which is why
# references are absent — not an extraction failure.
coverage_by_year <- works_cov %>%
  mutate(ft_chars = if_else(has_full_text, nchar(full_text), NA_integer_)) %>%
  group_by(year) %>%
  summarise(
    n_works               = n(),
    n_no_full_text        = sum(!has_full_text),
    n_ft_no_refs          = sum(has_full_text & !has_references),
    n_with_refs           = sum(has_references),
    median_full_text_chars = as.integer(median(ft_chars, na.rm = TRUE)),
    .groups = "drop"
  ) %>%
  mutate(
    pct_no_full_text = round(100 * n_no_full_text / n_works, 1),
    pct_with_refs    = round(100 * n_with_refs / n_works, 1)
  ) %>%
  arrange(year)
readr::write_csv(coverage_by_year,
                 file.path(out_dir, "15_coverage_by_year.csv"))

# --- headline totals (explicit denominators) ---
n_total      <- nrow(works_cov)
n_no_ft      <- sum(!works_cov$has_full_text)
n_ft         <- sum(works_cov$has_full_text)
n_ft_no_refs <- sum(works_cov$has_full_text & !works_cov$has_references)
n_with_refs  <- sum(works_cov$has_references)
n_no_refs    <- n_total - n_with_refs

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
by_q <- refs %>% count(ref_quality, name = "n_refs")
report <- c(
  "=== 15_extract_conference_references.R report ===",
  sprintf("Generated: %s", Sys.time()),
  "",
  "--- Reference coverage (denominators stated explicitly) ---",
  sprintf("Total works:                     %d", n_total),
  sprintf("  No full text (data gap):       %d (%.1f%% of all works)",
          n_no_ft, 100 * n_no_ft / n_total),
  sprintf("  Full text present:             %d (%.1f%% of all works)",
          n_ft, 100 * n_ft / n_total),
  sprintf("    of which, no refs found:     %d (%.1f%% of full-text works)",
          n_ft_no_refs, 100 * n_ft_no_refs / n_ft),
  sprintf("Works WITH >=1 reference:        %d (%.1f%% of all; %.1f%% of full-text)",
          n_with_refs, 100 * n_with_refs / n_total, 100 * n_with_refs / n_ft),
  sprintf("Works with NO references (any reason): %d (%.1f%% of all works)",
          n_no_refs, 100 * n_no_refs / n_total),
  "  (see 15_coverage_by_type.csv and 15_coverage_by_year.csv for breakdowns)",
  "",
  "--- Reference extraction ---",
  sprintf("Full-text works processed:       %d", nrow(ft)),
  sprintf("txt works with a reference BLOCK: %d (-> AnyStyle, script 15b)",
          nrow(txt_block_tbl)),
  sprintf("Total references extracted:      %d", nrow(refs)),
  sprintf("  with a DOI:                    %d (%.1f%%)",
          sum(!is.na(refs$ref_doi)),
          100 * mean(!is.na(refs$ref_doi))),
  "",
  "By extraction quality:",
  paste0("  ", by_q$ref_quality, ": ", by_q$n_refs),
  "",
  "NOTE: txt_line references are raw strings (noisier); xml_biblstruct and",
  "      any *_doi references are the most reliable. Resolution happens in 16.",
  "NOTE: pre-1996 conferences have ~0% full text in the source Index — the",
  "      effective citation corpus is essentially post-1996 (see by-year CSV)."
)
writeLines(report, file.path(out_dir, "15_extract_report.txt"))
cat(paste(report, collapse = "\n"), "\n")
