# Surf spots used throughout the app.
#
# swell_dir : the swell direction (degrees, coming FROM) the break works best on
# wind_dir  : the wind direction (degrees, coming FROM) that is dead offshore
# best_min / best_max : the swell-height window (m) the spot is at its best in

spots <- data.frame(
  id        = c("muizenberg", "jbay", "bells", "pipeline", "uluwatu",
                "hossegor", "nazare", "mavericks", "snapper", "supertubos"),
  name      = c("Muizenberg", "Jeffreys Bay", "Bells Beach", "Pipeline", "Uluwatu",
                "Hossegor", "Nazaré", "Mavericks", "Snapper Rocks", "Supertubos"),
  country   = c("South Africa", "South Africa", "Australia", "Hawaii", "Indonesia",
                "France", "Portugal", "California", "Australia", "Portugal"),
  lat       = c(-34.108, -34.030, -38.370, 21.665, -8.829,
                43.660, 39.600, 37.495, -28.160, 39.350),
  lon       = c(18.473, 24.920, 144.280, -158.053, 115.085,
                -1.440, -9.080, -122.500, 153.550, -9.370),
  swell_dir = c(200, 225, 225, 315, 225, 270, 315, 300, 135, 300),
  wind_dir  = c(330, 270, 315, 60, 135, 90, 90, 90, 225, 45),
  best_min  = c(0.6, 1.2, 1.2, 1.8, 1.2, 0.9, 2.0, 3.0, 0.9, 1.0),
  best_max  = c(1.8, 3.0, 3.0, 4.5, 3.0, 2.5, 6.0, 8.0, 2.0, 2.5),
  stringsAsFactors = FALSE
)

spot_choices <- setNames(spots$id, paste0(spots$name, " (", spots$country, ")"))

get_spot <- function(id) spots[spots$id == id, , drop = FALSE]

# Compass label for a direction in degrees.
compass <- function(deg) {
  pts <- c("N", "NE", "E", "SE", "S", "SW", "W", "NW")
  pts[(round(deg / 45) %% 8) + 1]
}
