import backend/daily_puzzle
import backend/web.{type Context}
import filepath
import frontend/daily_hashi as daily_hashi_app
import frontend/hashi_tutorial as hashi_tutorial_app
import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import lustre/attribute
import lustre/element/html
import simplifile
import wisp.{type Request, type Response}

// TODO:
// -[ ] add a route to get the raw data of the puzzle

const tutorial_cookie = "tutorial"

pub fn handle_request(req: Request, context: Context) -> Response {
  use req <- web.middleware(req, context)
  case req.method, wisp.path_segments(req) {
    // Someone's getting the daily puzzle, we check if they've done the tutorial
    // or send them to the tutorial page.
    Get, [] ->
      case wisp.get_cookie(req, tutorial_cookie, wisp.PlainText) {
        Error(_) -> wisp.redirect("/tutorial")
        Ok(_) ->
          daily_puzzle(req, context.cache)
          |> renew_tutorial_cookie(req)
      }

    // Someone has completed a puzzle and we store the time it took.
    Post, [] -> save_time(req, context)

    // The tutorial page.
    Get, ["tutorial"] -> tutorial()

    // Someone posts here when they've completed the tutorial. We set the cookie
    // and send them to the daily puzzle page.
    Post, ["tutorial"] ->
      wisp.redirect("/")
      |> renew_tutorial_cookie(req)

    // Don't know what happened here!
    _, _ ->
      wisp.not_found()
      |> wisp.html_body(web.not_found_page())
  }
}

fn renew_tutorial_cookie(response: Response, req: Request) -> Response {
  // We set the cookie for a year, if someone doesn't play for a year straight
  // we assume they forgot the rules.
  // I don't even know if this is gonna last a full year!
  wisp.set_cookie(
    response,
    req,
    tutorial_cookie,
    "completed :)",
    wisp.PlainText,
    60 * 60 * 24 * 30 * 12,
  )
}

fn tutorial() -> Response {
  // TODO) the tutorial is not cached I don't think that's ever gonna be a
  // problem but best keep an eye on it.

  web.layout([
    html.div([attribute.id("app")], [
      hashi_tutorial_app.view(hashi_tutorial_app.init(Nil).0),
    ]),
    // The lustre app bundled with the runtime that will take over the page
    // and allow to interact with it!
    html.script(
      [
        attribute.type_("module"),
        attribute.src("/static/generated/hashi_tutorial.js"),
      ],
      "",
    ),
  ])
  |> wisp.html_response(200)
}

/// The daily puzzle page is prerendered each day and served from an in-memory
/// cache. So there's not much work we have to do here!
pub fn daily_puzzle(_req: Request, cache: daily_puzzle.Cache) -> Response {
  case daily_puzzle.get_cached(cache) {
    Ok(page) -> wisp.html_response(page, 200)
    Error(_) -> wisp.internal_server_error()
  }
}

fn save_time(req: wisp.Request, context: Context) -> wisp.Response {
  use body <- wisp.require_string_body(req)

  // I'm being pretty liberal with the asserting, it's totally fine for such a
  // small app and any of these errors should only happen if someone is messing
  // with the API not using the client app.
  let assert Ok(daily_hashi_app.Outcome(day:, seconds:)) =
    json.parse(body, daily_hashi_app.outcome_decoder())

  let file_name =
    context.puzzles_folder
    |> filepath.join(daily_puzzle.file_name(for: day))

  let assert Ok(True) = simplifile.is_file(file_name)
  let assert Ok(_) =
    { int.to_string(seconds) <> "," }
    |> simplifile.append(to: file_name)

  wisp.ok()
}
