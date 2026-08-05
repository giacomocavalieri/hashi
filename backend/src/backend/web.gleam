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
  use <- style_500_page
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

const description = "Play a new Hashi puzzle every day!"

pub fn layout(body: List(Element(_))) -> String {
  html.html([attribute.lang("en")], [
    html.head([], [
      html.title([], "Hashi"),
      html.link([
        attribute.href("/static/styles-7.css"),
        attribute.rel("stylesheet"),
      ]),
      html.meta([attribute.name("description"), attribute.content(description)]),
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width, initial-scale=1"),
      ]),
      meta_og("og:title", "🏝️ Play Hashi"),
      meta_og("og:description", description),
      html.link([
        attribute.rel("icon"),
        attribute.href("/static/favicon.svg"),
      ]),
    ]),
    html.body([], body),
  ])
  |> element.to_document_string
}

fn meta_og(name: String, content: String) -> Element(_) {
  html.meta([
    attribute.attribute("property", name),
    attribute.content(content),
  ])
}

/// If there's a response with a 500 status code and an empty body we add a
/// default one.
///
/// TODO: This is probably a bit of an hack? Is there a better way?
fn style_500_page(value: fn() -> wisp.Response) -> wisp.Response {
  let response = value()
  case response.status == 500 {
    False -> response
    True ->
      // If the response has an unhelpful "Internal server error" text body we
      // replace it with something that has the same style as the rest of the
      // website.
      case wisp.Text("Internal server error") == response.body {
        False -> response
        True -> wisp.html_body(response, internal_server_error_page())
      }
  }
}

// SOME DEFAULT PAGES ----------------------------------------------------------
// I want 404 and 500 pages to be styled like the rest of the website, so here
// I define what they should look like.

pub fn not_found_page() -> String {
  layout([
    html.main([attribute.class("center stack")], [
      html.h1([], [html.text("🏝️ There's nothing here")]),
      html.a([attribute.class("button"), attribute.href("/")], [
        html.text("Go back to the daily puzzle"),
      ]),
    ]),
  ])
}

fn internal_server_error_page() -> String {
  layout([
    html.main([attribute.class("center stack")], [
      html.h1([], [html.text("⛴️ Something went wrong")]),
      html.p([], [
        html.text(
          "Try reloading the page in a little while, if the issue persists
           please report your problem describing what you were doing, I'll try
           and sort it out!",
        ),
      ]),
      html.a(
        [
          attribute.class("button"),
          attribute.href(
            "mailto:info@giacomocavalieri.me?subject=Daily hashi bug report",
          ),
        ],
        [
          html.text("Report a problem"),
        ],
      ),
    ]),
  ])
}
