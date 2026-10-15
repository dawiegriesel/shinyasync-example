# shinyasync example: surf forecast

A Shiny dashboard that pulls swell, wind and tide forecasts for ten surf spots
from [Open-Meteo](https://open-meteo.com/) (free, no key), scores every
daylight hour, and lets you run a Monte Carlo band around the score. Every slow
step runs on a `mirai` worker through
[shinyasync](https://github.com/dawiegriesel/shinyasync), so the UI never
blocks and a second browser tab is never held up by the first.

The point of the app is to exercise every primitive the package exports, with
enough moving parts that you can watch them run, cancel and supersede each
other in the sidebar's task monitor.

## Run it

```r
renv::restore()
shiny::runApp()
```

Set the "Simulated API latency" slider above zero: Open-Meteo answers in about
100 ms, which is too fast to see anything happen.

## What each part demonstrates

| Where | Primitive | What to watch |
|---|---|---|
| Forecast tab, swell and wind cards | `reactiveAsync()` x 2 | Two independent fetches start together on two workers. Change the spot while they run: the old requests are cancelled, the badges go orange, and the previous forecast stays on screen with a "showing previous forecast" note. |
| Surf score card | chained `reactiveAsync()` | Reads both fetches as a plain `reactive()` would. It halts until both have a value, and keeps the previous score while the fetches catch up with a new spot. |
| Sidebar simulation buttons | `bindEvent()` + `cancel_async()` | The Monte Carlo band only runs on the button. Cancel stops the worker and keeps the last band. Buttons enable and disable from `status_async()`. |
| "Right now" tile | `invalidateLater()` inside an async | Refetches current conditions every 60 s in the background. |
| How it works tab, cache table | `observeAsync()` | Writes each scored forecast to `cache/` from the worker. A `reactivePoll()` lists the files. |
| Rank all spots tab | `reactiveValAsync()` set from `mirai_async()` | Fetches and scores all ten spots in one worker. `mirai_async()` ships `rank_spots()` and every helper it calls, so nothing is listed by hand. |
| Compare tab | modules | One module mounted twice, each returning its async reactive to the parent, which combines them in the verdict. |
| Sidebar task monitor | `status_async()` and `$status()` | Live status of every task in the app. |
| `server()` | `pool_async(workers = 4)` | Optional: the first task would start a default pool. This call sizes it for every session in the process. |

## Lessons learned building this

- **An async reactive starts its task the first time it is read.** The trigger
  observer is created suspended. A pattern like "only read `sim()` once
  `status_async(sim) == "success"`" therefore never starts the task. Read it
  unconditionally and catch the `shiny.silent.error` halt when there is no
  value yet (see `sim_band` in `app.R`).
- **Chains need no guard.** With stale-while-revalidate an upstream returns its
  previous value while it recomputes, but a downstream `reactiveAsync()` waits
  for it to catch up with its own inputs, so the score never pairs a new spot
  with the old spot's wind. Tagging a result with `attr(s, "spot")` is still
  useful for outputs that combine results from different tasks, as the
  simulation band and the compare verdict do.
- **Use `mirai_async()` for a raw task.** A bare `mirai::mirai()` ships only
  what you hand it; `mirai_async()` ships the helpers an expression calls,
  as `reactiveAsync()` does.

## Files

- `app.R`: UI and server.
- `R/spots.R`: the spot table with each break's ideal swell and wind direction.
- `R/api.R`: Open-Meteo marine and weather calls.
- `R/score.R`: the scoring model, the Monte Carlo simulation and the ranking.
- `R/charts.R`: plotly helpers.
- `R/mod_spot_card.R`: the comparison module and the status badge.
