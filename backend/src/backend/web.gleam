import backend/daily_puzzle
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import wisp

pub type Context {
  Context(
    cache: daily_puzzle.Cache,
    puzzles_folder: String,
    static_assets_folder: String,
    server_url: String,
  )
}

pub fn middleware(
  req: wisp.Request,
  context: Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  let req = wisp.set_max_body_size(req, 100)
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

pub fn layout(body: List(Element(_))) -> String {
  html.html([attribute.lang("en")], [
    html.head([], [
      html.title([], "Hashi"),
      html.link([
        attribute.href("/static/styles-2.css"),
        attribute.rel("stylesheet"),
      ]),
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width, initial-scale=1"),
      ]),
      meta_og("og:title", "🏝️ Play Hashi"),
      meta_og("og:description", "Play a new Hashi puzzle every day!"),
    ]),
    html.body([], body),
  ])
  |> element.to_string
}

fn meta_og(name: String, content: String) -> Element(_) {
  html.meta([
    attribute.attribute("property", name),
    attribute.content(content),
  ])
}
