###############################################################################
# Country → Region mapping utility
#
# Uses the countrycode package to add geographic groupings to data frames
# containing ISO alpha-2 country codes.
###############################################################################

library(countrycode)

#' Add region/continent columns to a data frame with country codes
#'
#' @param df A data frame
#' @param country_col Name of the column containing ISO alpha-2 codes (default: "citing_country")
#' @return The input data frame with added columns: continent, un_region, un_subregion, geo_group
add_region_data <- function(df, country_col = "citing_country") {
  df |>
    mutate(
      continent    = countrycode(.data[[country_col]], "iso2c", "continent",
                                  warn = FALSE),
      un_region    = countrycode(.data[[country_col]], "iso2c", "un.region.name",
                                  warn = FALSE),
      un_subregion = countrycode(.data[[country_col]], "iso2c", "un.regionsub.name",
                                  warn = FALSE),
      # Custom geographic grouping for heatmap/network visualisation
      geo_group = case_when(
        continent == "Europe" & un_subregion == "Western Europe"  ~ "W. Europe",
        continent == "Europe" & un_subregion == "Northern Europe" ~ "N. Europe",
        continent == "Europe" & un_subregion == "Southern Europe" ~ "S. Europe",
        continent == "Europe"                                     ~ "E. Europe",
        continent == "Americas" & .data[[country_col]] %in% c("US", "CA") ~ "N. America",
        continent == "Americas"                                   ~ "Latin America",
        continent == "Asia" & un_subregion == "Eastern Asia"      ~ "E. Asia",
        continent == "Asia" & un_subregion == "South-Eastern Asia"~ "SE Asia",
        continent == "Asia"                                       ~ "Other Asia",
        continent == "Oceania"                                    ~ "Oceania",
        continent == "Africa"                                     ~ "Africa",
        TRUE                                                      ~ "Other"
      )
    )
}
