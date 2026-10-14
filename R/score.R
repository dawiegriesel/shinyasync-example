# A simple, transparent surf-quality model. Each component is in [0, 1] and the
# weighted sum is reported on a 0-10 scale.

# Smallest angle between two compass directions, in degrees.
angle_diff <- function(a, b) {
  d <- abs(a - b) %% 360
  pmin(d, 360 - d)
}

# Swell height: plateau at 1 inside the spot's best window, falling off outside.
height_score <- function(h, lo, hi) {
  below <- pmax(0, h / lo)
  above <- pmax(0, 1 - (h - hi) / hi)
  s <- ifelse(h < lo, below, ifelse(h > hi, above, 1))
  pmin(1, pmax(0, s))
}

# Period: anything under 6 s is wind slop, 15 s and above is long-range groundswell.
period_score <- function(p) pmin(1, pmax(0, (p - 6) / 9))

# Swell direction: 1 when dead on, 0 when 90 degrees or more off.
direction_score <- function(dir, ideal) pmax(0, cos(pmin(angle_diff(dir, ideal), 90) * pi / 180))

# Wind: light wind is good regardless of direction; otherwise offshore good,
# onshore bad, with strength making both effects larger.
wind_score <- function(kn, dir, offshore) {
  align    <- cos(angle_diff(dir, offshore) * pi / 180)      # 1 offshore, -1 onshore
  strength <- pmin(1, kn / 20)                               # 0 calm .. 1 at 20 kn+
  base     <- 0.75 + 0.25 * align * strength                 # 0.5 .. 1 in the 0..20 kn range
  base     <- ifelse(align < 0, base - 0.5 * strength, base) # onshore is punished harder
  base     <- base - 0.4 * pmax(0, (kn - 25) / 15)           # too much wind of any kind
  pmin(1, pmax(0, base))
}

# Combine the two hourly forecasts for one spot into a scored data frame.
score_hours <- function(marine, wind, spot) {
  w <- wind$hourly
  i <- match(marine$time, w$time)
  df <- data.frame(
    time         = marine$time,
    swell_height = marine$swell_height,
    swell_period = marine$swell_period,
    swell_dir    = marine$swell_dir,
    wave_height  = marine$wave_height,
    tide         = marine$tide,
    wind_kn      = w$wind_kn[i],
    wind_dir     = w$wind_dir[i],
    gust_kn      = w$gust_kn[i],
    daylight     = w$daylight[i]
  )
  df <- df[stats::complete.cases(df), ]
  df$s_height <- height_score(df$swell_height, spot$best_min, spot$best_max)
  df$s_period <- period_score(df$swell_period)
  df$s_dir    <- direction_score(df$swell_dir, spot$swell_dir)
  df$s_wind   <- wind_score(df$wind_kn, df$wind_dir, spot$wind_dir)
  df$score    <- combine_score(df$s_height, df$s_period, df$s_dir, df$s_wind)
  df$score[!df$daylight] <- NA          # no surfing in the dark
  df$wind_type <- wind_type(df$wind_dir, spot$wind_dir)
  df
}

# Weighted geometric mean: one weak component drags the whole score down,
# which is how surf works (perfect swell with howling onshore is still junk).
combine_score <- function(h, p, d, w) {
  10 * pmax(h, 0.02)^0.35 * pmax(p, 0.02)^0.3 * pmax(d, 0.02)^0.1 * pmax(w, 0.02)^0.25
}

wind_type <- function(dir, offshore) {
  d <- angle_diff(dir, offshore)
  factor(ifelse(d <= 45, "Offshore", ifelse(d >= 135, "Onshore", "Cross-shore")),
         levels = c("Offshore", "Cross-shore", "Onshore"))
}

rating <- function(score) {
  cut(score, c(-Inf, 2, 4, 6, 8, Inf),
      labels = c("Flat / blown out", "Poor", "Fair", "Good", "Epic"))
}

# Monte Carlo band around the score: forecasts are uncertain, so perturb the
# inputs n times and report the 10th / 50th / 90th percentile per hour. This is
# deliberately heavy (n x hours evaluations) so the async behaviour is visible.
simulate_scores <- function(scored, spot, n = 5000, delay = 0) {
  if (delay > 0) Sys.sleep(delay)
  H <- nrow(scored)
  draw <- function(x, sd_fun) x + stats::rnorm(H * n, 0, sd_fun(x))
  h  <- pmax(0, draw(scored$swell_height, function(x) 0.15 * x + 0.1))
  p  <- pmax(2, draw(scored$swell_period, function(x) 1.0))
  sd <- draw(scored$swell_dir, function(x) 15) %% 360
  wk <- pmax(0, draw(scored$wind_kn,     function(x) 4))
  wd <- draw(scored$wind_dir,            function(x) 25) %% 360
  s <- combine_score(height_score(h, spot$best_min, spot$best_max), period_score(p),
                     direction_score(sd, spot$swell_dir), wind_score(wk, wd, spot$wind_dir))
  s[rep(!scored$daylight, n)] <- NA
  m <- matrix(s, nrow = H)
  q <- apply(m, 1, stats::quantile, probs = c(0.1, 0.5, 0.9), names = FALSE, na.rm = TRUE)
  data.frame(time = scored$time, p10 = q[1, ], p50 = q[2, ], p90 = q[3, ],
             prob_good = rowMeans(m >= 6))
}

# Fetch + score every spot, used by the ranking task. Returns one row per spot.
rank_spots <- function(spots, days = 3) {
  rows <- lapply(seq_len(nrow(spots)), function(i) {
    sp <- spots[i, , drop = FALSE]
    sc <- score_hours(fetch_marine(sp$lat, sp$lon, days),
                      fetch_wind(sp$lat, sp$lon, days), sp)
    day <- sc[sc$daylight, ]
    data.frame(
      id = sp$id, name = sp$name, country = sp$country,
      mean_score = mean(day$score, na.rm = TRUE), best_score = max(day$score, na.rm = TRUE),
      best_time  = format(day$time[which.max(day$score)], "%a %H:%M"),
      swell_now  = sc$swell_height[1], period_now = sc$swell_period[1]
    )
  })
  out <- do.call(rbind, rows)
  out[order(-out$mean_score), ]
}
