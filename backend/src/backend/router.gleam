import backend/daily_puzzle
import backend/web.{type Context}
import gleam/http.{Get}
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, context: Context) -> Response {
  use req <- web.middleware(req, context)
  case req.method, wisp.path_segments(req) {
    Get, [] -> daily_puzzle(req, context.cache)
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
