###############################################################################
# DH Citation Endogeneity Study
# Phase 6: All visualizations
#
# Produces 7 figures from the analysis outputs:
#   Fig 1: Citation flow network (top 25 countries)
#   Fig 2: Citation heatmap (top 30 countries, grouped by region)
#   Fig 3: Temporal trends (excess endogeneity, top 15 countries)
#   Fig 4: Excess endogeneity bar chart (top 30 countries)
#   Fig 5: Bridge scholars scatter (entropy vs self-citation)
#   Fig 6: DH vs comparator fields
#   Fig 7: Sensitivity comparison across journal tiers
#
# All saved to output/ as PNG (300 dpi).
###############################################################################

library(tidyverse)
library(igraph)
library(ggraph)
library(tidygraph)
library(countrycode)
library(viridis)
library(patchwork)

source("R/helpers/country_regions.R")

# --- Configuration -----------------------------------------------------------

OUTPUT_DIR <- "output"
dir.create(OUTPUT_DIR, showWarnings = FALSE)
DPI <- 300
MIN_CITATIONS_THRESHOLD <- 100  # Must match value in 03_endogeneity_analysis.R
BRIDGE_MIN_WORKS     <- 3      # Must match value in 03_endogeneity_analysis.R
BRIDGE_MIN_CITATIONS <- 10     # Must match value in 03_endogeneity_analysis.R

# Primary corpus for Figs 1-5: "core" tier (Exclusively + keyword-matched DH)
PRIMARY_SUFFIX <- "_core"
CORPUS_LABEL   <- "Core DH corpus (Exclusively DH + keyword-matched journals)"

# Custom colour palette for regions
region_colours <- c(
  "W. Europe"    = "#1b9e77",
  "N. Europe"    = "#66c2a5",
  "S. Europe"    = "#b2e2ce",
  "E. Europe"    = "#d5f4e6",
  "N. America"   = "#d95f02",
  "Latin America" = "#fc8d62",
  "E. Asia"      = "#7570b3",
  "SE Asia"      = "#bcbddc",
  "Other Asia"   = "#dadaeb",
  "Oceania"      = "#e7298a",
  "Africa"       = "#e6ab02",
  "Other"        = "#999999"
)

cat("================================================================\n")
cat("   GENERATING VISUALIZATIONS\n")
cat("================================================================\n\n")

# --- Load data ---------------------------------------------------------------

# Read all data files (some may be empty if pipeline was run with new journal list
# but cited works haven't been re-fetched yet)
country_stats    <- read_csv(paste0("data/05_country_endogeneity", PRIMARY_SUFFIX, ".csv"), show_col_types = FALSE)
temporal_overall <- read_csv(paste0("data/06_temporal_overall", PRIMARY_SUFFIX, ".csv"), show_col_types = FALSE)
temporal_country <- read_csv(paste0("data/07_temporal_by_country", PRIMARY_SUFFIX, ".csv"), show_col_types = FALSE)
bridge_scholars  <- read_csv(paste0("data/08_bridge_scholars", PRIMARY_SUFFIX, ".csv"), show_col_types = FALSE)
flow_matrix      <- read_csv(paste0("data/09_citation_flow_matrix", PRIMARY_SUFFIX, ".csv"), show_col_types = FALSE)
if (file.exists(paste0("data/10_temporal_slopes", PRIMARY_SUFFIX, ".csv"))) {
  temporal_slopes <- read_csv(paste0("data/10_temporal_slopes", PRIMARY_SUFFIX, ".csv"), show_col_types = FALSE)
} else {
  temporal_slopes <- tibble()
}
# Bridge scholar temporal data
bridge_temporal_file <- paste0("data/12_bridge_temporal", PRIMARY_SUFFIX, ".csv")
if (file.exists(bridge_temporal_file)) {
  bridge_temporal <- read_csv(bridge_temporal_file, show_col_types = FALSE)
} else {
  bridge_temporal <- tibble()
}

# Compute sample sizes for figure annotations
n_total_citations <- sum(temporal_overall$n_citations, na.rm = TRUE)
n_countries_with_data <- sum(country_stats$meets_threshold, na.rm = TRUE)

cat("Data loaded (primary corpus: core):\n")
cat("  country_stats:", nrow(country_stats), "rows\n")
cat("  temporal_overall:", nrow(temporal_overall), "rows\n")
cat("  temporal_country:", nrow(temporal_country), "rows\n")
cat("  bridge_scholars:", nrow(bridge_scholars), "rows\n")
cat("  flow_matrix:", nrow(flow_matrix), "rows\n")
cat("  temporal_slopes:", nrow(temporal_slopes), "rows\n")
cat("  bridge_temporal:", nrow(bridge_temporal), "rows\n")

# Comparator data (optional — may not exist if 04/05 haven't been run)
has_comparator <- file.exists("data/14_comparator_temporal.csv") &&
                  file.exists("data/15_field_comparison_summary.csv")
if (has_comparator) {
  comp_temporal <- read_csv("data/14_comparator_temporal.csv", show_col_types = FALSE)
  field_summary <- read_csv("data/15_field_comparison_summary.csv", show_col_types = FALSE)
  cat("Comparator data loaded.\n")
} else {
  cat("No comparator data found — skipping Figs 6.\n")
}

# Sensitivity data (optional — may not exist if sensitivity runs haven't been done)
sensitivity_files <- c(
  all         = "data/05_country_endogeneity.csv",
  exclusively = "data/05_country_endogeneity_exclusively.csv",
  core        = "data/05_country_endogeneity_core.csv"
)
has_sensitivity <- all(file.exists(sensitivity_files))
if (has_sensitivity) {
  sensitivity_data <- map2_dfr(sensitivity_files, names(sensitivity_files),
    ~ read_csv(.x, show_col_types = FALSE) |> mutate(tier = .y)
  )
  cat("Sensitivity data loaded (3 tiers).\n")
} else {
  cat("Not all sensitivity tiers available — skipping Fig 7.\n")
}

# --- Validate loaded data ---
# Ensure proper column types (CSV reading can mis-type empty or short files)
if (nrow(country_stats) == 0) {
  cat("\nWARNING: country_stats has 0 rows. Script 03 may need to be re-run\n")
  cat("  after rebuilding the corpus (scripts 01 → 02 → 03).\n")
  cat("  Generating only figures that don't require country_stats.\n\n")
}

if ("meets_threshold" %in% names(country_stats)) {
  country_stats <- country_stats |>
    mutate(meets_threshold = as.logical(meets_threshold))
}

# Add region data to country stats
if (nrow(country_stats) > 0) {
  country_stats <- country_stats |>
    add_region_data(country_col = "citing_country")
}

cat("\n")

###############################################################################
# FIG 1: Citation flow network
###############################################################################

cat("--- Fig 1: Citation flow network ---\n")

# Need data in country_stats to proceed
has_country_data <- nrow(country_stats) > 0 &&
  "meets_threshold" %in% names(country_stats) &&
  any(country_stats$meets_threshold, na.rm = TRUE)

if (!has_country_data) {
  cat("  SKIPPED: No country data available (re-run scripts 01→02→03 first)\n")
} else {

# Get top 25 countries by citation volume
top25 <- country_stats |>
  filter(meets_threshold) |>
  slice_head(n = 25) |>
  pull(citing_country)

# Prepare edge list from flow matrix
flow_long <- flow_matrix |>
  rename(from = citing_country) |>
  pivot_longer(-from, names_to = "to", values_to = "weight") |>
  filter(from %in% top25, to %in% top25, from != to, weight > 0)

# Keep only top edges by weight to avoid visual clutter
# Threshold: keep edges representing top 80% of total flow
flow_long <- flow_long |>
  arrange(desc(weight)) |>
  mutate(cumshare = cumsum(weight) / sum(weight)) |>
  filter(cumshare <= 0.80 | row_number() <= 50)  # Keep at least 50 edges

# Node attributes
node_data <- country_stats |>
  filter(citing_country %in% top25) |>
  select(name = citing_country, n_citations, excess_endogeneity_any, geo_group)

# Create graph
g <- tbl_graph(
  nodes = node_data,
  edges = flow_long |> select(from, to, weight),
  directed = TRUE
)

p1 <- ggraph(g, layout = "fr") +
  geom_edge_arc(
    aes(width = weight, alpha = weight),
    arrow = arrow(length = unit(2, "mm"), type = "closed"),
    end_cap = circle(4, "mm"),
    strength = 0.2,
    colour = "grey50"
  ) +
  geom_node_point(
    aes(size = n_citations, fill = excess_endogeneity_any),
    shape = 21, colour = "grey30"
  ) +
  geom_node_text(aes(label = name), size = 2.8, repel = TRUE,
                 max.overlaps = 30) +
  scale_edge_width(range = c(0.2, 2.5), guide = "none") +
  scale_edge_alpha(range = c(0.15, 0.6), guide = "none") +
  scale_size_continuous(range = c(3, 14), name = "Citations",
                        labels = scales::comma) +
  scale_fill_gradient2(
    low = "#2166ac", mid = "white", high = "#b2182b", midpoint = 0,
    name = "Excess\nendogeneity",
    labels = scales::percent
  ) +
  labs(
    title = "Citation flows between top 25 DH countries",
    subtitle = "Node size = citation volume; colour = excess endogeneity (red = more insular than expected)",
    caption = paste0(CORPUS_LABEL, "\nN = ", scales::comma(n_total_citations),
                     " citations from ", n_countries_with_data, " countries")
  ) +
  theme_void() +
  theme(
    plot.title = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(size = 10, colour = "grey40"),
    plot.caption = element_text(size = 8, colour = "grey50", hjust = 0),
    legend.position = "right"
  )

ggsave(file.path(OUTPUT_DIR, "fig1_citation_network.png"),
       p1, width = 12, height = 10, dpi = DPI, bg = "white")
cat("  Saved fig1_citation_network.png\n")

} # end if has_country_data (Fig 1)

###############################################################################
# FIG 2: Citation heatmap
###############################################################################

cat("--- Fig 2: Citation heatmap ---\n")

if (!has_country_data) {
  cat("  SKIPPED: No country data available\n")
} else {

# Top 30 countries
top30 <- country_stats |>
  filter(meets_threshold) |>
  slice_head(n = 30) |>
  pull(citing_country)

# Long form of the FULL flow matrix (all countries) — needed both for the
# row-normalised observed share and for the expected share (null model).
flow_long <- flow_matrix |>
  rename(from = citing_country) |>
  pivot_longer(-from, names_to = "to", values_to = "n_cites")

# EXPECTED share per cited country = that country's share of the ENTIRE citation
# pool (grand total over ALL citing/cited countries, NOT just the top 30). This
# matches the null model behind expected_scr in 05_country_endogeneity: under
# random citing, a country is cited in proportion to its overall presence.
grand_total   <- sum(flow_long$n_cites, na.rm = TRUE)
expected_share <- flow_long |>
  group_by(to) |>
  summarise(expected = sum(n_cites, na.rm = TRUE) / grand_total, .groups = "drop")

# OBSERVED share = row-normalised (i's citations to j / i's total citations),
# computed over the full row so shares are correct; then subset to the top 30.
heat_data <- flow_long |>
  group_by(from) |>
  mutate(prop = n_cites / sum(n_cites, na.rm = TRUE)) |>
  ungroup() |>
  filter(from %in% top30, to %in% top30) |>
  # excess = observed minus expected (the country×country generalisation of
  # excess endogeneity; the diagonal is each country's self-country excess).
  left_join(expected_share, by = "to") |>
  mutate(excess = prop - expected)

# Order rows and columns by region, then alphabetically within region
country_order <- country_stats |>
  filter(citing_country %in% top30) |>
  select(citing_country, geo_group) |>
  arrange(geo_group, citing_country) |>
  pull(citing_country)

heat_data <- heat_data |>
  mutate(
    from = factor(from, levels = rev(country_order)),
    to   = factor(to, levels = country_order)
  )

# Add region labels for annotation
region_labels <- country_stats |>
  filter(citing_country %in% top30) |>
  select(citing_country, geo_group) |>
  arrange(match(citing_country, country_order))

# Symmetric colour limits so 0 (= cited exactly as much as chance) sits at the
# white midpoint; cap at a robust quantile so a few extreme cells don't wash out
# the rest.
excess_cap <- stats::quantile(abs(heat_data$excess), 0.98, na.rm = TRUE)

p2 <- ggplot(heat_data, aes(x = to, y = from, fill = excess)) +
  geom_tile(colour = "white", linewidth = 0.3) +
  scale_fill_gradient2(
    low = "#2166AC", mid = "white", high = "#B2182B", midpoint = 0,
    limits = c(-excess_cap, excess_cap), oob = scales::squish,
    name = "Excess\n(obs − exp)",
    labels = scales::percent
  ) +
  labs(
    title = "Excess citation heatmap: who cites whom more than chance?",
    subtitle = paste0("Cell = observed minus expected citation share. ",
                      "Red = more than chance, blue = less; diagonal = self-country. ",
                      "Ordered by region."),
    caption = paste0(CORPUS_LABEL,
                     "\nExpected share = cited country's share of the full citation ",
                     "pool. Top 30 countries; N = ",
                     scales::comma(n_total_citations), " citations."),
    x = "Cited country",
    y = "Citing country"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(face = "bold", size = 13),
    plot.subtitle = element_text(size = 9, colour = "grey40"),
    plot.caption = element_text(size = 8, colour = "grey50", hjust = 0),
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 8),
    axis.text.y = element_text(size = 8),
    panel.grid = element_blank(),
    legend.position = "right"
  )

ggsave(file.path(OUTPUT_DIR, "fig2_citation_heatmap.png"),
       p2, width = 12, height = 10, dpi = DPI, bg = "white")
cat("  Saved fig2_citation_heatmap.png\n")

} # end if has_country_data (Fig 2)

###############################################################################
# FIG 3: Temporal trends
###############################################################################

cat("--- Fig 3: Temporal trends ---\n")

if (nrow(temporal_overall) == 0) {
  cat("  SKIPPED: No temporal data available\n")
} else {

# Overall temporal trend
p3a <- ggplot(temporal_overall, aes(x = citing_year, y = scr_any)) +
  geom_line(linewidth = 1.2, colour = "#d95f02") +
  geom_point(aes(size = n_citations), colour = "#d95f02", alpha = 0.7) +
  scale_size_continuous(range = c(1, 5), name = "Citations",
                        labels = scales::comma) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title = "Overall DH citation endogeneity over time",
    subtitle = paste0("N = ", scales::comma(n_total_citations), " citations across ",
                      nrow(temporal_overall), " years"),
    x = "Year", y = "Self-citation rate (any overlap)"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(face = "bold", size = 12),
    plot.subtitle = element_text(size = 9, colour = "grey40")
  )

# Per-country excess endogeneity trends.
# DRAWN LINES: only the top 15 countries by citation volume, for readability.
# MEAN LINE: equal-weight mean over the FULL >=100-citation set (all analysable
# countries), so the central-tendency line is NOT biased toward the high-volume
# countries that happen to be plotted. The two sets are deliberately different.
thresh_countries <- country_stats |>
  filter(meets_threshold) |>
  pull(citing_country)

# country_stats is ordered by citation volume, so the first 15 of the threshold
# set are the top 15 (matches TOP_N_COUNTRIES used elsewhere in script 03).
top15_countries <- head(thresh_countries, 15)

temporal_country_thr <- temporal_country |>
  filter(citing_country %in% thresh_countries)   # full >=100 set (for the mean)

temporal_country_top <- temporal_country_thr |>
  filter(citing_country %in% top15_countries)    # top 15 (drawn lines)

# Bold EQUAL-WEIGHT mean across the FULL >=100 set: each country weighted equally
# per year (simple average of per-country excess), NOT citation-weighted — so a
# small country counts the same as a large one.
excess_mean <- temporal_country_thr |>
  group_by(citing_year) |>
  summarise(excess_scr_any = mean(excess_scr_any, na.rm = TRUE),
            .groups = "drop")

p3b <- ggplot(temporal_country_top, aes(x = citing_year, y = excess_scr_any)) +
  geom_line(aes(colour = citing_country, group = citing_country),
            linewidth = 0.6, alpha = 0.7) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
  geom_line(data = excess_mean, aes(x = citing_year, y = excess_scr_any),
            colour = "black", linewidth = 1.5, inherit.aes = FALSE) +
  geom_point(data = excess_mean, aes(x = citing_year, y = excess_scr_any),
             colour = "black", size = 2, inherit.aes = FALSE) +
  scale_colour_viridis_d(option = "turbo", name = "Country") +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title = "Excess endogeneity by country over time",
    subtitle = paste0("Top 15 countries by citation volume (lines); bold black = ",
                      "equal-weight mean over all ",
                      n_distinct(temporal_country_thr$citing_country),
                      " countries (≥100 citations); dashed = neutral"),
    caption = CORPUS_LABEL,
    x = "Year", y = "Excess endogeneity (SCR - expected)"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(face = "bold", size = 12),
    plot.subtitle = element_text(size = 9, colour = "grey40"),
    plot.caption = element_text(size = 8, colour = "grey50", hjust = 0),
    legend.position = "right"
  )

p3 <- p3a / p3b + plot_layout(heights = c(1, 1.5))

ggsave(file.path(OUTPUT_DIR, "fig3_temporal_trends.png"),
       p3, width = 13, height = 11, dpi = DPI, bg = "white")
cat("  Saved fig3_temporal_trends.png\n")

} # end if temporal data (Fig 3)

###############################################################################
# FIG 4: Excess endogeneity bar chart
###############################################################################

cat("--- Fig 4: Excess endogeneity bar chart ---\n")

if (!has_country_data) {
  cat("  SKIPPED: No country data available\n")
} else {

bar_data <- country_stats |>
  filter(meets_threshold) |>
  slice_head(n = 30) |>
  mutate(
    sig = ifelse(!is.na(p_value_any) & p_value_any < 0.05, "p < 0.05", "n.s."),
    citing_country = fct_reorder(citing_country, excess_endogeneity_any)
  )

p4 <- ggplot(bar_data, aes(x = citing_country, y = excess_endogeneity_any, fill = sig)) +
  geom_col(width = 0.7) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey40") +
  coord_flip() +
  scale_fill_manual(
    values = c("p < 0.05" = "#e41a1c", "n.s." = "#999999"),
    name = "Significance"
  ) +
  scale_y_continuous(labels = scales::percent) +
  labs(
    title = "Excess citation endogeneity by country",
    subtitle = paste0("Top 30 of ", n_countries_with_data, " countries with ",
                      MIN_CITATIONS_THRESHOLD, "+ citations; ",
                      "bars = observed SCR minus expected SCR from null model"),
    caption = paste0(CORPUS_LABEL, "\nN = ", scales::comma(n_total_citations), " citations"),
    x = NULL,
    y = "Excess endogeneity (observed - expected)"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(face = "bold", size = 13),
    plot.subtitle = element_text(size = 9, colour = "grey40"),
    plot.caption = element_text(size = 8, colour = "grey50", hjust = 0),
    panel.grid.major.y = element_blank()
  )

ggsave(file.path(OUTPUT_DIR, "fig4_excess_endogeneity.png"),
       p4, width = 10, height = 9, dpi = DPI, bg = "white")
cat("  Saved fig4_excess_endogeneity.png\n")

} # end if has_country_data (Fig 4)

###############################################################################
# FIG 5: Bridge scholars scatter
###############################################################################

cat("--- Fig 5: Bridge scholars ---\n")

if (nrow(bridge_scholars) > 0) {

  # --- Panel A: Scatter plot with reference lines ---

  # Percentile thresholds
  entropy_q <- quantile(bridge_scholars$shannon_entropy,
                         probs = c(0.25, 0.50, 0.75), na.rm = TRUE)
  selfcite_q <- quantile(bridge_scholars$self_cite_rate,
                          probs = c(0.25, 0.50, 0.75), na.rm = TRUE)

  # Entropy reference values: ln(k) = max entropy for k countries
  entropy_refs <- tibble(
    y     = log(c(5, 10, 20, 40)),
    label = c("ln(5)\nuniform\nacross 5", "ln(10)\nuniform\nacross 10",
              "ln(20)\nuniform\nacross 20", "ln(40)\nuniform\nacross 40")
  )

  # Use normalized entropy as color if available, else n_countries_cited
  has_norm_entropy <- "entropy_norm" %in% names(bridge_scholars)

  p5a <- ggplot(bridge_scholars, aes(x = self_cite_rate, y = shannon_entropy)) +
    # Entropy reference bands (theoretical max for k countries)
    geom_hline(yintercept = entropy_refs$y, linetype = "dotted",
               colour = "#b2182b", linewidth = 0.3, alpha = 0.6) +
    annotate("text",
             x = 0.01,
             y = entropy_refs$y + 0.06,
             label = paste0("ln(", c(5, 10, 20, 40), ")"),
             size = 2.2, colour = "#b2182b", hjust = 0, fontface = "italic") +
    # Data points
    geom_point(aes(size = n_citations_total,
                   colour = if (has_norm_entropy) entropy_norm else n_countries_cited),
               alpha = 0.5) +
    # Percentile lines
    geom_hline(yintercept = entropy_q, linetype = "dashed",
               colour = "grey50", linewidth = 0.4) +
    geom_vline(xintercept = selfcite_q, linetype = "dashed",
               colour = "grey50", linewidth = 0.4) +
    # Percentile labels (entropy)
    annotate("text",
             x = max(bridge_scholars$self_cite_rate, na.rm = TRUE) * 0.97,
             y = as.numeric(entropy_q) + 0.05,
             label = c("25th pctile", "50th pctile", "75th pctile"),
             size = 2.5, colour = "grey40", hjust = 1) +
    # Percentile labels (self-citation)
    annotate("text",
             x = as.numeric(selfcite_q) + 0.01,
             y = max(bridge_scholars$shannon_entropy, na.rm = TRUE) * 0.99,
             label = c("25th", "50th", "75th"),
             size = 2.5, colour = "grey40", hjust = 0, vjust = 1) +
    {if (has_norm_entropy)
      scale_colour_viridis_c(option = "plasma", name = "Normalized\nentropy\n(H/ln(k))",
                              limits = c(0, 1), labels = scales::percent)
    else
      scale_colour_viridis_c(option = "plasma", name = "Countries\ncited")} +
    scale_size_continuous(range = c(1, 8), name = "Total\ncitations",
                          labels = scales::comma) +
    scale_x_continuous(labels = scales::percent) +
    labs(
      title = "Citation diversity vs geographic self-citation among DH authors",
      subtitle = paste0("N = ", scales::comma(nrow(bridge_scholars)), " authors with ",
                        BRIDGE_MIN_WORKS, "+ works and ",
                        BRIDGE_MIN_CITATIONS, "+ citations\n",
                        "Grey dashed = 25th/50th/75th percentiles; ",
                        "red dotted = theoretical max entropy for k countries"),
      x = "Geographic self-citation rate",
      y = "Citation entropy (Shannon)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 8, colour = "grey40")
    )

  # --- Panel B: Temporal trend (if data available) ---

  if (nrow(bridge_temporal) > 0) {
    p5b <- ggplot(bridge_temporal, aes(x = citing_year)) +
      geom_col(aes(y = pct_bridge), fill = "#2166ac", alpha = 0.7, width = 0.7) +
      geom_line(aes(y = pct_bridge), colour = "#2166ac", linewidth = 0.8) +
      geom_text(aes(y = pct_bridge, label = n_bridge_scholars),
                vjust = -0.5, size = 2.5, colour = "grey30") +
      scale_y_continuous(labels = scales::percent,
                         expand = expansion(mult = c(0, 0.15))) +
      labs(
        title = "Proportion of bridge scholars among active DH authors over time",
        subtitle = "Numbers above bars = count of bridge scholars active that year",
        caption = CORPUS_LABEL,
        x = "Publication year",
        y = "Bridge scholars / active authors"
      ) +
      theme_minimal() +
      theme(
        plot.title = element_text(face = "bold", size = 11),
        plot.subtitle = element_text(size = 8.5, colour = "grey40"),
        plot.caption = element_text(size = 8, colour = "grey50", hjust = 0)
      )

    p5 <- p5a / p5b + plot_layout(heights = c(2, 1))
    fig5_height <- 13
  } else {
    p5 <- p5a +
      labs(caption = CORPUS_LABEL) +
      theme(plot.caption = element_text(size = 8, colour = "grey50", hjust = 0))
    fig5_height <- 8
    cat("  Note: no bridge temporal data, showing scatter only\n")
  }

  ggsave(file.path(OUTPUT_DIR, "fig5_bridge_scholars.png"),
         p5, width = 11, height = fig5_height, dpi = DPI, bg = "white")
  cat("  Saved fig5_bridge_scholars.png\n")
} else {
  cat("  SKIPPED: No bridge scholars data (empty CSV)\n")
}

###############################################################################
# FIG 6: DH vs comparator fields
###############################################################################

cat("--- Fig 6: DH vs comparator fields ---\n")

if (has_comparator) {
  # Bar chart: overall endogeneity by field
  p6a <- ggplot(field_summary,
                aes(x = fct_reorder(field, scr_any), y = scr_any)) +
    geom_col(fill = "#2166ac", width = 0.6) +
    geom_errorbar(
      aes(ymin = expected_scr_avg, ymax = expected_scr_avg),
      width = 0.3, colour = "#b2182b", linewidth = 0.8, linetype = "dashed"
    ) +
    coord_flip() +
    scale_y_continuous(labels = scales::percent) +
    labs(
      title = "Citation endogeneity: DH vs comparator fields",
      subtitle = "Blue bars = observed SCR; red dashed = expected from null model",
      x = NULL,
      y = "Self-citation rate (any overlap)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 9, colour = "grey40")
    )

  # Temporal comparison
  p6b <- ggplot(comp_temporal |> bind_rows(temporal_overall |> mutate(field = "Digital Humanities")),
                aes(x = citing_year, y = scr_any, colour = field)) +
    geom_line(linewidth = 0.9) +
    geom_point(size = 1.5) +
    scale_colour_brewer(palette = "Set1", name = "Field") +
    scale_y_continuous(labels = scales::percent) +
    labs(
      title = "Endogeneity trends across fields",
      x = "Year",
      y = "Self-citation rate (any overlap)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 12),
      legend.position = "bottom"
    )

  p6 <- p6a / p6b + plot_layout(heights = c(1, 1.3))

  ggsave(file.path(OUTPUT_DIR, "fig6_comparator_fields.png"),
         p6, width = 11, height = 10, dpi = DPI, bg = "white")
  cat("  Saved fig6_comparator_fields.png\n")
} else {
  cat("  SKIPPED: No comparator data available\n")
}

###############################################################################
# FIG 7: Sensitivity comparison
###############################################################################

cat("--- Fig 7: Sensitivity comparison ---\n")

if (has_sensitivity) {
  # Compare country endogeneity across 3 tiers
  tier_labels <- c(
    all         = "All (Excl. + Keywords + Signif.)",
    core        = "Core (Excl. + Keywords)",
    exclusively = "Exclusively DH journals"
  )

  sensitivity_data <- sensitivity_data |>
    mutate(tier_label = tier_labels[tier])

  # Compare top countries' excess endogeneity across tiers
  top_countries_all <- sensitivity_data |>
    filter(tier == "all", meets_threshold) |>
    arrange(desc(n_citations)) |>
    slice_head(n = 20) |>
    pull(citing_country)

  sens_plot_data <- sensitivity_data |>
    filter(citing_country %in% top_countries_all, meets_threshold) |>
    select(citing_country, tier_label, scr_any, excess_endogeneity_any) |>
    mutate(citing_country = factor(citing_country, levels = rev(top_countries_all)))

  # Compute corpus sizes per tier for annotation
  tier_sizes <- sensitivity_data |>
    group_by(tier) |>
    summarise(n_cites = sum(n_citations, na.rm = TRUE), .groups = "drop") |>
    mutate(tier_label = tier_labels[tier])
  tier_size_str <- paste(tier_sizes$tier_label, ":",
                         scales::comma(tier_sizes$n_cites), "citations",
                         collapse = "  |  ")

  p7a <- ggplot(sens_plot_data,
                aes(x = citing_country, y = scr_any, fill = tier_label)) +
    geom_col(position = position_dodge(width = 0.7), width = 0.6) +
    coord_flip() +
    scale_fill_brewer(palette = "Set2", name = "Corpus tier") +
    scale_y_continuous(labels = scales::percent) +
    labs(
      title = "Self-citation rate by corpus tier",
      subtitle = paste0("Top 20 countries; sample sizes: ", tier_size_str),
      x = NULL,
      y = "SCR (any overlap)"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(face = "bold", size = 12),
      plot.subtitle = element_text(size = 7.5, colour = "grey40"),
      legend.position = "bottom"
    )

  # Also read temporal data for each tier if available
  temp_files <- c(
    all         = "data/06_temporal_overall.csv",
    exclusively = "data/06_temporal_overall_exclusively.csv",
    core        = "data/06_temporal_overall_core.csv"
  )
  has_temp_sensitivity <- all(file.exists(temp_files))

  if (has_temp_sensitivity) {
    temp_sens <- map2_dfr(temp_files, names(temp_files),
      ~ read_csv(.x, show_col_types = FALSE) |> mutate(tier = .y)
    ) |>
      mutate(tier_label = tier_labels[tier])

    p7b <- ggplot(temp_sens, aes(x = citing_year, y = scr_any,
                                  colour = tier_label)) +
      geom_line(linewidth = 0.9) +
      geom_point(size = 1.5) +
      scale_colour_brewer(palette = "Set2", name = "Corpus tier") +
      scale_y_continuous(labels = scales::percent) +
      labs(
        title = "Endogeneity trends by corpus tier",
        caption = paste0("All = Exclusively + keyword-matched + Significantly DH journals\n",
                         "Core = Exclusively + keyword-matched journals\n",
                         "Exclusively = only Exclusively DH journals"),
        x = "Year",
        y = "SCR (any overlap)"
      ) +
      theme_minimal() +
      theme(
        plot.title = element_text(face = "bold", size = 12),
        plot.caption = element_text(size = 8, colour = "grey50", hjust = 0),
        legend.position = "bottom"
      )

    p7 <- p7a / p7b
  } else {
    p7 <- p7a
  }

  ggsave(file.path(OUTPUT_DIR, "fig7_sensitivity.png"),
         p7, width = 11, height = if (has_temp_sensitivity) 11 else 7,
         dpi = DPI, bg = "white")
  cat("  Saved fig7_sensitivity.png\n")
} else {
  cat("  SKIPPED: Not all sensitivity tiers available\n")
}

###############################################################################
# Summary
###############################################################################

cat("\n================================================================\n")
cat("   VISUALIZATION COMPLETE\n")
cat("================================================================\n")
cat("\nFigures saved to", OUTPUT_DIR, "/:\n")

fig_files <- list.files(OUTPUT_DIR, pattern = "^fig.*\\.png$", full.names = FALSE)
for (f in sort(fig_files)) {
  cat("  ", f, "\n")
}
cat("\nTotal:", length(fig_files), "figures\n")
