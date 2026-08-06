import frontend/hashi_grid
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/calendar.{type Date}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import rsvp
import shared/hashi.{type Bridge, type InvalidSolution, type Puzzle}
import shared/schedule

pub fn main() {
  let app = lustre.application(init, update, view)

  // The app expects the puzzle data to be in a `<script>` with id "#app-data",
  // it will read it and parse it to a puzzle.
  // If it's wrong I've really messed up something, so I just crash.
  let assert Ok(#(puzzle_day, puzzle, server_url)) =
    read_app_json_data("app-data")
    |> json.parse(daily_puzzle_decoder())

  let current_time = timestamp.system_time()
  let state = case load_saved_state() {
    Ok(SaveState(puzzle_day: saved_puzzle_day, elapsed_time:, connections:))
      if saved_puzzle_day == puzzle_day
    ->
      InitState(
        server_url:,
        puzzle_day:,
        puzzle:,
        connections:,
        elapsed_time:,
        current_time:,
      )

    Ok(_) | Error(_) ->
      InitState(
        server_url:,
        puzzle_day:,
        puzzle:,
        connections: dict.new(),
        elapsed_time: duration.seconds(0),
        current_time:,
      )
  }

  let assert Ok(_) = lustre.start(app, "#app", state)
}

@external(javascript, "./hashi_ffi.mjs", "read_app_json_data")
fn read_app_json_data(id: String) -> String

fn load_saved_state() -> Result(SaveState, Nil) {
  let string = read_local_storage(save_state_local_storage_key)
  json.parse(string, save_state_decoder())
  |> result.replace_error(Nil)
}

// MODEL -----------------------------------------------------------------------

pub type Model {
  Model(
    /// Who we should send the outcome to once we're done
    server_url: String,
    /// The day of the puzzle we're solving.
    puzzle_day: Date,
    /// If the user has recently shared their outcome, this will be set to
    /// `Some` with the medium with which the outcome was shared.
    share: Option(ShareMedium),
    /// The time we spent solving the puzzle.
    elapsed_time: Duration,
    current_time: Timestamp,
    grid: hashi_grid.Model,
  )
}

pub type ShareMedium {
  Clipboard
  RichShare
}

pub type Solution {
  Solution(
    /// This tells us what the outcome of the solution is.
    /// If it's `Ok(Nil)` the game has been solved.
    outcome: Result(Nil, InvalidSolution),
    /// For each island, this tells us which islands are connected to it and
    /// with what kind of bridge.
    connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
    /// A set of cells taken by a bridge.
    /// We need this to quickly be able to check if a cell is taken.
    bridges: Set(#(Int, Int)),
  )
}

pub fn init(state: InitState) -> #(Model, Effect(Message)) {
  let model = init_model(state)
  let effect = tick_timer()
  #(model, effect)
}

pub fn init_model(state: InitState) -> Model {
  let InitState(
    server_url: server_url,
    puzzle:,
    puzzle_day:,
    connections:,
    elapsed_time:,
    current_time:,
  ) = state

  Model(
    server_url:,
    puzzle_day:,
    elapsed_time:,
    current_time:,
    share: None,
    grid: hashi_grid.init(hashi_grid.InitState(puzzle:, connections:)),
  )
}

// INITIAL STATE ---------------------------------------------------------------
// This is the data that we will need to create a puzzle.
// When the app starts it somehow needs to know what puzzle, and for what day
// we're playing. That information is embedded in the page by the server.
// We're gonna parse it and use it as the starting point to `init` the model.

pub type InitState {
  InitState(
    server_url: String,
    puzzle_day: Date,
    puzzle: Puzzle,
    connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
    elapsed_time: Duration,
    current_time: Timestamp,
  )
}

pub fn daily_puzzle_to_json(day: Date, puzzle: Puzzle, server: String) -> Json {
  json.object([
    #("puzzle_day", date_to_json(day)),
    #("puzzle", hashi.to_json(puzzle)),
    #("server", json.string(server)),
  ])
}

pub fn daily_puzzle_decoder() -> Decoder(#(Date, Puzzle, String)) {
  use date <- decode.field("puzzle_day", date_decoder())
  use puzzle <- decode.field("puzzle", hashi.decoder())
  use server <- decode.field("server", decode.string)
  decode.success(#(date, puzzle, server))
}

fn date_to_json(day: Date) -> Json {
  let calendar.Date(year:, month:, day:) = day
  json.preprocessed_array([
    json.int(year),
    json.int(calendar.month_to_int(month)),
    json.int(day),
  ])
}

fn date_decoder() -> Decoder(Date) {
  use year <- decode.field(0, decode.int)
  use month <- decode.field(1, {
    use month <- decode.then(decode.int)
    case calendar.month_from_int(month) {
      Ok(month) -> decode.success(month)
      Error(_) -> decode.failure(calendar.October, "Month")
    }
  })
  use day <- decode.field(2, decode.int)
  decode.success(calendar.Date(year:, month:, day:))
}

// SAVE STATE ------------------------------------------------------------------
// As the game is played we save its state to localstorage so we can resume the
// game. We only store the bare minimum that we need, that is the connections
// that were drawn by the user, the day of the puzzle (to check if we can load
// this, or it is for a past day), and what the start and end time are.
//
// So this is not totally equivalent to the initial state we'll need to start
// the app. There we will need more info: like where each island is, and what
// the bridges in the canonical solution are.
//
// So to avoid doing extra work we do not collapse the two data structures into
// one, but keep them separate!

/// This represents the data that is saved as we progress through the game, and
/// that can be used to resume a game that was interrupted.
type SaveState {
  SaveState(
    /// The day of the puzzle this save state refers to.
    /// We need this to make sure we're loading the state for the correct
    /// puzzle!
    puzzle_day: Date,
    /// How long we've spent solving the puzzle so far.
    elapsed_time: Duration,
    /// The connections drawn by the user so far.
    connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
  )
}

fn save_state_to_json(save_state: SaveState) -> Json {
  let SaveState(puzzle_day:, elapsed_time:, connections:) = save_state

  json.object([
    #("puzzle_day", date_to_json(puzzle_day)),
    #("elapsed_time", duration_to_json(elapsed_time)),
    #("connections", hashi.connections_to_json(connections)),
  ])
}

fn save_state_decoder() -> Decoder(SaveState) {
  use puzzle_day <- decode.field("puzzle_day", date_decoder())
  use elapsed_time <- decode.field("elapsed_time", duration_decoder())
  use connections <- decode.field("connections", hashi.connections_decoder())
  decode.success(SaveState(puzzle_day:, elapsed_time:, connections:))
}

fn duration_to_json(duration: Duration) -> Json {
  let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(duration)
  json.preprocessed_array([
    json.int(seconds),
    json.int(nanoseconds),
  ])
}

fn duration_decoder() -> Decoder(Duration) {
  use seconds <- decode.field(0, decode.int)
  use nanoseconds <- decode.field(1, decode.int)
  duration.seconds(seconds)
  |> duration.add(duration.nanoseconds(nanoseconds))
  |> decode.success
}

// OUTCOME ---------------------------------------------------------------------
// Whever the puzzle is completed we send the outcome to the server, this is
// a representation of the data sent to the server.

pub type Outcome {
  Outcome(
    /// The day of the puzzle that has been solved.
    day: Date,
    /// How many seconds it took to solve the puzzle.
    seconds: Int,
  )
}

fn outcome_to_json(outcome: Outcome) -> Json {
  let Outcome(day:, seconds:) = outcome
  json.object([
    #("day", date_to_json(day)),
    #("seconds", json.int(seconds)),
  ])
}

pub fn outcome_decoder() -> Decoder(Outcome) {
  use day <- decode.field("day", date_decoder())
  use seconds <- decode.field("seconds", seconds_decoder())
  decode.success(Outcome(day:, seconds:))
}

fn seconds_decoder() -> Decoder(Int) {
  use seconds <- decode.then(decode.int)
  case seconds > 0 {
    True -> decode.success(seconds)
    False -> decode.failure(1, "PositiveInt")
  }
}

// UPDATE ----------------------------------------------------------------------

pub type Message {
  TimerTicked(previous_tick: Timestamp, current_time: Timestamp)
  UserClickedUndo
  UserClickedRedo

  UserClickedShare
  UserSharedOutcome(medium: ShareMedium)
  ShareTimerExpired

  RsvpPostedOutcome

  GridProducedMessage(hashi_grid.Message)
  UserClickedDeleteAllBridges
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    RsvpPostedOutcome -> {
      let effect = effect.none()
      #(model, effect)
    }

    TimerTicked(previous_tick:, current_time:) ->
      case hashi_grid.is_complete(model.grid) {
        // If the game is not over we need to update the elapsed time and save
        // the state.
        False -> {
          let elapsed_time =
            model.elapsed_time
            |> duration.add(timestamp.difference(previous_tick, current_time))
          let model = Model(..model, elapsed_time:, current_time:)
          let effect = effect.batch([save_state(model), tick_timer()])
          #(model, effect)
        }
        // Otherwise we just update the current time with its new value.
        True -> {
          let model = Model(..model, current_time:)
          let effect = tick_timer()
          #(model, effect)
        }
      }

    UserClickedShare -> {
      let effect = share_outcome(model)
      #(model, effect)
    }
    UserSharedOutcome(medium) -> {
      let model = Model(..model, share: Some(medium))
      let effect = after(1000, fn() { ShareTimerExpired })
      #(model, effect)
    }
    ShareTimerExpired -> {
      let model = Model(..model, share: None)
      let effect = effect.none()
      #(model, effect)
    }

    UserClickedUndo -> {
      use <- skip_if_complete(model)
      let model = Model(..model, grid: hashi_grid.step_back(model.grid))
      let effect = save_state(model)
      #(model, effect)
    }
    UserClickedRedo -> {
      use <- skip_if_complete(model)
      let model = Model(..model, grid: hashi_grid.step_forward(model.grid))
      let effect = save_state(model)
      #(model, effect)
    }
    UserClickedDeleteAllBridges -> {
      use <- skip_if_complete(model)
      let model =
        Model(..model, grid: hashi_grid.delete_all_bridges(model.grid))
      let effect = save_state(model)
      #(model, effect)
    }
    GridProducedMessage(message) -> {
      use <- skip_if_complete(model)
      let #(grid, effect) = hashi_grid.update(model.grid, message)
      let model = Model(..model, grid:)
      let effect = effect.map(effect, GridProducedMessage)
      let other_effects = case message {
        hashi_grid.PointerMoved(..)
        | hashi_grid.PointerEnteredIsland(..)
        | hashi_grid.PointerLeftIsland -> []

        hashi_grid.UserPressedOnIsland(..)
        | hashi_grid.UserStoppedPressing(..)
        | hashi_grid.UserClickedBridge(..) ->
          case hashi_grid.is_complete(model.grid) {
            True -> [save_state(model), send_outcome_to_server(model)]
            False -> [save_state(model)]
          }
      }

      let effect = effect.batch([effect, ..other_effects])
      #(model, effect)
    }
  }
}

fn skip_if_complete(
  model: Model,
  run: fn() -> #(Model, Effect(Message)),
) -> #(Model, Effect(Message)) {
  case hashi_grid.is_complete(model.grid) {
    True -> #(model, effect.none())
    False -> run()
  }
}

// EFFECTS ---------------------------------------------------------------------

fn after(
  milliseconds: Int,
  dispatch message: fn() -> message,
) -> Effect(message) {
  use dispatch <- effect.from
  use <- do_after(milliseconds)
  dispatch(message())
}

@external(javascript, "./hashi_ffi.mjs", "do_after")
fn do_after(milliseconds: Int, value: fn() -> Nil) -> Nil

const timer_interval_ms = 1000

fn tick_timer() -> Effect(Message) {
  use dispatch <- effect.from
  let previous_tick = timestamp.system_time()
  use <- do_after(timer_interval_ms)
  let current_time = timestamp.system_time()
  dispatch(TimerTicked(previous_tick:, current_time:))
}

fn share_outcome(model: Model) -> Effect(Message) {
  use dispatch <- effect.from

  let elapsed = pretty_elapsed_time(model)
  let title = "🏝️ Hashi - " <> pretty_date(model.puzzle_day)
  do_share(
    title:,
    message: title
      <> "\nSolved in "
      <> elapsed
      <> "\nPlay at "
      <> model.server_url,
    on_share: fn(copied_to_clipboard) {
      case copied_to_clipboard {
        True -> dispatch(UserSharedOutcome(Clipboard))
        False -> dispatch(UserSharedOutcome(RichShare))
      }
    },
  )
}

@external(javascript, "./hashi_ffi.mjs", "do_share")
fn do_share(
  title title: String,
  message message: String,
  // The boolean is `True` if the data was shared as text to the clipboard.
  // `False` if it was shared with the share API.
  on_share run: fn(Bool) -> Nil,
) -> Nil

const save_state_local_storage_key = "save"

/// This save the current solution to localstore so that a game can be resumed
/// upon loading the page.
fn save_state(model: Model) -> Effect(Message) {
  use _dispatch <- effect.from

  SaveState(
    puzzle_day: model.puzzle_day,
    connections: hashi_grid.current_solution(model.grid).connections,
    elapsed_time: model.elapsed_time,
  )
  |> save_state_to_json
  |> json.to_string
  |> write_local_storage(save_state_local_storage_key, _)
}

@external(javascript, "./hashi_ffi.mjs", "write_local_storage")
fn write_local_storage(key: String, value: String) -> Nil

@external(javascript, "./hashi_ffi.mjs", "read_local_storage")
fn read_local_storage(key: String) -> String

fn send_outcome_to_server(model: Model) -> Effect(Message) {
  let outcome =
    Outcome(
      day: model.puzzle_day,
      seconds: model.elapsed_time
        |> duration.to_seconds
        |> float.round,
    )

  rsvp.post(
    model.server_url,
    outcome_to_json(outcome),
    rsvp.expect_ok_response(fn(_reply) { RsvpPostedOutcome }),
  )
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Message) {
  html.main([attribute.class("center stack")], [
    html.div([attribute.class("center")], [
      html.h1([], [html.text("🏝️ Hashi")]),
      html.h2([], [html.text(pretty_date(model.puzzle_day))]),
    ]),
    hashi_grid.view(model.grid)
      |> element.map(GridProducedMessage),
    case hashi_grid.current_solution(model.grid).outcome {
      Ok(_) | Error(hashi.IslandsHaveWrongBridges(..)) -> element.none()
      Error(hashi.DisjointGroups(_)) ->
        html.p([], [
          html.text(
            "This is not a valid solution, there is a group of islands that is not connected to all the other ones.",
          ),
        ])
    },
    button_controls(model),
  ])
}

fn button_controls(model: Model) -> Element(Message) {
  let time = html.p([], [html.text(pretty_elapsed_time(model))])
  case hashi_grid.is_complete(model.grid) {
    False -> {
      let undo =
        html.button(
          [
            event.on_click(UserClickedUndo),
            attribute.disabled(!hashi_grid.can_step_back(model.grid)),
          ],
          [html.text("undo")],
        )
      let redo =
        html.button(
          [
            event.on_click(UserClickedRedo),
            attribute.disabled(!hashi_grid.can_step_forward(model.grid)),
          ],
          [html.text("redo")],
        )
      let delete_all_bridges =
        html.button(
          [
            event.on_click(UserClickedDeleteAllBridges),
            attribute.disabled(!hashi_grid.has_bridges(model.grid)),
          ],
          [html.text("Delete all bridges")],
        )

      html.div([attribute.class("center stack-s")], [
        html.div([attribute.class("button-group")], [
          undo,
          time,
          redo,
        ]),
        delete_all_bridges,
      ])
    }
    True -> {
      let #(attributes, text) = case model.share {
        Some(Clipboard) -> #([attribute.class("success")], "copied!")
        Some(RichShare) -> #([attribute.class("success")], "shared!")
        None -> #([event.on_click(UserClickedShare)], "Share")
      }
      let share =
        html.button([attribute.class("share"), ..attributes], [html.text(text)])
      html.div([attribute.class("center stack-s")], [
        html.div([attribute.class("button-group")], [time, share]),
        html.p([], [html.text(pretty_missing_time(model))]),
      ])
    }
  }
}

fn pretty_missing_time(model: Model) -> String {
  let next_time = schedule.next_puzzle_time(model.puzzle_day)
  let missing = timestamp.difference(model.current_time, next_time)
  let missing = duration.to_seconds(missing) |> float.round

  let ready_message = "The next puzzle is ready, refresh the page!"
  use <- bool.guard(when: missing <= 1, return: ready_message)

  let hours = missing / 60 / 60
  let minutes = { missing - hours * 60 * 60 } / 60
  let seconds = missing - hours * 60 * 60 - minutes * 60

  let hours = int.to_string(hours) |> string.pad_start(to: 2, with: "0")
  let minutes = int.to_string(minutes) |> string.pad_start(to: 2, with: "0")
  let seconds = int.to_string(seconds) |> string.pad_start(to: 2, with: "0")
  "Next puzzle in: " <> hours <> ":" <> minutes <> ":" <> seconds
}

fn pretty_elapsed_time(model: Model) -> String {
  let elapsed_seconds =
    model.elapsed_time
    |> duration.to_seconds
    |> float.round

  let elapsed_minutes = elapsed_seconds / 60
  let elapsed_seconds = elapsed_seconds - elapsed_minutes * 60

  let elapsed_minutes =
    int.to_string(elapsed_minutes) |> string.pad_start(with: "0", to: 2)
  let elapsed_seconds =
    int.to_string(elapsed_seconds) |> string.pad_start(with: "0", to: 2)

  elapsed_minutes <> ":" <> elapsed_seconds
}

fn pretty_date(date: Date) -> String {
  let calendar.Date(year:, month:, day:) = date

  let year =
    int.to_string(year)
    |> string.pad_start(to: 4, with: "0")

  let month =
    calendar.month_to_int(month)
    |> int.to_string
    |> string.pad_start(to: 2, with: "0")

  let day =
    int.to_string(day)
    |> string.pad_start(to: 2, with: "0")

  year <> "-" <> month <> "-" <> day
}
