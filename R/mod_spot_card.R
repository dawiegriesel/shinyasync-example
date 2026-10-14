# A self-contained "spot card" module: picks a spot, fetches and scores it in a
# worker, and returns the async reactive to the caller so the parent can compare
# two cards. Nothing inside is special; reactiveAsync() captures the namespaced
# `input` like any other reactive.

spotCardUI <- function(id, default) {
  ns <- NS(id)
  bslib::card(
    bslib::card_header(
      div(class = "d-flex justify-content-between align-items-center",
          selectInput(ns("spot"), NULL, spot_choices, selected = default, width = "70%"),
          uiOutput(ns("status"), inline = TRUE))
    ),
    bslib::layout_columns(
      col_widths = c(4, 4, 4),
      bslib::value_box("Mean score", textOutput(ns("mean")), theme = "light"),
      bslib::value_box("Best session", textOutput(ns("best")), theme = "light"),
      bslib::value_box("Hours ≥ 6", textOutput(ns("good")), theme = "light")
    ),
    plotly::plotlyOutput(ns("plot"), height = 220)
  )
}

spotCardServer <- function(id, days) {
  moduleServer(id, function(input, output, session) {

    scored <- reactiveAsync({
      sp <- get_spot(input$spot)                       # literal read, captured
      s <- score_hours(fetch_marine(sp$lat, sp$lon, days()),
                       fetch_wind(sp$lat, sp$lon, days()), sp)
      attr(s, "spot") <- sp$id
      s
    }, label = paste0("card:", id))

    day <- reactive({ s <- scored(); s[s$daylight, ] })

    output$status <- renderUI(status_badge(status_async(scored)))
    output$mean   <- renderText(sprintf("%.1f", mean(day()$score, na.rm = TRUE)))
    output$best   <- renderText({
      d <- day(); format(d$time[which.max(d$score)], "%a %H:%M")
    })
    output$good   <- renderText(sum(day()$score >= 6))
    output$plot   <- plotly::renderPlotly({
      s <- scored()
      plotly::plot_ly(s, x = ~time, y = ~score, height = 220) |>
        plotly::add_lines(name = "score", line = list(color = pal$aqua, width = 2),
                          connectgaps = FALSE) |>
        base_layout(showlegend = FALSE, margin = list(l = 32, r = 8, t = 8, b = 36),
                    yaxis = axis(range = c(0, 10.5), title = ""))
    })

    scored
  })
}

# Shared little badge for task status.
status_badge <- function(s) {
  cls <- switch(s, running = "warning", success = "success", error = "danger", "secondary")
  ic <- switch(s, running = shiny::icon("spinner", class = "fa-spin"), success = shiny::icon("check"),
               error = shiny::icon("triangle-exclamation"), shiny::icon("pause"))
  span(class = paste0("badge rounded-pill text-bg-", cls), ic, " ", s)
}
