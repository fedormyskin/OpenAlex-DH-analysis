# =============================================================================
# 15c_add_language_columns.R
# -----------------------------------------------------------------------------
# One-off helper: add the two language columns (ref_script, ref_lang_cld3) to an
# EXISTING 15b_parsed_references.csv WITHOUT re-running AnyStyle (script 15b).
#
# Use this if you already have 15b output and just want the language signals.
# The logic here is IDENTICAL to script 15b, so the result matches a full rerun.
#   * ref_script    : Unicode script of the title (CJK/Cyrillic/Arabic/Greek/
#                     Latin/Other). Dependency-free; separates non-Latin scripts
#                     but lumps EN/ES/FR/DE/IT together as "Latin".
#   * ref_lang_cld3 : language guess via cld3 (separates Latin-script languages);
#                     noisy on short titles. Requires the cld3 package.
#
# INPUT/OUTPUT : data/output/15b_parsed_references.csv  (overwritten in place;
#                a .bak copy is made first)
#
# Run:  Rscript R/15c_add_language_columns.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

path <- file.path("data", "output", "15b_parsed_references.csv")
stopifnot(file.exists(path))

# --- language helpers (identical to script 15b) ------------------------------
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
  message("cld3 not installed — ref_lang_cld3 will be NA. ",
          "install.packages('cld3') to enable Latin-script language IDs.")
}
detect_lang_cld3 <- function(titles) {
  if (!HAVE_CLD3) return(rep(NA_character_, length(titles)))
  out <- cld3::detect_language(titles)
  out[is.na(titles)] <- NA_character_
  out
}

# --- read, back up, transform, write -----------------------------------------
refs <- readr::read_csv(path, show_col_types = FALSE,
                        col_types = cols(ref_title = col_character()))

# safety backup of the current file
file.copy(path, paste0(path, ".bak"), overwrite = TRUE)

# drop any stale language columns, then add fresh ones in a stable position
refs <- refs %>%
  select(-any_of(c("ref_language", "ref_script", "ref_lang_cld3"))) %>%
  mutate(
    ref_script    = vapply(ref_title, detect_script, character(1)),
    ref_lang_cld3 = detect_lang_cld3(ref_title)
  ) %>%
  relocate(ref_script, ref_lang_cld3, .before = dplyr::last_col())

readr::write_csv(refs, path)

# --- report ------------------------------------------------------------------
cat("Updated:", path, "(backup at", paste0(path, ".bak"), ")\n")
cat("References:", nrow(refs), "\n\n")
cat("Script distribution:\n")
print(refs %>% count(ref_script, sort = TRUE))
if (HAVE_CLD3) {
  cat("\ncld3 language distribution (top 12):\n")
  print(refs %>% count(ref_lang_cld3, sort = TRUE) %>% head(12))
} else {
  cat("\ncld3 disabled — ref_lang_cld3 is all NA.\n")
}
