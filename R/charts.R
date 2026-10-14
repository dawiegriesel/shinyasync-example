# Plotly helpers. One colour per job: blue for swell, orange for wind,
# aqua for the surf score, grey for context. Never two y-axes on one plot.

pal <- list(blue = "#2a78d6", orange = "#eb6834", aqua = "#1baf7a",
            yellow = "#eda100", grey = "#9a9893", grid = "#ebeae6",
            text = "#52514e", ink = "#0b0b0b")

axis <- function(...) utils::modifyList(list(gridcolor = pal$grid, zeroline = FALSE, fixedrange = TRUE), list(...))

base_layout <- function(p, ...) {
  defaults <- list(
    paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
    font = list(family = "system-ui, -apple-system, Segoe UI, sans-serif",
                color = pal$text, size = 12),
    margin = list(l = 48, r = 16, t = 32, b = 40),
    hovermode = "x unified",
    xaxis = axis(title = ""),
    yaxis = axis(),
    legend = list(orientation = "h", y = 1.12, x = 0)
  )
  args <- utils::modifyList(defaults, list(...))
  do.call(plotly::layout, c(list(p), args)) |>
    plotly::config(displayModeBar = FALSE)
}

# Shaded night bands from sunrise/sunset so the daylight-only scoring is obvious.
night_shapes <- function(sun, lim) {
  shapes <- list()
  for (i in seq_len(nrow(sun))) {
    if (i > 1) {
      shapes[[length(shapes) + 1]] <- list(
        type = "rect", xref = "x", yref = "paper", layer = "below",
        x0 = sun$sunset[i - 1], x1 = sun$sunrise[i], y0 = 0, y1 = 1,
        fillcolor = "rgba(82,81,78,0.07)", line = list(width = 0))
    }
  }
  shapes
}

plot_swell <- function(df, sun) {
  p1 <- plotly::plot_ly(df, x = ~time, height = 460) |>
    plotly::add_lines(y = ~wave_height, name = "Total wave height (m)",
                      line = list(color = pal$grey, width = 1.5, dash = "dot")) |>
    plotly::add_lines(y = ~swell_height, name = "Swell height (m)",
                      line = list(color = pal$blue, width = 2), fill = "tozeroy",
                      fillcolor = "rgba(42,120,214,0.12)")
  p2 <- plotly::plot_ly(df, x = ~time) |>
    plotly::add_lines(y = ~swell_period, name = "Swell period (s)",
                      line = list(color = pal$blue, width = 2))
  p3 <- plotly::plot_ly(df, x = ~time) |>
    plotly::add_lines(y = ~tide, name = "Tide (m, MSL)",
                      line = list(color = pal$grey, width = 2))
  plotly::subplot(p1, p2, p3, nrows = 3, shareX = TRUE, titleY = FALSE,
                  heights = c(0.45, 0.3, 0.25)) |>
    base_layout(shapes = night_shapes(sun),
                yaxis  = axis(title = "height (m)", rangemode = "tozero"),
                yaxis2 = axis(title = "period (s)", rangemode = "tozero"),
                yaxis3 = axis(title = "tide (m)"))
}

plot_wind <- function(df, sun) {
  cols <- c(Offshore = pal$aqua, `Cross-shore` = pal$grey, Onshore = pal$orange)
  plotly::plot_ly(df, x = ~time, height = 260) |>
    plotly::add_bars(y = ~wind_kn, color = ~wind_type, colors = cols,
                     text = ~paste0(compass(wind_dir), " ", round(wind_dir), "°"),
                     hovertemplate = "%{y:.0f} kn %{text}<extra>%{fullData.name}</extra>",
                     marker = list(line = list(width = 0))) |>
    plotly::add_lines(y = ~gust_kn, name = "Gusts (kn)",
                      line = list(color = pal$grey, width = 1, dash = "dot")) |>
    base_layout(shapes = night_shapes(sun), bargap = 0.25,
                yaxis = axis(title = "knots", rangemode = "tozero"))
}

plot_score <- function(df, sun, sim = NULL) {
  p <- plotly::plot_ly(height = 280)
  if (!is.null(sim)) {
    p <- p |>
      plotly::add_ribbons(data = sim, x = ~time, ymin = ~p10, ymax = ~p90,
                          name = "Simulated 10-90% band",
                          line = list(width = 0), fillcolor = "rgba(27,175,122,0.18)")
  }
  p |>
    plotly::add_lines(data = df, x = ~time, y = ~score, name = "Surf score (0-10)",
                      line = list(color = pal$aqua, width = 2.5),
                      hovertemplate = "%{y:.1f}<extra>score</extra>") |>
    base_layout(shapes = c(night_shapes(sun), list(
                  list(type = "line", xref = "paper", x0 = 0, x1 = 1, y0 = 6, y1 = 6,
                       line = list(color = pal$grey, width = 1, dash = "dash")))),
                yaxis = axis(title = "score", range = c(0, 10.5)),
                annotations = list(list(x = 1, xref = "paper", y = 6, text = "Good",
                                        showarrow = FALSE, xanchor = "right",
                                        yanchor = "bottom", font = list(color = pal$grey))))
}

plot_map <- function(spots, selected) {
  spots$sel <- spots$id == selected
  plotly::plot_geo(spots, lat = ~lat, lon = ~lon, height = 230) |>
    plotly::add_markers(text = ~paste0(name, ", ", country), hoverinfo = "text",
                        marker = list(size = ~ifelse(sel, 14, 8),
                                      color = ~ifelse(sel, pal$orange, pal$blue),
                                      line = list(color = "white", width = 2))) |>
    plotly::layout(geo = list(showland = TRUE, landcolor = "#f1f0ec",
                              showocean = TRUE, oceancolor = "#e3eef9",
                              showcountries = FALSE, showcoastlines = TRUE,
                              coastlinecolor = "#c9c8c2", projection = list(type = "natural earth"),
                              bgcolor = "rgba(0,0,0,0)"),
                   margin = list(l = 0, r = 0, t = 0, b = 0),
                   paper_bgcolor = "rgba(0,0,0,0)") |>
    plotly::config(displayModeBar = FALSE)
}

plot_ranking <- function(rk) {
  rk$label <- factor(rk$name, levels = rev(rk$name))
  plotly::plot_ly(rk, y = ~label, x = ~mean_score, type = "bar", orientation = "h", height = 330,
                  marker = list(color = pal$aqua),
                  text = ~sprintf("%.1f", mean_score), textposition = "outside",
                  hovertemplate = "%{y}: %{x:.2f}<extra></extra>") |>
    base_layout(hovermode = "y",
                xaxis = axis(title = "mean daylight score, next 3 days", range = c(0, 10)),
                yaxis = axis(title = ""),
                margin = list(l = 110, r = 30, t = 10, b = 40))
}
