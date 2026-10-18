# Open-Meteo helpers. No API key needed.
#
# All functions are plain top-level functions, so shinyasync ships them to the
# mirai worker automatically. Everything inside uses package-qualified calls.
# `om_base` is not defined here: it is the request template that
# pool_async(everywhere = ) in app.R creates on every worker, so om_get() only
# works on the pool, through reactiveAsync(), observeAsync() or mirai_async().

om_get <- function(url, query) {
  resp <- om_base |>
    httr2::req_url(url) |>
    httr2::req_url_query(!!!query) |>
    httr2::req_perform()
  out <- httr2::resp_body_json(resp, simplifyVector = TRUE)
  if (isTRUE(out$error)) stop("Open-Meteo: ", out$reason)
  out
}

parse_time <- function(x, tz) as.POSIXct(x, format = "%Y-%m-%dT%H:%M", tz = tz)

# Hourly swell / wave / tide forecast.
fetch_marine <- function(lat, lon, days = 5, delay = 0) {
  if (delay > 0) Sys.sleep(delay)
  out <- om_get("https://marine-api.open-meteo.com/v1/marine", list(
    latitude = lat, longitude = lon, timezone = "auto", forecast_days = days,
    hourly = paste(c("wave_height", "wave_direction", "wave_period",
                     "swell_wave_height", "swell_wave_direction", "swell_wave_period",
                     "wind_wave_height", "sea_level_height_msl"), collapse = ",")
  ))
  h <- out$hourly
  data.frame(
    time         = parse_time(h$time, out$timezone),
    wave_height  = h$wave_height,
    wave_dir     = h$wave_direction,
    wave_period  = h$wave_period,
    swell_height = h$swell_wave_height,
    swell_dir    = h$swell_wave_direction,
    swell_period = h$swell_wave_period,
    windwave     = h$wind_wave_height,
    tide         = h$sea_level_height_msl,
    tz           = out$timezone,
    stringsAsFactors = FALSE
  )
}

# Hourly wind / air temperature forecast, plus sunrise and sunset.
fetch_wind <- function(lat, lon, days = 5, delay = 0) {
  if (delay > 0) Sys.sleep(delay)
  out <- om_get("https://api.open-meteo.com/v1/forecast", list(
    latitude = lat, longitude = lon, timezone = "auto", forecast_days = days,
    wind_speed_unit = "kn",
    hourly = "wind_speed_10m,wind_direction_10m,wind_gusts_10m,temperature_2m",
    daily  = "sunrise,sunset"
  ))
  h <- out$hourly
  hourly <- data.frame(
    time      = parse_time(h$time, out$timezone),
    wind_kn   = h$wind_speed_10m,
    wind_dir  = h$wind_direction_10m,
    gust_kn   = h$wind_gusts_10m,
    temp_c    = h$temperature_2m,
    stringsAsFactors = FALSE
  )
  sun <- data.frame(
    date    = as.Date(out$daily$time),
    sunrise = parse_time(out$daily$sunrise, out$timezone),
    sunset  = parse_time(out$daily$sunset, out$timezone)
  )
  # Mark daylight hours; surfing in the dark scores nothing.
  day_of <- as.Date(format(hourly$time, "%Y-%m-%d"))
  idx <- match(day_of, sun$date)
  hourly$daylight <- hourly$time >= sun$sunrise[idx] & hourly$time <= sun$sunset[idx]
  hourly$daylight[is.na(hourly$daylight)] <- FALSE
  list(hourly = hourly, sun = sun)
}

# Current conditions for the "right now" tile. Two small requests.
fetch_now <- function(lat, lon) {
  m <- om_get("https://marine-api.open-meteo.com/v1/marine", list(
    latitude = lat, longitude = lon, timezone = "auto",
    current = "wave_height,wave_direction,wave_period,swell_wave_height,swell_wave_period,sea_surface_temperature"
  ))
  w <- om_get("https://api.open-meteo.com/v1/forecast", list(
    latitude = lat, longitude = lon, timezone = "auto", wind_speed_unit = "kn",
    current = "wind_speed_10m,wind_direction_10m,wind_gusts_10m,temperature_2m"
  ))
  list(
    time        = parse_time(m$current$time, m$timezone),
    tz          = m$timezone,
    wave_height = m$current$wave_height,
    wave_dir    = m$current$wave_direction,
    period      = m$current$swell_wave_period,
    sst         = m$current$sea_surface_temperature,
    wind_kn     = w$current$wind_speed_10m,
    wind_dir    = w$current$wind_direction_10m,
    gust_kn     = w$current$wind_gusts_10m,
    temp_c      = w$current$temperature_2m,
    fetched_at  = Sys.time()
  )
}
