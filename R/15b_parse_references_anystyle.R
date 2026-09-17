# =============================================================================
# 15b_parse_references_anystyle.R
# -----------------------------------------------------------------------------
# Parse the raw txt reference BLOCKS (from script 15) into STRUCTURED references
# using AnyStyle, a purpose-built reference parser. This fixes the line-wrapping
# problem: AnyStyle reassembles references that span multiple lines, which the
# naive line-split in script 15 (`txt_line`) cannot do.
#
# WHY A SEPARATE SCRIPT + CACHED CSV:
#   AnyStyle is a Ruby tool — an external, non-CRAN dependency. To keep the rest
#   of the pipeline reproducible WITHOUT requiring every re-runner to install
#   Ruby, we run AnyStyle ONCE here and write its structured output to
#   `data/output/15b_parsed_references.csv`, which is committed to the repo.
#   Script 16 then reads that CSV. Re-runners who already have the CSV can skip
#   this script entirely.
#
# PREREQUISITE — install AnyStyle (once, on your machine):
#   brew install ruby            # if you need a recent Ruby
#   gem install anystyle-cli
#   anystyle --version           # verify it is on PATH
#
# CAVEAT (multilingual): AnyStyle's default model is English-trained. Non-English
#   references (FR/ES/DE/JA in this corpus) parse less reliably. We keep the
#   original block text so low-quality parses can be audited.
#
# INPUT  : data/output/15_conf_txt_blocks.csv     (from script 15)
# OUTPUT : data/output/15b_parsed_references.csv  (cached structured refs)
#          data/output/15b_parse_report.txt
#
# Run:  Rscript R/15b_parse_references_anystyle.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
})

out_dir <- file.path("data", "output")

# --- Language signals on the parsed title -----------------------------------
# AnyStyle does NOT emit a language field, so we derive two signals ourselves
# to support the project's multilingual / Global-South audit:
#
#   ref_script    : Unicode SCRIPT of the title (CJK / Cyrillic / Arabic /
#                   Greek / Latin / Other). Dependency-free and reliable; it
#                   cleanly separates non-European references, but CANNOT tell
#                   apart languages that share the Latin script (EN/ES/FR/DE...).
#   ref_lang_cld3 : full language guess via the cld3 package (EN/es/fr/de...),
#                   computed only if cld3 is installed. This DISAMBIGUATES the
#                   Latin-script languages. It is noisy on short titles, so treat
#                   it as a hint, not ground truth.
detect_script <- function(x) {
  if (is.na(x)) return(NA_character_)
  if (grepl("[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]", x, perl = TRUE))
    return("CJK")
  if (grepl("\\p{Cyrillic}", x, perl = TRUE)) return("Cyrillic")
  if (grepl("\\p{Arabic}",   x, perl = TRUE)) return("Arabic")
  if (grepl("\\p{Greek}",    x, perl = TRUE)) return("Greek")
  if (grepl("\\p{Latin}",    x, perl = TRUE)) return("Latin")
  "Other"
}

HAVE_CLD3 <- requireNamespace("cld3", quietly = TRUE)
if (!HAVE_CLD3) {
  message("Note: cld3 not installed — ref_lang_cld3 will be NA. ",
          "Install with install.packages('cld3') for Latin-script language IDs.")
}
detect_lang_cld3 <- function(titles) {
  if (!HAVE_CLD3) return(rep(NA_character_, length(titles)))
  out <- cld3::detect_language(titles)
  out[is.na(titles)] <- NA_character_
  out
}

# --- 0. Locate the AnyStyle binary -------------------------------------------
# R's system2() runs in a NON-interactive shell that does NOT source ~/.zshrc or
# ~/.bash_profile, so a gem installed under Homebrew Ruby may work in your
# terminal yet be invisible here. We therefore resolve the binary explicitly:
#   1. ANYSTYLE_BIN env var (set this if auto-detection fails — most reliable)
#   2. `which anystyle` via the login shell
#   3. a list of common Homebrew / RubyGems install locations
find_anystyle <- function() {
  # 1. explicit override
  env_bin <- Sys.getenv("ANYSTYLE_BIN", unset = "")
  if (nzchar(env_bin) && file.exists(env_bin)) return(env_bin)

  # 2. ask a login shell (sources your profile, so PATH matches your terminal)
  shell <- Sys.getenv("SHELL", unset = "/bin/sh")
  hit <- tryCatch(
    system2(shell, c("-lc", shQuote("command -v anystyle")),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0))
  hit <- hit[nzchar(hit)]
  if (length(hit) && file.exists(hit[1])) return(hit[1])

  # 3. probe common locations (Homebrew ARM + Intel, user gems, rbenv)
  cands <- c(
    Sys.glob("/opt/homebrew/lib/ruby/gems/*/bin/anystyle"),
    Sys.glob("/opt/homebrew/opt/ruby/bin/anystyle"),
    Sys.glob("/usr/local/lib/ruby/gems/*/bin/anystyle"),
    Sys.glob("/usr/local/opt/ruby/bin/anystyle"),
    Sys.glob("~/.gem/ruby/*/bin/anystyle"),
    Sys.glob("~/.rbenv/shims/anystyle"),
    "/opt/homebrew/bin/anystyle", "/usr/local/bin/anystyle")
  cands <- cands[file.exists(cands)]
  if (length(cands)) return(cands[1])

  "anystyle"  # last resort: hope it's on PATH
}

ANYSTYLE <- find_anystyle()
anystyle_ok <- tryCatch(
  system2(ANYSTYLE, "--version", stdout = TRUE, stderr = TRUE),
  error = function(e) NULL)
if (is.null(anystyle_ok) || length(anystyle_ok) == 0) {
  stop(paste0(
    "AnyStyle CLI not found.\n",
    "  It is installed (you confirmed `anystyle --version` works in your shell),\n",
    "  but R's non-interactive shell can't see it on PATH.\n",
    "  FIX: find the path with `which anystyle` in your terminal, then set it,\n",
    "  e.g. in .Renviron:  ANYSTYLE_BIN=/full/path/to/anystyle\n",
    "  (tried: ", ANYSTYLE, ")"))
}
cat("AnyStyle:", ANYSTYLE, "->", paste(anystyle_ok, collapse = " "), "\n")

# --- 1. Load txt reference blocks --------------------------------------------
blocks <- readr::read_csv(file.path(out_dir, "15_conf_txt_blocks.csv"),
                          show_col_types = FALSE) %>%
  filter(!is.na(ref_block), str_squish(ref_block) != "")
cat("txt reference blocks to parse:", nrow(blocks), "\n")

# --- Pre-segment a block into ONE REFERENCE PER LINE --------------------------
# AnyStyle's `parse` expects one reference per line; given a whole block it can
# mis-segment (splitting line-wrapped references into title fragments). The
# conference blocks are mostly already one-reference-per-line (sometimes
# numbered), so we segment them ourselves first: strip leading numbering, and
# only MERGE a line into the previous reference when it is clearly a wrapped
# continuation (starts lowercase or with a connective like "and"/"in"/"pp").
# This sharply reduces fragment titles (lowercase-start refs dropped ~2565 -> ~30
# in testing). It is not perfect — a continuation line that starts with a capital
# (e.g. "University of Chicago Press") can still be split — so a downstream
# quality gate drops residual <4-word fragments before matching.
presegment_block <- function(block) {
  lines <- str_squish(str_split(block, "\n")[[1]])
  lines <- lines[lines != ""]
  if (!length(lines)) return(character(0))
  lines <- str_replace(lines, "^\\s*[\\[(]?\\d{1,3}[\\]).]\\s+", "")  # strip numbering
  is_continuation <- function(l) grepl("^[a-z&]|^(and|in|pp|vol|no|eds?)\\b", l)
  refs <- character(0); cur <- ""
  for (l in lines) {
    if (cur == "") cur <- l
    else if (is_continuation(l)) cur <- paste(cur, l)
    else { refs <- c(refs, cur); cur <- l }
  }
  if (cur != "") refs <- c(refs, cur)
  refs
}

# --- 2. Parse one block with AnyStyle (returns a tibble of references) --------
# Pre-segment to one-reference-per-line, then write to a temp file and call
# `anystyle -f json parse FILE`. AnyStyle returns a JSON array, one object per line.
parse_block <- function(work_id, block_text) {
  refs_in <- presegment_block(block_text)
  if (!length(refs_in)) return(tibble())
  tf <- tempfile(fileext = ".txt")
  writeLines(refs_in, tf, useBytes = TRUE)        # one reference per line
  on.exit(unlink(tf), add = TRUE)

  raw <- tryCatch(
    system2(ANYSTYLE, c("-f", "json", "parse", shQuote(tf)),
            stdout = TRUE, stderr = FALSE),
    error = function(e) NULL)
  if (is.null(raw) || length(raw) == 0) return(tibble())

  parsed <- tryCatch(jsonlite::fromJSON(paste(raw, collapse = "\n"),
                                        simplifyVector = FALSE),
                     error = function(e) NULL)
  if (is.null(parsed) || length(parsed) == 0) return(tibble())

  # Flatten the fields we need. AnyStyle fields are arrays; collapse to strings.
  flat <- function(x) if (is.null(x)) NA_character_ else
    paste(unlist(x), collapse = " ")
  collapse_authors <- function(a) {
    if (is.null(a)) return(NA_character_)
    fam <- map_chr(a, ~ .x$family %||% .x$last %||% NA_character_)
    fam <- fam[!is.na(fam)]
    if (!length(fam)) NA_character_ else paste(fam, collapse = "; ")
  }

  map_dfr(seq_along(parsed), function(i) {
    r <- parsed[[i]]
    tibble(
      work_id      = work_id,
      ref_index    = i,
      ref_title    = flat(r$title),
      ref_authors  = collapse_authors(r$author),
      ref_year     = flat(r$date),
      ref_doi      = str_to_lower(flat(r$doi)),
      ref_type     = flat(r$type)
      # language is derived later (detect_script / cld3) — AnyStyle omits it.
    )
  })
}

# --- 3. Run over all blocks --------------------------------------------------
cat("Parsing with AnyStyle (this may take a while)...\n")
parsed_all <- map_dfr(seq_len(nrow(blocks)), function(i) {
  res <- parse_block(blocks$work_id[i], blocks$ref_block[i])
  if (i %% 200 == 0) cat(sprintf("  ...%d / %d works\n", i, nrow(blocks)))
  res
})

# Clean up + stable ids; mark quality so script 16 can prioritise.
parsed_all <- parsed_all %>%
  mutate(
    ref_doi   = ifelse(ref_doi == "" | ref_doi == "NA", NA_character_, ref_doi),
    ref_title = ifelse(ref_title == "" | ref_title == "NA", NA_character_, ref_title),
    ref_quality = "anystyle"
  ) %>%
  filter(!is.na(ref_title) | !is.na(ref_doi)) %>%   # need at least a title or DOI
  group_by(work_id) %>%
  mutate(ref_index = row_number()) %>%
  ungroup() %>%
  mutate(ref_id = paste0(work_id, "_a", ref_index)) %>%
  # Derive language signals from the parsed title.
  mutate(
    ref_script    = vapply(ref_title, detect_script, character(1)),
    ref_lang_cld3 = detect_lang_cld3(ref_title)
  ) %>%
  select(ref_id, work_id, ref_index, ref_title, ref_authors, ref_year,
         ref_doi, ref_type, ref_script, ref_lang_cld3, ref_quality)

readr::write_csv(parsed_all, file.path(out_dir, "15b_parsed_references.csv"))

# --- 4. Report ---------------------------------------------------------------
report <- c(
  "=== 15b_parse_references_anystyle.R report ===",
  sprintf("Generated: %s", Sys.time()),
  sprintf("AnyStyle: %s", paste(anystyle_ok, collapse = " ")),
  sprintf("txt blocks parsed:               %d", nrow(blocks)),
  sprintf("Structured references produced:  %d", nrow(parsed_all)),
  sprintf("  with a title:                  %d (%.1f%%)",
          sum(!is.na(parsed_all$ref_title)),
          100 * mean(!is.na(parsed_all$ref_title))),
  sprintf("  with a DOI:                    %d (%.1f%%)",
          sum(!is.na(parsed_all$ref_doi)),
          100 * mean(!is.na(parsed_all$ref_doi))),
  "",
  "Script breakdown (Unicode script of the title — reliable, dependency-free):",
  paste0("  ", capture.output(print(
    parsed_all %>% count(ref_script, sort = TRUE)))),
  "",
  sprintf("cld3 language detection: %s",
          if (HAVE_CLD3) "ENABLED" else "DISABLED (cld3 not installed)"),
  if (HAVE_CLD3)
    paste0("  ", capture.output(print(
      parsed_all %>% count(ref_lang_cld3, sort = TRUE) %>% head(12))))
  else
    "  (install cld3 to separate Latin-script languages: EN/es/fr/de/it...)",
  "",
  "NOTE: non-English refs parse less reliably (AnyStyle is English-trained).",
  "      ref_script catches non-Latin scripts; ref_lang_cld3 (if present)",
  "      separates Latin-script languages but is noisy on short titles.",
  "      This CSV is the cached input for script 16 — commit it for reproducibility."
)
writeLines(report, file.path(out_dir, "15b_parse_report.txt"))
cat(paste(report, collapse = "\n"), "\n")
