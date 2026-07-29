import backend/daily_puzzle
import wisp

pub type Context {
  Context(
    cache: daily_puzzle.Cache,
    puzzles_folder: String,
    static_assets_folder: String,
  )
}

pub fn middleware(
  req: wisp.Request,
  context: Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)
  use <- wisp.serve_static(
    req,
    under: "/static",
    from: context.static_assets_folder,
  )
  handle_request(req)
}
