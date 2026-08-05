import frontend/history.{type History}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import lustre/attribute.{type Attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import shared/hashi.{
  type Bridge, type Direction, type InvalidSolution, type Puzzle,
}

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Model(
    /// The puzzle we're currently trying to solve.
    puzzle: Puzzle,
    /// We keep track of all the moves of a user so we can easily undo/redo
    solutions: History(Solution),
    /// The position of the cursor, in the coordinate space of the svg grid
    /// holding the puzzle.
    pointer: #(Int, Int),
    /// When drawing a bridge from one island to another, this contains the
    /// coordinates of the starting island.
    bridge_start: Option(BridgeStart),
  )
}

type BridgeStart {
  BridgeStart(
    /// This is the coordinates of the island from which a bridge is starting.
    island: #(Int, Int),
    /// These are the coordinates of where the cursor where when we started
    /// drawing the bridge. We need this to know where the cursor is moving
    /// (up/down/left/right).
    point: #(Int, Int),
  )
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

pub type InitState {
  InitState(
    puzzle: Puzzle,
    connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
  )
}

pub fn init(state: InitState) -> Model {
  let InitState(puzzle:, connections:) = state
  let outcome = hashi.check(puzzle, connections)
  let model =
    Model(
      pointer: #(0, 0),
      puzzle:,
      bridge_start: None,
      solutions: history.new(
        Solution(outcome:, connections:, bridges: {
          use cells, start, connections <- dict.fold(connections, set.new())
          use cells, end, _bridge <- dict.fold(connections, cells)
          add_bridge_cells(cells, start, end)
        }),
      ),
    )

  model
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

fn remove_one_bridge(
  model: Model,
  one: #(Int, Int),
  other: #(Int, Int),
) -> Model {
  let #(x, y) = one
  let #(other_x, other_y) = other

  let solution = history.current(model.solutions)
  let connections =
    solution.connections
    |> try_remove_one_bridge(from: one, to: other)
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

/// If a bridge can be drawn between two points, this returns the next bridge
/// we'll have to insert between the two points if it is actually drawn.
/// If the bridge is `Ok(None)` that means that drawing a bridge will delete
/// all the bridges.
fn can_connect(
  model: Model,
  point: #(Int, Int),
  to selected: #(Int, Int),
) -> Result(Option(Bridge), Nil) {
  // The islands must be orthogonal
  let #(x, y) = selected
  let #(other_x, other_y) = point

  use <- bool.guard(
    when: selected == point
      || !hashi.has_island(model.puzzle, point)
      || !hashi.has_island(model.puzzle, selected),
    return: Error(Nil),
  )

  let solution = history.current(model.solutions)
  let bridge = {
    use connections <- result.try(dict.get(solution.connections, point))
    use bridge <- result.try(dict.get(connections, selected))
    Ok(bridge)
  }

  case bridge {
    Ok(hashi.Double) -> Ok(None)
    Ok(hashi.Single) -> Ok(Some(hashi.Double))
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
            True -> Ok(Some(hashi.Single))
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
            True -> Ok(Some(hashi.Single))
            False -> Error(Nil)
          }
        }

        _ -> Error(Nil)
      }
  }
}

pub fn is_complete(model: Model) -> Bool {
  history.current(model.solutions).outcome == Ok(Nil)
}

pub fn step_forward(model: Model) -> Model {
  Model(..model, solutions: history.step_forward(model.solutions))
}

pub fn can_step_forward(model: Model) -> Bool {
  history.can_step_forward(model.solutions)
}

pub fn step_back(model: Model) -> Model {
  Model(..model, solutions: history.step_back(model.solutions))
}

pub fn can_step_back(model: Model) -> Bool {
  history.can_step_back(model.solutions)
}

pub fn current_solution(model: Model) -> Solution {
  history.current(model.solutions)
}

pub fn has_bridges(model: Model) -> Bool {
  !set.is_empty(history.current(model.solutions).bridges)
}

pub fn delete_all_bridges(model: Model) -> Model {
  let outcome = hashi.check(model.puzzle, dict.new())
  let new_solution =
    Solution(outcome:, connections: dict.new(), bridges: set.new())
  let solutions = history.push(model.solutions, new_solution)
  Model(..model, solutions:)
}

// UPDATE ----------------------------------------------------------------------

pub type Message {
  UserPressedOnIsland(island: #(Int, Int), pointer: #(Int, Int))
  UserStoppedPressing(pointer: #(Int, Int))
  PointerMoved(pointer: #(Int, Int))
  UserClickedBridge(between: #(Int, Int), and: #(Int, Int))
}

pub fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  use <- skip_if_complete(model)

  case message {
    UserClickedBridge(between: one, and: other) -> {
      let model = remove_one_bridge(model, one, other)
      let effect = effect.none()
      #(model, effect)
    }

    UserPressedOnIsland(island:, pointer:) -> {
      // If we press on an island and there was an already selected one, then
      // we have to connect the two islands.
      let model = Model(..model, pointer:)
      case model.bridge_start {
        Some(BridgeStart(island: start, ..)) -> {
          let model = try_connect(model, start, island)
          let effect = effect.none()
          #(model, effect)
        }

        None -> {
          let bridge_start = Some(BridgeStart(island:, point: pointer))
          let model = Model(..model, bridge_start:)
          let effect = effect.none()
          #(model, effect)
        }
      }
    }

    UserStoppedPressing(pointer:) -> {
      let model = Model(..model, pointer:)
      case model.bridge_start {
        None -> {
          let model = Model(..model, bridge_start: None)
          let effect = effect.none()
          #(model, effect)
        }

        // If we stop start and stop pressing on the same island where we
        // started that counts as a click. We select the island that has just
        // been clicked as the start and wait for the destination to be clicked.
        Some(BridgeStart(island:, point:)) -> {
          let squared_distance = {
            let dx = model.pointer.0 - point.0
            let dy = model.pointer.1 - point.1
            dx * dx + dy * dy
          }
          case squared_distance == 0 {
            True -> #(model, effect.none())
            False -> {
              let direction = direction(from: point, to: model.pointer)
              case try_connect_in_direction(model, island, direction) {
                Error(_) -> {
                  let model = Model(..model, bridge_start: None)
                  let effect = effect.none()
                  #(model, effect)
                }
                Ok(model) -> {
                  let effect = effect.none()
                  #(model, effect)
                }
              }
            }
          }
        }
      }
    }

    PointerMoved(pointer:) -> {
      let model = Model(..model, pointer:)
      let effect = effect.none()
      #(model, effect)
    }
  }
}

/// If there's an island that can be connected to the given one, going in the
/// given direction, it will be returned.
fn try_connect_in_direction(
  model: Model,
  of island: #(Int, Int),
  going direction: Direction,
) -> Result(Model, Nil) {
  use candidate <- result.try(neighbour(model, of: island, going: direction))
  Ok(try_connect(model, island, candidate))
}

fn neighbour(
  model: Model,
  of island: #(Int, Int),
  going direction: Direction,
) -> Result(#(Int, Int), Nil) {
  let #(x, y) = island
  let occupied = fn(x, y) { hashi.has_island(model.puzzle, #(x, y)) }
  case direction {
    hashi.Down -> {
      let height = hashi.height(model.puzzle)
      range_first(from: y + 1, to: height - 1, so_that: occupied(x, _))
      |> result.map(fn(y) { #(x, y) })
    }
    hashi.Left ->
      range_first(from: x - 1, to: 0, so_that: occupied(_, y))
      |> result.map(fn(x) { #(x, y) })
    hashi.Up ->
      range_first(from: y - 1, to: 0, so_that: occupied(x, _))
      |> result.map(fn(y) { #(x, y) })
    hashi.Right -> {
      let width = hashi.width(model.puzzle)
      range_first(from: x + 1, to: width - 1, so_that: occupied(_, y))
      |> result.map(fn(x) { #(x, y) })
    }
  }
}

fn direction(from start: #(Int, Int), to end: #(Int, Int)) -> Direction {
  let #(x_start, y_start) = start
  let #(x_end, y_end) = end
  case int.to_float(y_start - y_end) /. int.to_float(x_start - x_end) {
    _ if y_start == y_end && x_start < x_end -> hashi.Right
    _ if y_start == y_end -> hashi.Left
    _ if x_start == x_end && y_start < y_end -> hashi.Down
    _ if x_start == x_end -> hashi.Up

    slope if slope >=. 1.0 ->
      case x_start < x_end {
        True -> hashi.Down
        False -> hashi.Up
      }

    slope if slope >=. 0.0 ->
      case x_start < x_end {
        True -> hashi.Right
        False -> hashi.Left
      }

    slope if slope >=. -1.0 ->
      case x_start < x_end {
        True -> hashi.Right
        False -> hashi.Left
      }

    _slope ->
      case x_start < x_end {
        True -> hashi.Up
        False -> hashi.Down
      }
  }
}

/// Given a starting and end island, this will try and connect the two in the
/// model.
/// In any case, the current selected islands will be deselected!
fn try_connect(model: Model, start: #(Int, Int), end: #(Int, Int)) -> Model {
  let model = case can_connect(model, start, end) {
    Ok(Some(bridge)) -> connect_islands(model, start, end, bridge)
    Ok(None) -> remove_one_bridge(model, start, end)
    Error(_) -> model
  }
  Model(..model, bridge_start: None)
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

// VIEW ------------------------------------------------------------------------

const radius = 10

const stroke_width = 2

pub fn view(model: Model) -> Element(Message) {
  let width = hashi.width(model.puzzle)
  let height = hashi.height(model.puzzle)

  let islands = {
    use islands, y <- int.range(from: 0, to: height, with: [])
    use islands, x <- int.range(from: 0, to: width, with: islands)
    [view_island(model, #(x, y)), ..islands]
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
      view_bridge_between_islands(model, #(x, y), #(other_x, other_y), bridge)
    [bridge, ..bridges]
  }

  let current_bridge = case model.bridge_start {
    // If there's no start island selected then there's no bridge to be drawn.
    None -> element.none()
    // Otherwise we draw the bridge in the direction we're going.
    Some(BridgeStart(island: start, point:)) -> {
      let squared_distance = {
        let dx = point.0 - model.pointer.0
        let dy = point.1 - model.pointer.1
        dx * dx + dy * dy
      }
      let direction = direction(point, model.pointer)
      case neighbour(model, start, direction) {
        _ if squared_distance == 0 -> element.none()
        Error(_) -> element.none()
        Ok(end) -> {
          case can_connect(model, start, end) {
            Error(_) -> element.none()
            Ok(_) -> {
              let #(x1, y1) = island_center(start)
              let #(x2, y2) = island_center(end)
              view_bridge(x1, x2, y1, y2, hashi.Single, False, [
                attribute.class("current"),
              ])
            }
          }
        }
      }
    }
  }

  let viewbox_height =
    radius * 2 * hashi.height(model.puzzle) + 1 + 2 * stroke_width
  let viewbox_width =
    radius * 2 * hashi.width(model.puzzle) + 1 + 2 * stroke_width

  html.svg(
    [
      attribute.class("hashi-grid"),
      case solution.outcome {
        Ok(_) -> attribute.class("complete")
        Error(_) -> attribute.none()
      },
      pointer_event_decoder()
        |> decode.map(UserStoppedPressing)
        |> event.on("pointerup", _),
      pointer_event_decoder()
        |> decode.map(PointerMoved)
        |> event.on("pointermove", _)
        |> event.throttle(5),
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
      element.fragment(bridges),
      current_bridge,
      element.fragment(islands),
    ],
  )
}

fn pointer_event_decoder() -> decode.Decoder(#(Int, Int)) {
  use x <- decode.field("x", decode.float |> decode.map(float.round))
  use y <- decode.field("y", decode.float |> decode.map(float.round))
  decode.success(#(x, y))
}

fn view_bridge_between_islands(
  model: Model,
  island: #(Int, Int),
  other_island: #(Int, Int),
  bridge: Bridge,
) -> Element(Message) {
  let #(x1, y1) = island_center(island)
  let #(x2, y2) = island_center(other_island)
  view_bridge(x1, x2, y1, y2, bridge, True, [
    // If there's an active island we don't want to trigger bridge events if we
    // inadvertently click on them!
    case model.bridge_start {
      Some(_) -> attribute.none()
      None -> event.on_click(UserClickedBridge(island, other_island))
    },
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
  hitbox: Bool,
  attributes: List(Attribute(message)),
) -> Element(message) {
  let margin = radius + stroke_width
  let min_x = int.min(x1, x2)
  let min_y = int.min(y1, y2)
  let delta_x = int.absolute_value(x1 - x2)
  let delta_y = int.absolute_value(y1 - y2)
  let hitbox = case x1 == x2 {
    _ if !hitbox -> element.none()
    True ->
      svg.rect([
        attribute.attribute("fill", "transparent"),
        attribute.attribute("stroke", "transparent"),
        attribute.attribute("x", int.to_string(min_x - 3 * stroke_width)),
        attribute.attribute("y", int.to_string(min_y + margin)),
        attribute.width(6 * stroke_width),
        attribute.height(delta_y - 2 * margin),
      ])

    False ->
      svg.rect([
        attribute.attribute("fill", "transparent"),
        attribute.attribute("stroke", "transparent"),
        attribute.attribute("x", int.to_string(min_x + margin)),
        attribute.attribute("y", int.to_string(min_y - 3 * stroke_width)),
        attribute.width(delta_x - 2 * margin),
        attribute.height(6 * stroke_width),
      ])
  }

  let bridge_lines = case bridge {
    hashi.Single -> [
      hitbox,
      svg.line([
        attribute.attribute("x1", int.to_string(x1)),
        attribute.attribute("y1", int.to_string(y1)),
        attribute.attribute("x2", int.to_string(x2)),
        attribute.attribute("y2", int.to_string(y2)),
      ]),
      svg.rect([]),
    ]

    hashi.Double if x1 == x2 -> [
      hitbox,
      svg.line([
        attribute.attribute("x1", int.to_string(x1 - stroke_width)),
        attribute.attribute("y1", int.to_string(y1)),
        attribute.attribute("x2", int.to_string(x2 - stroke_width)),
        attribute.attribute("y2", int.to_string(y2)),
      ]),
      svg.line([
        attribute.attribute("x1", int.to_string(x1 + stroke_width)),
        attribute.attribute("y1", int.to_string(y1)),
        attribute.attribute("x2", int.to_string(x2 + stroke_width)),
        attribute.attribute("y2", int.to_string(y2)),
      ]),
    ]
    hashi.Double -> [
      hitbox,
      svg.line([
        attribute.attribute("x1", int.to_string(x1)),
        attribute.attribute("y1", int.to_string(y1 - stroke_width)),
        attribute.attribute("x2", int.to_string(x2)),
        attribute.attribute("y2", int.to_string(y2 - stroke_width)),
      ]),
      svg.line([
        attribute.attribute("x1", int.to_string(x1)),
        attribute.attribute("y1", int.to_string(y1 + stroke_width)),
        attribute.attribute("x2", int.to_string(x2)),
        attribute.attribute("y2", int.to_string(y2 + stroke_width)),
      ]),
      svg.rect([]),
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

fn view_island(model: Model, island: #(Int, Int)) -> Element(Message) {
  case hashi.island_rank(model.puzzle, island) {
    Error(_) -> element.none()
    Ok(rank) -> {
      let #(cx, cy) = island_center(island)
      let selectable = case model.bridge_start {
        None -> attribute.class("selectable")
        Some(BridgeStart(island: other_island, ..)) if other_island == island ->
          attribute.class("selected")

        Some(BridgeStart(island: other_island, ..)) ->
          case can_connect(model, island, other_island) {
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

        // If we get to this error it means that all islands have the correct
        // number of bridges, but there's groups that are disjoint.
        // To make it easy to spot which islands are not connected we're gonna
        // colour all the ones from one of the groups in red!
        Error(hashi.DisjointGroups([first_group, ..])) ->
          case set.contains(first_group, island) {
            True -> attribute.class("unreachable")
            False -> attribute.class("complete")
          }

        Error(hashi.DisjointGroups([])) -> {
          attribute.class("complete")
        }
        Ok(Nil) -> attribute.class("complete")
      }

      svg.g(
        [
          attribute.class("hashi-island"),
          attribute.class("hashi-island-hitbox"),
          event.on("pointerdown", {
            use pointer <- decode.then(pointer_event_decoder())
            decode.success(UserPressedOnIsland(island:, pointer:))
          }),
          status,
          selectable,
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

fn try_remove_one_bridge(
  connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
  from one: #(Int, Int),
  to other: #(Int, Int),
) -> Dict(#(Int, Int), Dict(#(Int, Int), Bridge)) {
  let connections = case dict.get(connections, one) {
    Error(_) -> connections
    Ok(reachable) -> {
      let reachable = case dict.get(reachable, other) {
        Error(_) -> reachable
        Ok(hashi.Single) -> dict.delete(reachable, other)
        Ok(hashi.Double) -> dict.insert(reachable, other, hashi.Single)
      }
      dict.insert(connections, one, reachable)
    }
  }

  let connections = case dict.get(connections, other) {
    Error(_) -> connections
    Ok(reachable) -> {
      let reachable = case dict.get(reachable, one) {
        Error(_) -> reachable
        Ok(hashi.Single) -> dict.delete(reachable, one)
        Ok(hashi.Double) -> dict.insert(reachable, one, hashi.Single)
      }
      dict.insert(connections, other, reachable)
    }
  }

  connections
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

fn range_first(
  from start: Int,
  to end: Int,
  so_that predicate: fn(Int) -> Bool,
) -> Result(Int, Nil) {
  case start < end {
    True -> range_first_loop(start, end, 1, predicate)
    False -> range_first_loop(start, end, -1, predicate)
  }
}

fn range_first_loop(
  current: Int,
  end: Int,
  delta: Int,
  predicate: fn(Int) -> Bool,
) -> Result(Int, Nil) {
  case predicate(current) {
    True -> Ok(current)
    False if current == end -> Error(Nil)
    False -> range_first_loop(current + delta, end, delta, predicate)
  }
}
