# =============================================================================
# 06b_conference_comparison.R
# -----------------------------------------------------------------------------
# Figures comparing CONFERENCE vs JOURNAL citation endogeneity:
#   fig8_conf_vs_journal_excess.png       — excess endogeneity by country
#   fig9_conf_vs_journal_temporal.png     — endogeneity over time, each conf
#                                            series (>=50 cites) vs journals
#   fig9b_conf_vs_journal_temporal_by_country.png — over time, by country
#   fig10_endogeneity_by_series.png       — endogeneity by conference series
#   fig10b_endogeneity_by_series_temporal.png — over time, faceted by series
#
# Uses the ADHO-GLOBAL conference subset (the international annual conference) by
# default, so the comparison is NOT confounded by mechanically-regional national
# conferences. Override with CONF_SUFFIX (e.g. "" for all conferences, "_regional").
#
# Reads country-level endogeneity (05 journal, 18 conference) and temporal overall
# (06 journal, 18 conference). Style mirrors script 06 (300 dpi PNG to output/).
#
# Run:  Rscript R/06b_conference_comparison.R
#       CONF_SUFFIX="" Rscript R/06b_conference_comparison.R   # all conferences
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(viridis)
  library(patchwork)
})

out_dir <- file.path("data", "output")
fig_dir <- "output"
dir.create(fig_dir, showWarnings = FALSE, recursive = TRUE)

# Which conference subset to plot. Default to the ADHO-global subset.
CONF_SUFFIX  <- Sys.getenv("CONF_SUFFIX", unset = "_adho")
conf_label   <- switch(CONF_SUFFIX,
                       "_adho"     = "ADHO conference",
                       "_regional" = "Regional conferences",
                       "Conferences")

# --- data --------------------------------------------------------------------
conf <- readr::read_csv(
  file.path(out_dir, paste0("18_conf_country_endogeneity", CONF_SUFFIX, ".csv")),
  show_col_types = FALSE)
jour <- readr::read_csv("data/05_country_endogeneity.csv", show_col_types = FALSE)

# Countries that clear the conference threshold are the comparable set.
cc <- conf %>% filter(meets_threshold) %>% pull(citing_country)

comp <- bind_rows(
  conf %>% filter(citing_country %in% cc) %>%
    transmute(country = citing_country, venue = conf_label,
              excess = excess_endogeneity_any, scr = scr_any,
              n = n_citations, ratio = endogeneity_ratio_any),
  jour %>% filter(citing_country %in% cc) %>%
    transmute(country = citing_country, venue = "Journals",
              excess = excess_endogeneity_any, scr = scr_any,
              n = n_citations, ratio = endogeneity_ratio_any)
)
# order countries by conference excess endogeneity (descending)
ord <- conf %>% filter(citing_country %in% cc) %>%
  arrange(excess_endogeneity_any) %>% pull(citing_country)
comp <- comp %>% mutate(country = factor(country, levels = ord))

# ============================================================================
# FIGURE 8 — excess endogeneity by country, conference vs journal
# ============================================================================
venue_cols <- setNames(c("#440154", "#21908C"), c(conf_label, "Journals"))

p8 <- ggplot(comp, aes(x = country, y = excess, fill = venue)) +
  geom_col(position = position_dodge(width = 0.75), width = 0.7) +
  coord_flip() +
  scale_fill_manual(values = venue_cols, name = NULL) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
  labs(
    title = sprintf("Citation endogeneity: %s vs DH journals", conf_label),
    subtitle = "Excess self-country citation (observed minus chance), by citing country",
    x = NULL, y = "Excess endogeneity (any-overlap)",
    caption = paste0("Countries with ≥100 conference citations. Excess = ",
                     "observed self-country citation rate minus the rate expected ",
                     "by chance.\nConference set is small and coverage-filtered ",
                     "(see methods); magnitudes are indicative.")
  ) +
  theme_minimal(base_size = 12) +
  theme(legend.position = "top",
        plot.title = element_text(face = "bold"),
        plot.caption = element_text(size = 8, colour = "grey40", hjust = 0),
        panel.grid.major.y = element_blank())

ggsave(file.path(fig_dir, "fig8_conf_vs_journal_excess.png"), p8,
       width = 8, height = 6, dpi = 300)
cat("wrote fig8_conf_vs_journal_excess.png\n")

# ============================================================================
# FIGURE 9 — endogeneity over time: each conference SERIES (>=50 cites) vs
#            the journal corpus as a reference baseline.
# ----------------------------------------------------------------------------
# One coloured line per qualifying conference series (from 18_conf_series_*),
# plus a neutral (black, dashed) Journals reference line so series can be read
# against the journal benchmark. Falls back to the old ADHO-vs-journals plot if
# the per-series files are absent.
# ============================================================================
series_stat_f <- file.path(out_dir, "18_conf_series_endogeneity.csv")
series_temp_f <- file.path(out_dir, "18_conf_series_temporal.csv")
t_jour <- readr::read_csv("data/06_temporal_overall.csv",
                          show_col_types = FALSE) %>% mutate(series = "Journals")

if (file.exists(series_stat_f) && file.exists(series_temp_f)) {
  keep9 <- readr::read_csv(series_stat_f, show_col_types = FALSE) %>%
    filter(meets_threshold) %>% pull(venue_series)

  ser_t <- readr::read_csv(series_temp_f, show_col_types = FALSE) %>%
    filter(venue_series %in% keep9) %>%
    transmute(citing_year, scr_any, n_citations, series = venue_series)

  temporal9 <- bind_rows(ser_t, t_jour)
  # colour: viridis for the series, black for the Journals baseline
  ser_levels <- sort(unique(ser_t$series))
  ser_cols   <- setNames(viridis::viridis(length(ser_levels), end = 0.9),
                         ser_levels)
  pal9 <- c(ser_cols, Journals = "black")
  temporal9 <- temporal9 %>%
    mutate(series = factor(series, levels = c(ser_levels, "Journals")),
           is_ref = series == "Journals")

  p9 <- ggplot(temporal9, aes(x = citing_year, y = scr_any,
                              colour = series, group = series)) +
    geom_line(aes(linetype = is_ref), linewidth = 1) +
    geom_point(aes(size = n_citations), alpha = 0.7) +
    scale_colour_manual(values = pal9, name = NULL) +
    scale_linetype_manual(values = c(`FALSE` = "solid", `TRUE` = "dashed"),
                          guide = "none") +
    scale_size_continuous(name = "Citations\n(per year)", range = c(1, 6),
                          labels = scales::comma) +
    scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                       limits = c(0, NA)) +
    labs(
      title = "Endogeneity over time: conference series vs journals",
      subtitle = "Any-overlap self-country citation rate by year (series with ≥50 citations)",
      x = NULL, y = "Endogeneity (any-overlap)",
      caption = paste0("Journals (dashed black) = reference baseline. ",
                       "Point size = citations that year; smaller series are noisier.")
    ) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "right",
          plot.title = element_text(face = "bold"),
          plot.caption = element_text(size = 8, colour = "grey40", hjust = 0))
} else {
  # fallback: original ADHO-vs-journals 2-line plot
  t_conf <- readr::read_csv(
    file.path(out_dir, paste0("18_conf_temporal_overall", CONF_SUFFIX, ".csv")),
    show_col_types = FALSE) %>% mutate(series = conf_label)
  temporal9 <- bind_rows(t_conf, t_jour %>% rename(series = series))
  p9 <- ggplot(temporal9, aes(x = citing_year, y = scr_any,
                              colour = series, group = series)) +
    geom_line(linewidth = 1) +
    geom_point(aes(size = n_citations), alpha = 0.7) +
    scale_colour_manual(values = setNames(c("#440154", "#21908C"),
                                          c(conf_label, "Journals")), name = NULL) +
    scale_size_continuous(name = "Citations\n(per year)", range = c(1, 6),
                          labels = scales::comma) +
    scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                       limits = c(0, NA)) +
    labs(title = sprintf("Endogeneity over time: %s vs journals", conf_label),
         subtitle = "Overall any-overlap self-country citation rate by year",
         x = NULL, y = "Endogeneity (any-overlap)") +
    theme_minimal(base_size = 12) +
    theme(legend.position = "right",
          plot.title = element_text(face = "bold"))
}

ggsave(file.path(fig_dir, "fig9_conf_vs_journal_temporal.png"), p9,
       width = 9, height = 5.5, dpi = 300)
cat("wrote fig9_conf_vs_journal_temporal.png\n")

# ============================================================================
# FIGURE 9b — endogeneity over time BY COUNTRY, conference vs journal
# ============================================================================
t_conf_cty <- readr::read_csv(
  file.path(out_dir, paste0("18_conf_temporal_by_country", CONF_SUFFIX, ".csv")),
  show_col_types = FALSE) %>% mutate(venue = conf_label)
t_jour_cty <- readr::read_csv("data/07_temporal_by_country.csv",
                               show_col_types = FALSE) %>% mutate(venue = "Journals")

# Restrict to countries that clear the conference threshold (same set as fig8)
temporal_cty <- bind_rows(t_conf_cty, t_jour_cty) %>%
  filter(citing_country %in% cc) %>%
  mutate(venue = factor(venue, levels = c(conf_label, "Journals")))

p9b <- ggplot(temporal_cty, aes(x = citing_year, y = scr_any,
                                colour = venue, group = venue)) +
  facet_wrap(~ citing_country, scales = "free_y") +
  geom_line(linewidth = 0.8) +
  geom_point(aes(size = n_citations), alpha = 0.7) +
  scale_colour_manual(values = venue_cols, name = NULL) +
  scale_size_continuous(name = "Citations\n(per year)", range = c(1, 5),
                        labels = scales::comma) +
  scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                     expand = expansion(mult = c(0, 0.05))) +
  labs(
    title = sprintf("Endogeneity over time by country: %s vs journals", conf_label),
    subtitle = "Any-overlap self-country citation rate by year",
    x = NULL, y = "Endogeneity (any-overlap)",
    caption = paste0("Countries with ≥100 conference citations. ",
                     "Point size = citations that year.")
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "top",
        plot.title = element_text(face = "bold"),
        plot.caption = element_text(size = 8, colour = "grey40", hjust = 0),
        panel.grid.minor = element_blank())

ggsave(file.path(fig_dir, "fig9b_conf_vs_journal_temporal_by_country.png"), p9b,
       width = 12, height = 10, dpi = 300)
cat("wrote fig9b_conf_vs_journal_temporal_by_country.png\n")

# ============================================================================
# FIGURE 10 — endogeneity by conference SERIES (B1 venue_series), faceted
# ----------------------------------------------------------------------------
# Each regional series is kept separate (they are not interchangeable). Only
# series clearing the >=50-citation threshold are shown, so every panel is
# statistically non-trivial. Source files come from the FULL ("all") run of 18.
# ============================================================================
series_file <- file.path(out_dir, "18_conf_series_endogeneity.csv")
series_temp <- file.path(out_dir, "18_conf_series_temporal.csv")

if (file.exists(series_file) && file.exists(series_temp)) {
  s_stats <- readr::read_csv(series_file, show_col_types = FALSE)
  s_temp  <- readr::read_csv(series_temp, show_col_types = FALSE)

  keep_series <- s_stats %>% filter(meets_threshold) %>% pull(venue_series)
  cat("Series clearing threshold:", length(keep_series),
      "->", paste(keep_series, collapse = ", "), "\n")

  if (length(keep_series) > 0) {
    # --- fig10: bar of overall endogeneity per qualifying series ------------
    sb <- s_stats %>%
      filter(venue_series %in% keep_series) %>%
      mutate(venue_series = forcats::fct_reorder(venue_series, scr_any))

    p10 <- ggplot(sb, aes(x = venue_series, y = scr_any, fill = scr_any)) +
      geom_col(width = 0.7, show.legend = FALSE) +
      geom_text(aes(label = sprintf("%.0f%% (n=%s)", 100 * scr_any,
                                    scales::comma(n_citations))),
                hjust = -0.05, size = 3) +
      coord_flip() +
      scale_fill_viridis(option = "D", end = 0.9) +
      scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                         expand = expansion(mult = c(0, 0.22))) +
      labs(
        title = "Citation endogeneity by conference series",
        subtitle = "Any-overlap self-country citation rate; series with ≥50 citations",
        x = NULL, y = "Endogeneity (any-overlap)",
        caption = paste0("Each regional series kept separate (B1 rule). ",
                         "n = citation records. Coverage-filtered subset; ",
                         "magnitudes are indicative.")
      ) +
      theme_minimal(base_size = 12) +
      theme(plot.title = element_text(face = "bold"),
            plot.caption = element_text(size = 8, colour = "grey40", hjust = 0),
            panel.grid.major.y = element_blank())

    ggsave(file.path(fig_dir, "fig10_endogeneity_by_series.png"), p10,
           width = 9, height = 1.6 + 0.55 * length(keep_series), dpi = 300)
    cat("wrote fig10_endogeneity_by_series.png\n")

    # --- fig10b: temporal facet per qualifying series ----------------------
    st <- s_temp %>% filter(venue_series %in% keep_series)

    p10b <- ggplot(st, aes(x = citing_year, y = scr_any)) +
      facet_wrap(~ venue_series, scales = "free_x") +
      geom_line(linewidth = 0.8, colour = "#440154") +
      geom_point(aes(size = n_citations), alpha = 0.7, colour = "#440154") +
      scale_size_continuous(name = "Citations\n(per year)", range = c(1, 5),
                            labels = scales::comma) +
      scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                         limits = c(0, NA)) +
      labs(
        title = "Endogeneity over time by conference series",
        subtitle = "Any-overlap self-country citation rate; series with ≥50 citations",
        x = NULL, y = "Endogeneity (any-overlap)",
        caption = "Point size = citations that year. Yearly points are noisy for smaller series."
      ) +
      theme_minimal(base_size = 11) +
      theme(plot.title = element_text(face = "bold"),
            plot.caption = element_text(size = 8, colour = "grey40", hjust = 0),
            panel.grid.minor = element_blank())

    ggsave(file.path(fig_dir, "fig10b_endogeneity_by_series_temporal.png"), p10b,
           width = 11, height = 8, dpi = 300)
    cat("wrote fig10b_endogeneity_by_series_temporal.png\n")
  } else {
    cat("No conference series clears the threshold; skipping fig10.\n")
  }
} else {
  cat("Series files not found (run 18 with VENUE_GROUP=all first); skipping fig10.\n")
}

cat("\nDone. Figures in", fig_dir, "/\n")
