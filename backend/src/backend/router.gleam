import backend/daily_puzzle
import backend/web.{type Context}
import filepath
import frontend/hashi as hashi_frontend_app
import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import simplifile
import wisp.{type Request, type Response}

// TODO) add a route to get the raw data of the puzzle

pub fn handle_request(req: Request, context: Context) -> Response {
  use req <- web.middleware(req, context)
  case req.method, wisp.path_segments(req) {
    Get, [] -> daily_puzzle(req, context.cache)
    Post, [] -> save_time(req, context)
    _, _ -> wisp.not_found()
  }
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

  let assert Ok(hashi_frontend_app.Outcome(day:, seconds:)) =
    json.parse(body, hashi_frontend_app.outcome_decoder())

  let file_name =
    context.puzzles_folder
    |> filepath.join(daily_puzzle.file_name(for: day))

  let assert Ok(True) = simplifile.is_file(file_name)
  let assert Ok(_) =
    { int.to_string(seconds) <> "," }
    |> simplifile.append(to: file_name)

  wisp.ok()
}
