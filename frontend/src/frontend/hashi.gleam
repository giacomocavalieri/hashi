import frontend/history.{type History}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
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
import hashi.{type Bridge, type InvalidSolution, type Puzzle}
import lustre
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event

pub fn main() {
  let app = lustre.application(init, update, view)

  // The app expects the puzzle data to be in a `<script>` with id "#app-data",
  // it will read it and parse it to a puzzle.
  // If it's wrong I've really messed up something, so I just crash.
  let assert Ok(#(puzzle_day, puzzle)) =
    read_app_json_data("app-data")
    |> json.parse(daily_puzzle_decoder())

  let state = case load_saved_state() {
    Ok(SaveState(puzzle_day: saved_puzzle_day, elapsed_time:, connections:))
      if saved_puzzle_day == puzzle_day
    -> InitState(puzzle_day:, puzzle:, connections:, elapsed_time:)

    Ok(_) | Error(_) ->
      InitState(
        puzzle_day:,
        puzzle:,
        connections: dict.new(),
        elapsed_time: duration.seconds(0),
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
    puzzle_day: Date,
    /// The puzzle we're currently trying to solve.
    puzzle: Puzzle,
    /// We keep track of all the moves of a user so we can easily undo/redo
    solutions: History(Solution),
    /// If the user has recently shared their outcome, this will be set to
    /// `Some` with the medium with which the outcome was shared.
    share: Option(ShareMedium),
    /// The position of the cursor, in the coordinate space of the svg grid
    /// holding the puzzle.
    cursor: #(Int, Int),
    /// The time we spent solving the puzzle.
    elapsed_time: Duration,
    /// When drawing a bridge from one island to another, this contains the
    /// coordinates of the starting island.
    start_island: Option(#(Int, Int)),
    /// When drawing a bridge from one island to another, this contains the
    /// coordinates of the destination island.
    target_island: Option(#(Int, Int)),
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
  let InitState(puzzle:, puzzle_day:, connections:, elapsed_time:) = state
  let outcome = hashi.check(puzzle, connections)
  Model(
    puzzle_day:,
    cursor: #(0, 0),
    puzzle:,
    elapsed_time:,
    start_island: None,
    target_island: None,
    share: None,
    solutions: history.new(
      Solution(outcome:, connections:, bridges: {
        use cells, start, connections <- dict.fold(connections, set.new())
        use cells, end, _bridge <- dict.fold(connections, cells)
        add_bridge_cells(cells, start, end)
      }),
    ),
  )
}

fn connect_islands(
  model: Model,
  one: #(Int, Int),
  other: #(Int, Int),
  bridge: Bridge,
) -> Model {
  let solution = history.current(model.solutions)
  let connections =
    solution.connections
    |> dict.upsert(one, insert_or_create(_, other, bridge))
    |> dict.upsert(other, insert_or_create(_, one, bridge))
  let outcome = hashi.check(model.puzzle, connections)
  let bridges = add_bridge_cells(solution.bridges, one, other)
  let new_solution = Solution(outcome:, connections:, bridges:)
  Model(..model, solutions: history.push(model.solutions, new_solution))
}

fn add_bridge_cells(
  bridges: Set(#(Int, Int)),
  one: #(Int, Int),
  other: #(Int, Int),
) -> Set(#(Int, Int)) {
  let #(x, y) = one
  let #(other_x, other_y) = other

  case Nil {
    _ if x == other_x ->
      int.range(y, other_y, bridges, fn(bridges, y) {
        set.insert(bridges, #(x, y))
      })
    _ if y == other_y ->
      int.range(x, other_x, bridges, fn(bridges, x) {
        set.insert(bridges, #(x, y))
      })
    _ -> bridges
  }
}

fn disconnect_islands(
  model: Model,
  one: #(Int, Int),
  other: #(Int, Int),
) -> Model {
  let #(x, y) = one
  let #(other_x, other_y) = other

  let solution = history.current(model.solutions)
  let connections =
    solution.connections
    |> dict.upsert(one, try_delete(_, other))
    |> dict.upsert(other, try_delete(_, one))
  let outcome = hashi.check(model.puzzle, connections)
  let bridges = case Nil {
    _ if x == other_x ->
      int.range(y, other_y, solution.bridges, fn(bridges, y) {
        set.delete(bridges, #(x, y))
      })
    _ if y == other_y ->
      int.range(x, other_x, solution.bridges, fn(bridges, x) {
        set.delete(bridges, #(x, y))
      })
    _ -> solution.bridges
  }
  let new_solution = Solution(outcome:, connections:, bridges:)
  Model(..model, solutions: history.push(model.solutions, new_solution))
}

/// If the two points can be connected, this will return the kind of bridge to
/// use to connect the two islands.
fn can_connect(
  model: Model,
  point: #(Int, Int),
  to selected: #(Int, Int),
) -> Result(Bridge, Nil) {
  // The islands must be orthogonal
  let #(x, y) = selected
  let #(other_x, other_y) = point

  use <- bool.guard(when: selected == point, return: Error(Nil))

  let solution = history.current(model.solutions)
  let bridge = {
    use connections <- result.try(dict.get(solution.connections, point))
    use bridge <- result.try(dict.get(connections, selected))
    Ok(bridge)
  }

  case bridge {
    Ok(hashi.Double) -> Error(Nil)
    Ok(hashi.Single) -> Ok(hashi.Double)
    Error(_) ->
      case Nil {
        _ if x == other_x -> {
          let can_connect =
            range_all(from: y, to: other_y, satisfy: fn(y) {
              { #(x, y) == selected || #(x, y) == point }
              || {
                !hashi.has_island(model.puzzle, #(x, y))
                && !set.contains(solution.bridges, #(x, y))
              }
            })

          case can_connect {
            True -> Ok(hashi.Single)
            False -> Error(Nil)
          }
        }

        _ if y == other_y -> {
          let can_connect =
            range_all(from: x, to: other_x, satisfy: fn(x) {
              { #(x, y) == selected || #(x, y) == point }
              || !hashi.has_island(model.puzzle, #(x, y))
              && !set.contains(solution.bridges, #(x, y))
            })

          case can_connect {
            True -> Ok(hashi.Single)
            False -> Error(Nil)
          }
        }

        _ -> Error(Nil)
      }
  }
}

fn is_complete(model: Model) -> Bool {
  history.current(model.solutions).outcome == Ok(Nil)
}

// INITIAL STATE ---------------------------------------------------------------
// This is the data that we will need to create a puzzle.
// When the app starts it somehow needs to know what puzzle, and for what day
// we're playing. That information is embedded in the page by the server.
// We're gonna parse it and use it as the starting point to `init` the model.

pub type InitState {
  InitState(
    puzzle_day: Date,
    puzzle: Puzzle,
    connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
    elapsed_time: Duration,
  )
}

pub fn daily_puzzle_to_json(day: Date, puzzle: Puzzle) -> Json {
  json.object([
    #("puzzle_day", date_to_json(day)),
    #("puzzle", hashi.to_json(puzzle)),
  ])
}

pub fn daily_puzzle_decoder() -> Decoder(#(Date, Puzzle)) {
  use date <- decode.field("puzzle_day", date_decoder())
  use puzzle <- decode.field("puzzle", hashi.decoder())
  decode.success(#(date, puzzle))
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
  let connections = dict.from_list(connections)
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

// UPDATE ----------------------------------------------------------------------

pub type Message {
  UserPressedOnIsland(point: #(Int, Int))
  UserStoppedPressing

  /// This catches all "pointermove" events that happen on the hashi grid.
  /// This is needed to check which island we're hovering, and where (relative
  /// to the grid) the cursor is.
  /// To find the hovered island, and where the cursor is over the grid the
  /// event will need to be handled in an effect that can read the DOM, so this
  /// just wraps the event object to be handled in JavaScript land.
  UserMovedPointerOverGrid(event: Dynamic)
  PointerEnteredIsland(point: #(Int, Int))
  PointerLeftIsland
  PointerMovedToPoint(point: #(Int, Int))

  UserClickedBridge(between: #(Int, Int), and: #(Int, Int))

  TimerTicked(previous_tick: Timestamp, current_time: Timestamp)
  UserClickedUndo
  UserClickedRedo

  UserClickedShare
  UserSharedOutcome(medium: ShareMedium)
  ShareTimerExpired
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    UserClickedBridge(between: one, and: other) -> {
      use <- skip_if_complete(model)
      let model = disconnect_islands(model, one, other)
      let effect = save_state(model)
      #(model, effect)
    }

    UserPressedOnIsland(point:) -> {
      use <- skip_if_complete(model)
      let model = Model(..model, start_island: Some(point))
      let effect = effect.none()
      #(model, effect)
    }

    UserStoppedPressing -> {
      use <- skip_if_complete(model)
      case model.start_island, model.target_island {
        None, _ | _, None -> {
          let model = Model(..model, start_island: None, target_island: None)
          let effect = effect.none()
          #(model, effect)
        }

        Some(start), Some(end) ->
          case can_connect(model, start, end) {
            Ok(bridge) -> {
              let model = connect_islands(model, start, end, bridge)
              let model =
                Model(..model, start_island: None, target_island: None)
              let effect = save_state(model)
              #(model, effect)
            }
            Error(_) -> {
              let model =
                Model(..model, start_island: None, target_island: None)
              let effect = effect.none()
              #(model, effect)
            }
          }
      }
    }

    PointerEnteredIsland(island) -> {
      use <- skip_if_complete(model)
      let model = case model.start_island {
        Some(_) -> Model(..model, target_island: Some(island))
        None -> model
      }
      let effect = effect.none()
      #(model, effect)
    }

    PointerLeftIsland -> {
      use <- skip_if_complete(model)
      let model = Model(..model, target_island: None)
      let effect = effect.none()
      #(model, effect)
    }

    UserMovedPointerOverGrid(event:) -> {
      use <- skip_if_complete(model)
      let effect = handle_moved_pointer_event(event)
      #(model, effect)
    }

    PointerMovedToPoint(point:) -> {
      use <- skip_if_complete(model)
      let model = Model(..model, cursor: point)
      let effect = effect.none()
      #(model, effect)
    }

    TimerTicked(previous_tick:, current_time:) -> {
      use <- skip_if_complete(model)
      let elapsed_time =
        model.elapsed_time
        |> duration.add(timestamp.difference(previous_tick, current_time))
      let model = Model(..model, elapsed_time:)
      let effect = effect.batch([save_state(model), tick_timer()])
      #(model, effect)
    }

    UserClickedUndo -> {
      use <- skip_if_complete(model)
      let model = Model(..model, solutions: history.step_back(model.solutions))
      let effect = save_state(model)
      #(model, effect)
    }

    UserClickedRedo -> {
      use <- skip_if_complete(model)
      let model =
        Model(..model, solutions: history.step_forward(model.solutions))
      let effect = save_state(model)
      #(model, effect)
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
  }
}

fn skip_if_complete(
  model: Model,
  run: fn() -> #(Model, Effect(Message)),
) -> #(Model, Effect(Message)) {
  case is_complete(model) {
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

const timer_interval_ms = 1000

fn tick_timer() -> Effect(Message) {
  use dispatch <- effect.from
  let previous_tick = timestamp.system_time()
  use <- do_after(timer_interval_ms)
  let current_time = timestamp.system_time()
  dispatch(TimerTicked(previous_tick:, current_time:))
}

@external(javascript, "./hashi_ffi.mjs", "do_after")
fn do_after(milliseconds: Int, value: fn() -> Nil) -> Nil

fn handle_moved_pointer_event(event: Dynamic) -> Effect(Message) {
  use dispatch <- effect.from
  do_handle_moved_pointer_event(
    event,
    on_island_enter: fn(island) { dispatch(PointerEnteredIsland(island)) },
    on_island_exit: fn() { dispatch(PointerLeftIsland) },
    on_point: fn(point) { dispatch(PointerMovedToPoint(point)) },
  )
}

@external(javascript, "./hashi_ffi.mjs", "do_handle_moved_pointer_event")
fn do_handle_moved_pointer_event(
  event: Dynamic,
  on_island_enter on_island_enter: fn(#(Int, Int)) -> Nil,
  on_island_exit on_island_exit: fn() -> Nil,
  on_point on_point: fn(#(Int, Int)) -> Nil,
) -> Nil

fn share_outcome(model: Model) -> Effect(Message) {
  use dispatch <- effect.from

  let elapsed = pretty_elapsed_time(model)
  let title = "🏝️ Hashi - " <> pretty_date(model.puzzle_day)
  do_share(
    title:,
    message: title
      <> "\nSolved in "
      <> elapsed
      <> "\nPlay at hashi.giacomocavalieri.me",
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
    connections: history.current(model.solutions).connections,
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

// VIEW ------------------------------------------------------------------------

const radius = 10

const stroke_width = 2

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

pub fn view(model: Model) -> Element(Message) {
  html.main([attribute.class("center-stack")], [
    html.h1([], [html.text("Hashi " <> pretty_date(model.puzzle_day))]),
    hashi_grid(model),
    button_controls(model),
  ])
}

fn button_controls(model: Model) -> Element(Message) {
  let undo = case is_complete(model) {
    True -> element.none()
    False ->
      html.button(
        [
          event.on_click(UserClickedUndo),
          attribute.disabled(!history.can_step_back(model.solutions)),
        ],
        [html.text("undo")],
      )
  }

  let redo = case is_complete(model) {
    True -> element.none()
    False ->
      html.button(
        [
          event.on_click(UserClickedRedo),
          attribute.disabled(!history.can_step_forward(model.solutions)),
        ],
        [html.text("redo")],
      )
  }

  let share = case is_complete(model) {
    False -> element.none()
    True -> {
      let #(attributes, text) = case model.share {
        Some(Clipboard) -> #([attribute.class("success")], "copied!")
        Some(RichShare) -> #([attribute.class("success")], "shared!")
        None -> #([event.on_click(UserClickedShare)], "share")
      }
      html.button([attribute.class("share"), ..attributes], [html.text(text)])
    }
  }

  html.div([attribute.class("button-group")], [
    undo,
    html.h2([], [html.text(pretty_elapsed_time(model))]),
    redo,
    share,
  ])
}

fn hashi_grid(model: Model) -> Element(Message) {
  let width = hashi.width(model.puzzle)
  let height = hashi.height(model.puzzle)

  let islands = {
    use islands, y <- int.range(from: 0, to: height, with: [])
    use islands, x <- int.range(from: 0, to: width, with: islands)
    [view_island(model, #(x, y)), ..islands]
  }

  let islands_hitboxes = {
    use islands, y <- int.range(from: 0, to: height, with: [])
    use islands, x <- int.range(from: 0, to: width, with: islands)
    case hashi.has_island(model.puzzle, #(x, y)) {
      True -> [view_island_hitbox(#(x, y)), ..islands]
      False -> islands
    }
  }

  let solution = history.current(model.solutions)
  let bridges = {
    use bridges, #(x, y), connections <- dict.fold(solution.connections, [])
    use bridges, #(other_x, other_y), bridge <- dict.fold(connections, bridges)
    // The `connections` data structure has bridges going from one island to the
    // other and vice-versa. We only want to draw each bridge once, so we use
    // this trick.
    use <- bool.guard(when: x < other_x || y < other_y, return: bridges)
    let bridge =
      view_bridge_between_islands(#(x, y), #(other_x, other_y), bridge)
    [bridge, ..bridges]
  }

  let current_bridge = case model.start_island, model.target_island {
    // If there's no start island selected then there's no bridge to be drawn.
    None, _ -> element.none()
    // If there's another island selected then we clip the bridge to that
    // island, so it's immediately clear where it's gonna land even if it's a
    // bit far from the actual island circle.
    Some(one), Some(other) ->
      case can_connect(model, one, other) {
        Error(_) -> {
          let #(cx, cy) = model.cursor
          let #(x1, y1) = island_center(one)
          view_bridge(x1, cx, y1, cy, hashi.Single, [])
        }

        Ok(_) -> {
          let #(x1, y1) = island_center(one)
          let #(x2, y2) = island_center(other)
          view_bridge(x1, x2, y1, y2, hashi.Single, [])
        }
      }

    // Otherwise, we draw the bridge up to where the cursor is.
    Some(island), None -> {
      let #(cx, cy) = model.cursor
      let #(x1, y1) = island_center(island)
      view_bridge(x1, cx, y1, cy, hashi.Single, [])
    }
  }

  let viewbox_height =
    radius * 2 * hashi.height(model.puzzle) + 1 + 2 * stroke_width
  let viewbox_width =
    radius * 2 * hashi.width(model.puzzle) + 1 + 2 * stroke_width

  let hashi_grid =
    html.svg(
      [
        attribute.class("hashi-grid"),
        case solution.outcome {
          Ok(_) -> attribute.class("complete")
          Error(_) -> attribute.none()
        },
        event.on("pointerup", decode.success(UserStoppedPressing)),
        event.on(
          "pointerdown",
          decode.map(decode.dynamic, UserMovedPointerOverGrid),
        ),
        event.on(
          "pointermove",
          decode.map(decode.dynamic, UserMovedPointerOverGrid),
        )
          |> event.throttle(15),
        attribute.attribute(
          "viewBox",
          int.to_string(-stroke_width)
            <> " "
            <> int.to_string(-stroke_width)
            <> " "
            <> int.to_string(viewbox_width)
            <> " "
            <> int.to_string(viewbox_height),
        ),
      ],
      [
        current_bridge,
        element.fragment(islands_hitboxes),
        element.fragment(bridges),
        element.fragment(islands),
      ],
    )
  hashi_grid
}

fn view_bridge_between_islands(
  island: #(Int, Int),
  other_island: #(Int, Int),
  bridge: Bridge,
) -> Element(Message) {
  let #(x1, y1) = island_center(island)
  let #(x2, y2) = island_center(other_island)
  view_bridge(x1, x2, y1, y2, bridge, [
    event.on_click(UserClickedBridge(island, other_island)),
  ])
}

/// Given an island this returns the coordinates where the center of the island
/// should be in the puzzle's grid.
fn island_center(island: #(Int, Int)) -> #(Int, Int) {
  let #(x, y) = island
  #(x * radius * 2 + radius, y * radius * 2 + radius)
}

fn view_bridge(
  x1: Int,
  x2: Int,
  y1: Int,
  y2: Int,
  bridge: Bridge,
  attributes: List(Attribute(message)),
) -> Element(message) {
  let offset = stroke_width

  let bridge_lines = case bridge {
    hashi.Single -> [
      svg.line([
        attribute.attribute("x1", int.to_string(x1)),
        attribute.attribute("y1", int.to_string(y1)),
        attribute.attribute("x2", int.to_string(x2)),
        attribute.attribute("y2", int.to_string(y2)),
      ]),
    ]

    hashi.Double if x1 == x2 -> [
      svg.line([
        attribute.attribute("x1", int.to_string(x1 - offset)),
        attribute.attribute("y1", int.to_string(y1)),
        attribute.attribute("x2", int.to_string(x2 - offset)),
        attribute.attribute("y2", int.to_string(y2)),
      ]),
      svg.line([
        attribute.attribute("x1", int.to_string(x1 + offset)),
        attribute.attribute("y1", int.to_string(y1)),
        attribute.attribute("x2", int.to_string(x2 + offset)),
        attribute.attribute("y2", int.to_string(y2)),
      ]),
    ]
    hashi.Double -> [
      svg.line([
        attribute.attribute("x1", int.to_string(x1)),
        attribute.attribute("y1", int.to_string(y1 - offset)),
        attribute.attribute("x2", int.to_string(x2)),
        attribute.attribute("y2", int.to_string(y2 - offset)),
      ]),
      svg.line([
        attribute.attribute("x1", int.to_string(x1)),
        attribute.attribute("y1", int.to_string(y1 + offset)),
        attribute.attribute("x2", int.to_string(x2)),
        attribute.attribute("y2", int.to_string(y2 + offset)),
      ]),
    ]
  }

  let double_class = case bridge {
    hashi.Single -> attribute.none()
    hashi.Double -> attribute.class("double")
  }

  svg.g(
    [
      attribute.attribute("stroke-width", int.to_string(stroke_width)),
      attribute.class("hashi-bridge"),
      double_class,
      ..attributes
    ],
    bridge_lines,
  )
}

/// This draws a transparent bigger island centered where the island should be.
/// This will act as a bigger hitbox to drop a bridge onto; from playing this on
/// mobile, it would otherwise feel awkard having to drop the bridge exactly
/// onto an island rather than close to it.
fn view_island_hitbox(island: #(Int, Int)) -> Element(Message) {
  let #(x, y) = island
  let #(cx, cy) = island_center(island)

  svg.g(
    [
      attribute.data("x", int.to_string(x)),
      attribute.data("y", int.to_string(y)),
      attribute.class("hashi-island-hitbox"),
    ],
    [
      svg.circle([
        attribute.attribute("cx", int.to_string(cx)),
        attribute.attribute("cy", int.to_string(cy)),
        attribute.attribute("r", float.to_string(int.to_float(radius) *. 2.0)),
        attribute.attribute("fill", "transparent"),
        attribute.attribute("stroke-width", "0"),
        attribute.attribute("stroke", "transparent"),
      ]),
    ],
  )
}

fn view_island(model: Model, island: #(Int, Int)) -> Element(Message) {
  case hashi.island_rank(model.puzzle, island) {
    Error(_) -> element.none()
    Ok(rank) -> {
      let #(x, y) = island
      let #(cx, cy) = island_center(island)

      let selectable = case model.start_island {
        None -> attribute.class("selectable")
        Some(other_point) if other_point == island -> attribute.class("selected")
        Some(other_point) ->
          case can_connect(model, island, other_point) {
            Error(_) -> attribute.class("disabled")
            Ok(_) -> attribute.class("selectable")
          }
      }

      let status = case history.current(model.solutions).outcome {
        // There's at least one island with the wrong number of bridges, we
        // check if it is this one, and we color it red if it has more than
        // expected. Green if it is correct.
        Error(hashi.IslandsHaveWrongBridges(wrong_islands)) ->
          case dict.get(wrong_islands, island) {
            Error(_) -> attribute.class("complete")
            Ok(hashi.WrongBridges(expected:, actual:)) if actual > expected ->
              attribute.class("wrong")
            Ok(hashi.WrongBridges(..)) -> attribute.none()
          }

        // If we get to this error it means that all islands are complete
        // already and they're only not connected properly.
        // So all islands will be marked as complete.
        Error(hashi.DisjointGroups(..)) -> attribute.class("complete")
        Ok(Nil) -> attribute.class("complete")
      }

      svg.g(
        [
          attribute.class("hashi-island"),
          attribute.class("hashi-island-hitbox"),
          event.on("pointerdown", decode.success(UserPressedOnIsland(island))),
          status,
          selectable,
          attribute.data("x", int.to_string(x)),
          attribute.data("y", int.to_string(y)),
        ],
        [
          svg.circle([
            attribute.attribute("cx", int.to_string(cx)),
            attribute.attribute("cy", int.to_string(cy)),
            attribute.attribute("r", int.to_string(radius)),
            attribute.attribute("stroke-width", int.to_string(stroke_width)),
          ]),
          svg.text(
            [
              attribute.attribute("x", int.to_string(cx)),
              attribute.attribute("y", int.to_string(cy)),
              attribute.attribute("text-anchor", "middle"),
              attribute.attribute("dominant-baseline", "central"),
            ],
            int.to_string(rank),
          ),
        ],
      )
    }
  }
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

// HELPERS ---------------------------------------------------------------------

fn insert_or_create(
  dict: Option(Dict(key, value)),
  key: key,
  value: value,
) -> Dict(key, value) {
  case dict {
    Some(dict) -> dict.insert(dict, key, value)
    None -> dict.from_list([#(key, value)])
  }
}

fn try_delete(dict: Option(Dict(key, value)), key: key) -> Dict(key, value) {
  case dict {
    Some(dict) -> dict.delete(dict, key)
    None -> dict.new()
  }
}

/// This returns true if `predicate` returns true for any of the numbers in
/// `[start, end]`.
fn range_all(
  from start: Int,
  to end: Int,
  satisfy predicate: fn(Int) -> Bool,
) -> Bool {
  case start < end {
    True -> range_all_loop(start, end, 1, predicate)
    False -> range_all_loop(start, end, -1, predicate)
  }
}

fn range_all_loop(
  current: Int,
  end: Int,
  delta: Int,
  predicate: fn(Int) -> Bool,
) -> Bool {
  case predicate(current) {
    True if current == end -> True
    True -> range_all_loop(current + delta, end, delta, predicate)
    False -> False
  }
}
