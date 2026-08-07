import backend/daily_puzzle
import backend/router
import backend/web.{type Context}
import envoy
import filepath
import frontend/daily_hashi as daily_hashi_app
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/time/calendar.{type Date}
import gleam/time/duration
import gleam/time/timestamp
import lustre/attribute
import lustre/element/html
import mist
import shared/hashi
import shared/schedule
import simplifile
import wisp
import wisp/wisp_mist

pub fn main() {
  process.sleep_forever()
}

/// The Erlang/OTP application start callback.
/// Responsible to start the "top" supervisor process and return its Pid
/// to the application controller.
pub fn start(
  _app: atom.Atom,
  _arguments,
) -> Result(process.Pid, actor.StartError) {
  case static_supervisor.start(supervised()) {
    Error(reason) -> Error(reason)
    Ok(actor.Started(pid, _data)) -> {
      let _ = process.register(pid, process.new_name("hashi_server"))
      Ok(pid)
    }
  }
}

/// The Erlang/OTP application stop callback.
/// This is called after all processes in the supervisor tree have
/// been shutdown by the application controller. Responsible for any
/// final clean up actions.
pub fn stop(_state: a) -> atom.Atom {
  atom.create("ok")
}

fn supervised() -> static_supervisor.Builder {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(puzzles_folder) = envoy.get("PUZZLES_FOLDER")
  let assert Ok(server_url) = envoy.get("SERVER_URL")
  let assert Ok(port) = envoy.get("PORT") |> result.try(int.parse)

  wisp.log_info("🏝️ Starting the Hashi service")
  wisp.log_info("We will point outcome solutions to " <> server_url)

  let assert Ok(priv_folder) = wisp.priv_directory("backend")
  let static_assets_folder = filepath.join(priv_folder, "static")
  let context =
    web.Context(
      cache: daily_puzzle.new_cache(),
      puzzles_folder:,
      static_assets_folder:,
      server_url:,
    )

  let server_spec =
    router.handle_request(_, context)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.supervised

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(daily_generator_spec(context))
  |> static_supervisor.add(server_spec)
}

fn daily_generator_spec(context: Context) {
  use <- supervision.worker
  actor.new_with_initialiser(100, fn(me) {
    process.send(me, Nil)
    Ok(actor.initialised(me))
  })
  |> actor.on_message(fn(me, _msg) {
    // First we get today's date and generate a puzzle.
    let today = schedule.today()
    cache_puzzle(today, context)

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

/// This caches the puzzle for the given day, if the puzzle has a file already
/// it will be generated using the options in that file. Otherwise it will be
/// generated using the default options for the day.
fn cache_puzzle(today: Date, context: Context) -> Nil {
  let puzzle = generate_puzzle(today, context)

  // Finally, after generating the puzzle, we prerender the page we'll be
  // serving and save that in the cache. So from now on all requests to the
  // server will serve this new page!
  let page = puzzle_to_page(today, puzzle, context.server_url)
  daily_puzzle.replace_cached(context.cache, page)
  Nil
}

/// Given a date this generates a puzzle for the given day by either using the
/// default options for the day, or reading the options that already exist at
/// the default puzzle's path where its options can be found.
///
/// The option file is created if it doesn't exist!
fn generate_puzzle(today: Date, context: Context) -> hashi.Puzzle {
  let puzzle_path =
    filepath.join(context.puzzles_folder, daily_puzzle.file_name(for: today))

  case simplifile.read(puzzle_path) {
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
      hashi.generate(options)
    }

    // On the other hand, if no puzzle file exists we just generate one from
    // scratch using a default set of parameters and save the file ourselves.
    Error(_) -> {
      // We turn today's date into a seed so that the puzzle for each day is
      // unique! The seed is the number YYYYMMDD.
      let seed =
        today.year
        * 10_000
        + calendar.month_to_int(today.month)
        * 100
        + today.day

      let options =
        daily_puzzle.default_options(for: today)
        |> hashi.with_seed(seed)

      let puzzle = hashi.generate(options)

      let assert Ok(_) =
        daily_puzzle.serialise_options(options)
        |> simplifile.write(to: puzzle_path)

      puzzle
    }
  }
}

fn puzzle_to_page(
  puzzle_day: Date,
  puzzle: hashi.Puzzle,
  server_url: String,
) -> String {
  // We create an initial dummy state to prerender the grid so that we don't see
  // the page flashing as the lustre app starts.
  let initial_state =
    daily_hashi_app.init_model(daily_hashi_app.InitState(
      connections: dict.new(),
      elapsed_time: duration.seconds(0),
      current_time: timestamp.system_time(),
      puzzle_day:,
      puzzle:,
      server_url:,
    ))

  web.layout([
    html.div([attribute.id("app")], [
      daily_hashi_app.view(initial_state),
    ]),
    html.script(
      [attribute.type_("application/hashi"), attribute.id("app-data")],
      daily_hashi_app.daily_puzzle_to_json(puzzle_day, puzzle, server_url)
        |> json.to_string,
    ),
    // The lustre app bundled with the runtime that will take over the page
    // and allow to interact with it!
    html.script(
      [
        attribute.type_("module"),
        attribute.src("/static/generated/daily_hashi.js"),
      ],
      "",
    ),
  ])
}
