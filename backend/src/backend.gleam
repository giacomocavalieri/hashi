import backend/daily_puzzle
import backend/router
import backend/web
import filepath
import frontend/hashi as hashi_frontend_app
import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/time/calendar.{type Date}
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import mist
import shared/hashi
import shared/schedule
import simplifile
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(priv_folder) = wisp.priv_directory("backend")
  let puzzles_folder = filepath.join(priv_folder, "puzzles")
  let static_assets_folder = filepath.join(priv_folder, "static")
  let context =
    web.Context(
      cache: daily_puzzle.new_cache(),
      puzzles_folder:,
      static_assets_folder:,
    )

  let server_spec =
    router.handle_request(_, context)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(1236)
    |> mist.supervised

  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(daily_generator_spec(context))
    |> static_supervisor.add(server_spec)
    |> static_supervisor.start

  process.sleep_forever()
}

fn daily_generator_spec(context: web.Context) {
  // We use the Italian offset so it's the most comfortable to me :)
  // We will generate the puzzle at 8:00 in the morning.
  let web.Context(cache:, puzzles_folder:, ..) = context

  use <- supervision.worker
  actor.new_with_initialiser(100, fn(me) {
    process.send(me, Nil)
    Ok(actor.initialised(me))
  })
  |> actor.on_message(fn(me, _msg) {
    // First we get today's date and generate a puzzle.
    let today = schedule.today()
    generate_puzzle(today, puzzles_folder, cache)

    // Then we figure out how long we have to sleep before waking up again.
    // We want to generate the puzzle at a fixed time of the next day!
    schedule.next_puzzle_time(today)
    |> timestamp.difference(timestamp.system_time(), _)
    |> duration.to_milliseconds
    |> process.send_after(me, _, Nil)

    actor.continue(me)
  })
  |> actor.start
}

fn generate_puzzle(
  today: Date,
  puzzle_folder: String,
  cache: daily_puzzle.Cache,
) -> Nil {
  let puzzle_path =
    filepath.join(puzzle_folder, daily_puzzle.file_name(for: today))

  // We turn today's date into a seed so that the puzzle for each day is unique!
  // The seed is the number YYYYMMDD.
  let seed =
    today.year * 1000 + calendar.month_to_int(today.month) * 100 + today.day

  let puzzle = case simplifile.read_bits(puzzle_path) {
    // We start by checking if a file for the puzzle already exists.
    // That can happen in two cases:
    //   1. the puzzle for today had already been generated, for some reason I
    //      had to restart the server. So now we've gotta populate the cache
    //      back using the same parameters that were used the first time.
    //   2. I decided to override the parameters for the puzzle and added the
    //      file myself, for example I might want to up the difficulty on
    //      special days, etc.
    // Either way we generate it from those existing options!
    Ok(file_content) -> {
      let assert Ok(options) = daily_puzzle.parse_options(file_content)
      let options = hashi.with_seed(options, seed)
      hashi.generate(options)
    }

    // On the other hand, if no puzzle file exists we just generate one from
    // scratch using a default set of parameters and save the file ourselves.
    Error(_) -> {
      let options =
        daily_puzzle.default_options(for: today)
        |> hashi.with_seed(seed)
      let puzzle = hashi.generate(options)

      let assert Ok(_) =
        daily_puzzle.serialise_options(options)
        |> simplifile.write_bits(to: puzzle_path)

      puzzle
    }
  }

  // Finally, after generating the puzzle, we prerender the page we'll be
  // serving and save that in the cache. So from now on all requests to the
  // server will serve this new page!
  let page = puzzle_to_page(today, puzzle)
  daily_puzzle.replace_cached(cache, page)
  Nil
}

fn puzzle_to_page(puzzle_day: Date, puzzle: hashi.Puzzle) -> String {
  // We create an initial dummy state to prerender the grid so that we don't see
  // the page flashing as the lustre app starts.
  let initial_state =
    hashi_frontend_app.init_model(hashi_frontend_app.InitState(
      connections: dict.new(),
      elapsed_time: duration.seconds(0),
      current_time: timestamp.system_time(),
      puzzle_day:,
      puzzle:,
    ))

  html.html([attribute.lang("en")], [
    html.head([], [
      html.title([], "Hashi"),
      html.link([
        attribute.href("/static/styles.css"),
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
    html.body([], [
      html.div([attribute.id("app")], [
        hashi_frontend_app.view(initial_state),
      ]),
      html.script(
        [attribute.type_("application/hashi"), attribute.id("app-data")],
        hashi_frontend_app.daily_puzzle_to_json(puzzle_day, puzzle)
          |> json.to_string,
      ),
      // The lustre app bundled with the runtime that will take over the page
      // and allow to interact with it!
      html.script(
        [attribute.type_("text/javascript"), attribute.src("/static/hashi.js")],
        "",
      ),
    ]),
  ])
  |> element.to_string
}

fn meta_og(name: String, content: String) -> Element(_) {
  html.meta([
    attribute.attribute("property", name),
    attribute.content(content),
  ])
}
