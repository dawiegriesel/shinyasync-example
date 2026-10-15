# Surf forecast dashboard: an example app for the shinyasync package.
#
# Every slow thing in this app (API calls, scoring, Monte Carlo simulation)
# runs on a mirai worker through shinyasync, so the UI never blocks and
# other users of the same process are never held up. The sidebar's task
# monitor shows every async task and what it is doing.
#
# Data: Open-Meteo marine + weather forecast APIs (free, no key).

library(shiny)
library(bslib)
library(shinyasync)
library(httr2)
library(plotly)

dir.create("cache", showWarnings = FALSE)
cache_dir <- normalizePath("cache")                      # plain object: shipped to workers

# ---- UI ---------------------------------------------------------------------

ui <- page_navbar(
  title = span(icon("water"), " Surf forecast"),
  theme = bs_theme(version = 5, preset = "shiny", primary = "#2a78d6"),
  fillable = FALSE,

  sidebar = sidebar(
    width = 320,
    selectInput("spot", "Spot", spot_choices, selected = "muizenberg"),
    sliderInput("days", "Forecast days", 2, 7, 4, step = 1),
    sliderInput("delay", "Simulated API latency (s)", 0, 5, 1.5, step = 0.5),
    helpText("Open-Meteo answers in ~100 ms. The latency slider slows the fetch",
             "so you can watch tasks run, cancel and supersede each other."),
    hr(),
    sliderInput("nsim", "Simulation draws", 1000, 50000, 10000, step = 1000),
    uiOutput("sim_buttons"),
    hr(),
    h6("Async task monitor"),
    uiOutput("monitor")
  ),

  nav_panel(
    "Forecast", icon = icon("chart-line"),
    layout_columns(
      col_widths = c(3, 3, 3, 3), fill = FALSE,
      value_box("Right now", uiOutput("now_main"), showcase = icon("wave-square"),
                uiOutput("now_sub"), theme = "primary"),
      value_box("Best session", textOutput("best_time"), showcase = icon("star"),
                textOutput("best_detail"), theme = "light"),
      value_box("Daylight hours ≥ 6", textOutput("good_hours"), showcase = icon("sun"),
                textOutput("good_detail"), theme = "light"),
      value_box("Fetched for", textOutput("fetched_spot"), showcase = icon("location-dot"),
                uiOutput("stale_note"), theme = "light")
    ),
    layout_columns(
      col_widths = c(8, 4),
      card(card_header("Surf score", uiOutput("score_status", inline = TRUE)),
           plotlyOutput("score_plot", height = 280)),
      card(card_header("Where"), plotlyOutput("map", height = 230))
    ),
    layout_columns(
      col_widths = c(6, 6),
      card(card_header("Swell, period and tide", uiOutput("marine_status", inline = TRUE)),
           plotlyOutput("swell_plot", height = 460)),
      card(card_header("Wind", uiOutput("wind_status", inline = TRUE)),
           plotlyOutput("wind_plot", height = 260),
           card_footer(class = "small text-muted",
                       "Bars are coloured by wind relative to the break: offshore grooms the",
                       "face, onshore crumbles it."),
           uiOutput("wind_summary"))
    )
  ),

  nav_panel(
    "Compare", icon = icon("scale-balanced"),
    p(class = "text-muted",
      "Two instances of the same module, each with its own async reactive returned",
      "to the parent. Change either spot and only that card refetches."),
    layout_columns(
      col_widths = c(6, 6),
      spotCardUI("a", "jbay"),
      spotCardUI("b", "uluwatu")
    ),
    card(card_header("Verdict"), uiOutput("verdict"))
  ),

  nav_panel(
    "Rank all spots", icon = icon("ranking-star"),
    layout_columns(
      col_widths = c(4, 8),
      card(
        card_header("Fan-out task"),
        p("Fetches and scores all", nrow(spots), "spots in one task started with",
          code("mirai_async()"), "and set on a", code("reactiveValAsync()"), "."),
        actionButton("rank", "Rank spots for the next 3 days", icon = icon("play"),
                     class = "btn-primary"),
        uiOutput("rank_status")
      ),
      card(card_header("Ranking"), plotlyOutput("rank_plot", height = 330),
           tableOutput("rank_table"))
    )
  ),

  nav_panel(
    "How it works", icon = icon("circle-info"),
    layout_columns(
      col_widths = c(7, 5),
      card(card_header("Moving parts"), uiOutput("howto")),
      card(card_header("Forecast cache written by observeAsync()"),
           p(class = "small text-muted", "Each time a spot is scored an observeAsync() writes",
             "the hourly table to disk from the worker. This table polls the directory."),
           tableOutput("cache_table"))
    ),
    card(card_header("Hourly table"), tableOutput("hourly_table"))
  )
)

# ---- Server -----------------------------------------------------------------

server <- function(input, output, session) {
  pool_async(workers = 4)              # optional: the first task would start a default
                                       # pool; this sizes it for every session in the process

  days <- reactive(input$days)

  # 1. Two independent fetches. Both start the moment the spot changes and run
  #    in parallel on different workers. Changing the spot again while they run
  #    cancels the in-flight requests (mode = "latest").
  marine <- reactiveAsync({
    sp <- get_spot(input$spot)
    fetch_marine(sp$lat, sp$lon, input$days, delay = input$delay)
  }, label = "marine")

  wind <- reactiveAsync({
    sp <- get_spot(input$spot)
    fetch_wind(sp$lat, sp$lon, input$days, delay = input$delay)
  }, label = "wind")

  # 2. A chained async reactive, written as a plain reactive() would be. While
  #    the fetches are catching up with a new spot it keeps the previous score
  #    rather than scoring one spot with another's wind, then re-runs once
  #    both have settled.
  scored <- reactiveAsync({
    sp <- get_spot(input$spot)
    s <- score_hours(marine(), wind(), sp)
    attr(s, "spot") <- sp$id
    s
  }, label = "score")

  # 3. Button-triggered heavy work with a cancel button. bindEvent() isolates
  #    everything inside, so only the button re-runs it.
  sim <- reactiveAsync({
    s <- simulate_scores(scored(), get_spot(input$spot), n = input$nsim, delay = input$delay)
    attr(s, "spot") <- input$spot
    s
  }, label = "sim") |> bindEvent(input$run_sim)

  observe(cancel_async(sim)) |> bindEvent(input$cancel_sim)

  # An async reactive starts its task the first time it is read, so something
  # must read it even before it has a value. Reading it while it has no value
  # halts like req(); catch that and treat it as "no band yet".
  sim_band <- reactive(tryCatch(sim(), shiny.silent.error = function(e) NULL))

  # 4. Background refresh: invalidateLater() runs on the session thread and
  #    re-runs the fetch every minute without blocking anything.
  now <- reactiveAsync({
    invalidateLater(60e3)
    sp <- get_spot(input$spot)
    fetch_now(sp$lat, sp$lon)
  }, label = "now")

  # 5. A side effect in a worker: write the scored forecast to the cache.
  cache_writer <- observeAsync({
    s <- scored()
    utils::write.csv(s, file.path(cache_dir, paste0(attr(s, "spot"), ".csv")),
                     row.names = FALSE)
  }, label = "cache")

  cache_files <- reactivePoll(
    1000, session,
    checkFunc = function() paste(file.info(list.files(cache_dir, full.names = TRUE))$mtime, collapse = ""),
    valueFunc = function() {
      f <- list.files(cache_dir, pattern = "\\.csv$", full.names = TRUE)
      if (!length(f)) return(data.frame(file = character(), rows = integer(), written = character()))
      data.frame(file = basename(f),
                 rows = vapply(f, function(x) length(readLines(x)) - 1L, integer(1)),
                 written = format(file.info(f)$mtime, "%H:%M:%S"), row.names = NULL)
    })

  # 6. Manual control: a reactiveValAsync() set from an observer. mirai_async()
  #    ships rank_spots() and every helper it calls, like reactiveAsync() does.
  ranking <- reactiveValAsync()
  observe({
    ranking(mirai_async(rank_spots(spots, days = 3)))
  }) |> bindEvent(input$rank)

  # 7. Modules, each returning its async reactive.
  card_a <- spotCardServer("a", days)
  card_b <- spotCardServer("b", days)

  # ---- Task monitor ---------------------------------------------------------
  output$monitor <- renderUI({
    rows <- list(
      c("marine fetch",      status_async(marine)),
      c("wind fetch",        status_async(wind)),
      c("score (chained)",   status_async(scored)),
      c("simulation (button)", status_async(sim)),
      c("right now (60 s)",  status_async(now)),
      c("cache observer",    cache_writer$status()),
      c("ranking (mirai)",   status_async(ranking)),
      c("compare card A",    status_async(card_a)),
      c("compare card B",    status_async(card_b))
    )
    tags$table(class = "table table-sm small mb-0",
      lapply(rows, function(r) tags$tr(tags$td(r[1]), tags$td(class = "text-end", status_badge(r[2])))))
  })

  output$sim_buttons <- renderUI({
    running <- status_async(sim) == "running"
    div(class = "d-grid gap-2",
        actionButton("run_sim", "Run uncertainty simulation", icon = icon("dice"),
                     class = "btn-primary", disabled = if (running) NA else NULL),
        actionButton("cancel_sim", "Cancel", icon = icon("ban"),
                     class = "btn-outline-danger", disabled = if (!running) NA else NULL))
  })

  # ---- Forecast tab ---------------------------------------------------------
  daylight <- reactive({ s <- scored(); s[s$daylight, ] })

  output$now_main <- renderUI({
    n <- now()
    HTML(sprintf("%.1f m @ %.0f s", n$wave_height, n$period))
  })
  output$now_sub <- renderUI({
    n <- now()
    tagList(
      sprintf("Wind %.0f kn %s, water %.0f°C, air %.0f°C", n$wind_kn, compass(n$wind_dir), n$sst, n$temp_c),
      tags$br(),
      span(class = "small", "refreshed ", format(n$fetched_at, "%H:%M:%S"), " · auto every 60 s")
    )
  })

  output$best_time   <- renderText({ d <- daylight(); format(d$time[which.max(d$score)], "%a %d %b, %H:%M") })
  output$best_detail <- renderText({
    d <- daylight(); i <- which.max(d$score)
    sprintf("%.1f / 10 · %s · %.1f m @ %.0f s · wind %.0f kn %s",
            d$score[i], rating(d$score[i]), d$swell_height[i], d$swell_period[i],
            d$wind_kn[i], tolower(as.character(d$wind_type[i])))
  })
  output$good_hours  <- renderText(sum(daylight()$score >= 6))
  output$good_detail <- renderText(sprintf("of %d daylight hours in the next %d days",
                                           nrow(daylight()), input$days))
  output$fetched_spot <- renderText(get_spot(attr(scored(), "spot"))$name)
  output$stale_note <- renderUI({
    if (status_async(marine) == "running" || status_async(wind) == "running")
      span(class = "text-warning", icon("clock"), " showing previous forecast while the new one loads")
    else span(class = "small", "forecast tz: ", marine()$tz[1])
  })

  output$score_status  <- renderUI(status_badge(status_async(scored)))
  output$marine_status <- renderUI(status_badge(status_async(marine)))
  output$wind_status   <- renderUI(status_badge(status_async(wind)))

  output$score_plot <- renderPlotly({
    s <- scored()
    b <- sim_band()
    band <- if (!is.null(b) && identical(attr(b, "spot"), attr(s, "spot"))) b
    plot_score(s, wind()$sun, band)
  })
  output$swell_plot <- renderPlotly(plot_swell(scored(), wind()$sun))
  output$wind_plot  <- renderPlotly(plot_wind(scored(), wind()$sun))
  output$wind_summary <- renderUI({
    d <- daylight()
    tab <- table(d$wind_type)
    div(class = "px-3 pb-2 small text-muted",
        sprintf("Daylight hours: %d offshore, %d cross-shore, %d onshore.",
                tab[["Offshore"]], tab[["Cross-shore"]], tab[["Onshore"]]))
  })
  output$map <- renderPlotly(plot_map(spots, input$spot))

  # ---- Compare tab ----------------------------------------------------------
  output$verdict <- renderUI({
    a <- card_a(); b <- card_b()
    ma <- mean(a$score, na.rm = TRUE); mb <- mean(b$score, na.rm = TRUE)
    na <- get_spot(attr(a, "spot"))$name      # tagged in the module, so it never names a spot
    nb <- get_spot(attr(b, "spot"))$name      # whose numbers are not on screen yet
    winner <- if (ma >= mb) na else nb
    tagList(
      h4(sprintf("Go to %s", winner)),
      p(sprintf("%s averages %.1f, %s averages %.1f over daylight hours. ", na, ma, nb, mb),
        "Both numbers come from async reactives returned by the module servers.")
    )
  })

  # ---- Rank tab -------------------------------------------------------------
  output$rank_status <- renderUI({
    s <- status_async(ranking)
    div(class = "mt-3", status_badge(s),
        if (s == "running") span(class = "small text-muted ms-2",
                                 sprintf("%d spots x 2 requests on one worker, 10-20 s", nrow(spots))))
  })
  output$rank_plot  <- renderPlotly({
    validate(need(!is.null(ranking()), "Press the button to rank the spots."))
    plot_ranking(ranking())
  })
  output$rank_table <- renderTable({
    r <- ranking()
    req(r)
    data.frame(Spot = r$name, Country = r$country, `Mean score` = round(r$mean_score, 1),
               `Best hour` = r$best_time, `Peak score` = round(r$best_score, 1),
               `Swell now (m)` = r$swell_now, `Period (s)` = r$period_now,
               check.names = FALSE)
  }, striped = TRUE, spacing = "xs", width = "100%")

  # ---- How it works tab -----------------------------------------------------
  output$cache_table  <- renderTable(cache_files(), striped = TRUE, spacing = "xs", width = "100%")
  output$hourly_table <- renderTable({
    s <- scored()
    s <- s[s$daylight, ]
    data.frame(Time = format(s$time, "%a %H:%M"),
               `Swell (m)` = s$swell_height, `Period (s)` = s$swell_period,
               Swell = compass(s$swell_dir), `Wind (kn)` = s$wind_kn,
               Wind = paste(compass(s$wind_dir), s$wind_type), `Tide (m)` = s$tide,
               Score = round(s$score, 1), Rating = as.character(rating(s$score)),
               check.names = FALSE)
  }, striped = TRUE, spacing = "xs", width = "100%")

  output$howto <- renderUI(tagList(
    tags$dl(class = "row",
      tags$dt(class = "col-sm-4", code("reactiveAsync()"), " × 2"),
      tags$dd(class = "col-sm-8", "Marine and wind fetches. Independent, so they run on two workers at once. Change the spot mid-flight and the old requests are cancelled."),
      tags$dt(class = "col-sm-4", "Chained ", code("reactiveAsync()")),
      tags$dd(class = "col-sm-8", "The score reads both fetches as a plain reactive() would. shinyasync keeps the previous score while the fetches catch up with a new spot, then re-runs it."),
      tags$dt(class = "col-sm-4", code("bindEvent()"), " + ", code("cancel_async()")),
      tags$dd(class = "col-sm-8", "The Monte Carlo simulation only runs on the button. Cancel stops the worker and keeps the last band."),
      tags$dt(class = "col-sm-4", code("invalidateLater()")),
      tags$dd(class = "col-sm-8", "The 'right now' tile refetches every 60 s in the background."),
      tags$dt(class = "col-sm-4", code("observeAsync()")),
      tags$dd(class = "col-sm-8", "Writes each scored forecast to the cache directory from the worker; nothing reads its result."),
      tags$dt(class = "col-sm-4", code("reactiveValAsync()")),
      tags$dd(class = "col-sm-8", "The ranking is a mirai_async() task set on an async reactive value. Pressing the button again supersedes a running one."),
      tags$dt(class = "col-sm-4", "Modules"),
      tags$dd(class = "col-sm-8", "The Compare tab mounts one module twice; each returns its async reactive to the parent."),
      tags$dt(class = "col-sm-4", code("status_async()")),
      tags$dd(class = "col-sm-8", "Drives every badge, the task monitor, the disabled buttons and the 'stale' note."),
      tags$dt(class = "col-sm-4", code("pool_async()")),
      tags$dd(class = "col-sm-8", "Optional: the first task would start a default pool. This app sizes it to four local daemons shared by every session of this process. Open the app in a second tab: it is never blocked by the first.")
    )
  ))
}

shinyApp(ui, server)
