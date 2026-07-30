import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/result
import gleam/set.{type Set}
import prng/random

// TODO) add an option to allow generating loops
// TODO) add an option to check a solution

/// Creates a new set of options to generate a hashiwokakero game.
/// By default a random seed is chosen, and single and double bridges are
/// equally likely to appear.
///
/// If you want to make sure the generated puzzle is deterministic, you can set
/// a seed to use with the `with_seed` function.
///
pub fn new(
  width width: Int,
  height height: Int,
  islands islands: Int,
) -> Options {
  Options(
    seed: random.new_seed(int.random(random.max_int)),
    double_bridge_ratio: 0.5,
    width:,
    height:,
    islands:,
  )
}

/// This sets the seed to be used to generate a new hashiwokakero game.
/// For a given seed the generated game will always be the same.
///
pub fn with_seed(options: Options, seed: Int) -> Options {
  Options(..options, seed: random.new_seed(seed))
}

/// This sets the ratio of double bridges that will appear in the generated
/// game.
///
/// `double_bridge_ratio` has to be a number between 1.0 and 0.0 (and it will be
/// clamped to those values if outside the range):
/// - 1.0 means 100% of the bridges will be double bridges
/// - 0.0 means 0% of the brdiges will be double bridges
///
/// By default, code generation uses `0.5`, meaning roughly half of the bridges
/// will be double bridges.
///
pub fn with_double_bridge_ratio(
  options: Options,
  double_bridge_ratio: Float,
) -> Options {
  Options(
    ..options,
    double_bridge_ratio: float.clamp(double_bridge_ratio, min: 0.0, max: 1.0),
  )
}

/// This represents the kind of bridge that can connect islands.
/// There can only be at most two bridges between any two islands.
pub type Bridge {
  Single
  Double
}

/// The options we can tweak when creating a new puzzle to make it easier or
/// more challenging.
pub type Options {
  Options(
    /// The ratio of double bridges in the final map. This has to be a number
    /// between 0.0 and 1.0.
    /// 1.0 means 100% of the bridges will be doubles.
    double_bridge_ratio: Float,
    /// The width of the puzzle to generate.
    width: Int,
    /// The height of the puzzle to generate.
    height: Int,
    /// How many islands the puzzle can have.
    islands: Int,
    /// The seed to use to pseudo-randomly generate the puzzle, this is handy
    /// to be able to regenerate the same puzzle if needed.
    seed: random.Seed,
  )
}

pub opaque type Puzzle {
  Puzzle(
    width: Int,
    height: Int,
    /// These are the cells where islands are
    islands: Set(#(Int, Int)),
    /// This maps an island to all the islands it can be reached from it, and
    /// with how many bridges.
    connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
    /// This is a set to keep track of all the cells that are taken by a bridge.
    /// We need this to be able to quickly tell if there's a bridge where we
    /// would like to place a new island when generating the game.
    bridge_cells: Set(#(Int, Int)),
  )
}

/// This returns the width of a given puzzle.
pub fn width(puzzle: Puzzle) -> Int {
  puzzle.width
}

/// This returns the height of a given puzzle.
pub fn height(puzzle: Puzzle) -> Int {
  puzzle.height
}

/// Returns `True` is there's an island at the given position.
/// The puzzle grid starts at (0, 0) at the bottom-left corner. For example:
///
/// ```txt
/// ┌───┬───┬───┐
/// │   │ 3 │   │
/// ├───┼───┼───┤
/// │   │   │   │
/// ├───┼───┼───┤
/// │ 1 │   │   │
/// └───┴───┴───┘
/// ```
///
/// Island 1 is at `(0, 0)`, island 3 is at `(1, 2)`.
///
pub fn has_island(puzzle: Puzzle, point: #(Int, Int)) -> Bool {
  set.contains(puzzle.islands, point)
}

/// If there's an island at the given position, this will return its rank: that
/// is, the number of bridges leaving from the island. For example, given this
/// grid:
///
/// ```txt
/// ┌───┬───┬───┐
/// │   │ 3 │   │
/// ├───┼───┼───┤
/// │   │   │   │
/// ├───┼───┼───┤
/// │ 1 │   │   │
/// └───┴───┴───┘
/// ```
///
/// ```gleam
/// assert Ok(1) == hashi.island_rank(puzzle, #(0, 0))
/// assert Ok(3) == hashi.island_rank(puzzle, #(1, 2))
/// assert Error(Nil) == hashi.island_rank(puzzle, #(2, 2))
/// ```
///
pub fn island_rank(puzzle: Puzzle, island: #(Int, Int)) -> Result(Int, Nil) {
  use connections <- result.map(dict.get(puzzle.connections, island))
  dict.fold(over: connections, from: 0, with: fn(count, _, bridge) {
    case bridge {
      Single -> count + 1
      Double -> count + 2
    }
  })
}

/// Returns `True` if there's a bridge at the given position.
fn has_bridge(puzzle: Puzzle, point: #(Int, Int)) -> Bool {
  set.contains(puzzle.bridge_cells, point)
}

/// Returns `True` if the given position is occupied, either by an island or by
/// a bridge.
fn is_occupied(puzzle: Puzzle, point: #(Int, Int)) -> Bool {
  has_island(puzzle, point) || has_bridge(puzzle, point)
}

/// Given a position, this tells us if there's any island orthogonally adjacent
/// with it.
///
/// So if there's any island in one of the point above, below, to the left, or
/// to the right of the given position:
///
/// ```txt
///   •
/// • x •
///   •
/// ```
///
fn neighbours_with_island(puzzle: Puzzle, point: #(Int, Int)) -> Bool {
  let #(x, y) = point

  has_island(puzzle, #(x + 1, y))
  || has_island(puzzle, #(x - 1, y))
  || has_island(puzzle, #(x, y + 1))
  || has_island(puzzle, #(x, y - 1))
}

/// Given some default options this creates a new puzzle.
///
/// The puzzle generation will always try to generate a puzzle with the given
/// number of islands.
/// But if there's too many islands for the cell it might get stuck trying to
/// generate a map with enough islands! Try to keep the number of islands lower
/// than a third of the number of cells to make sure this won't get stuck for a
/// long time.
///
pub fn generate(options: Options) -> Puzzle {
  // We start with a single island at a random position.
  let Options(double_bridge_ratio:, width:, height:, islands:, seed:) = options

  let #(x, seed) = random.int(0, width - 1) |> random.step(seed)
  let #(y, seed) = random.int(0, height - 1) |> random.step(seed)

  let puzzle =
    Puzzle(
      width:,
      height:,
      islands: set.new(),
      connections: dict.new(),
      bridge_cells: set.new(),
    )
    |> insert_island(#(x, y))

  let state =
    GenerateState(
      left_to_generate: islands - 1,
      seed:,
      free_islands: [#(x, y)],
      bridge_generator: random.weighted(#(double_bridge_ratio, Double), [
        #(1.0 -. double_bridge_ratio, Single),
      ]),
    )

  case grow_loop(puzzle, state) {
    Ok(result) -> ensure_all_borders_are_used(result)
    // If we cannot generate this many islands from the starting point we might
    // have been unlucky in how we chose to grow some islands.
    // Usually by trying again we get unstuck and can quickly get to a correct
    // grid.
    // Note that this is where we might get stuck in an infinite loop! If it's
    // impossible to place that many islands in a map of the given side we will
    // be looping indefinitely!
    Error(seed) -> generate(Options(..options, seed:))
  }
}

/// This function takes a generated puzzle and makes sure that all the borders
/// of the grid are used by islands by moving those around in a
/// solution-preserving way.
///
/// For example, in this 4x4 grid:
///
/// ```txt
/// • • • •
/// • 1 • •
/// • • • •
/// • 2 • 1
/// ```
///
/// Neither the left side, nor the upper side are used, effectively making this
/// a 3x3 puzzle instead. This is bound to happen as we randomly generate
/// puzzles.
/// There is an easy way to fix this: starting from one side we can always take
/// the closest non-empty row (or column) and move it to the side. This doesn't
/// change the overall solution as this won't change an island's neighbours.
///
/// So in our example we can make sure the left side is used by moving the
/// second column to the left:
///
/// ```txt
/// • • • •
/// 1 • • •
/// • • • •
/// 2 • • 1
/// ```
///
/// And finally we can make sure the top side is used by moving the second row
/// up:
///
/// ```txt
/// 1 • • •
/// • • • •
/// • • • •
/// 2 • • 1
/// ```
///
fn ensure_all_borders_are_used(puzzle: Puzzle) -> Puzzle {
  list.fold(over: [Up, Down, Left, Right], from: puzzle, with: fn(puzzle, side) {
    case side_has_islands(puzzle, side) {
      True -> puzzle
      False -> move_to_use_side(puzzle, side)
    }
  })
}

fn side_has_islands(puzzle: Puzzle, side: Direction) -> Bool {
  case side {
    Right -> column_has_islands(puzzle, puzzle.width - 1)
    Up -> row_has_islands(puzzle, puzzle.height - 1)
    Left -> column_has_islands(puzzle, 0)
    Down -> row_has_islands(puzzle, 0)
  }
}

fn column_has_islands(puzzle: Puzzle, column: Int) -> Bool {
  range_any(from: 0, to: puzzle.height - 1, so_that: fn(y) {
    set.contains(puzzle.islands, #(column, y))
  })
}

fn row_has_islands(puzzle: Puzzle, row: Int) -> Bool {
  range_any(from: 0, to: puzzle.width - 1, so_that: fn(x) {
    set.contains(puzzle.islands, #(x, row))
  })
}

fn move_to_use_side(puzzle: Puzzle, side: Direction) -> Puzzle {
  case side {
    Up -> {
      let first_used_row_from_the_top =
        range_first(from: puzzle.height - 2, to: 0, so_that: fn(row) {
          row_has_islands(puzzle, row)
        })

      case first_used_row_from_the_top {
        Error(Nil) -> puzzle
        Ok(y) -> move_row(puzzle, from: y, to: puzzle.height - 1)
      }
    }

    Down -> {
      let first_used_row_from_the_bottom =
        range_first(from: 1, to: puzzle.height, so_that: fn(row) {
          row_has_islands(puzzle, row)
        })

      case first_used_row_from_the_bottom {
        Error(Nil) -> puzzle
        Ok(y) -> move_row(puzzle, from: y, to: 0)
      }
    }

    Left -> {
      let first_used_column_from_the_left =
        range_first(from: 0, to: puzzle.width, so_that: fn(column) {
          column_has_islands(puzzle, column)
        })

      case first_used_column_from_the_left {
        Error(Nil) -> puzzle
        Ok(x) -> move_column(puzzle, from: x, to: 0)
      }
    }

    Right -> {
      let first_used_column_from_the_right =
        range_first(from: puzzle.width - 2, to: 0, so_that: fn(column) {
          column_has_islands(puzzle, column)
        })

      case first_used_column_from_the_right {
        Error(Nil) -> puzzle
        Ok(x) -> move_column(puzzle, from: x, to: puzzle.width - 1)
      }
    }
  }
}

/// This moves all the islands in a row to the given one.
///
/// > Note: this does not perform any check whatsoever that the row we're moving
/// > islands to is empty! You will have to check that for yourself, otherwise
/// > we might end up overwriting existing islands resulting in an invalid
/// > puzzle.
fn move_row(puzzle: Puzzle, from old_y: Int, to new_y: Int) -> Puzzle {
  update_islands(puzzle, fn(island) {
    let #(x, y) = island
    case old_y == y {
      True -> #(x, new_y)
      False -> island
    }
  })
}

/// This moves all the islands in a column to the given one.
///
/// > Note: this does not perform any check whatsoever that the column we're
/// > moving islands to is empty! You will have to check that for yourself,
/// > otherwise we might end up overwriting existing islands resulting in an
/// > invalid puzzle.
fn move_column(puzzle: Puzzle, from old_x: Int, to new_x: Int) -> Puzzle {
  update_islands(puzzle, fn(island) {
    let #(x, y) = island
    case old_x == x {
      True -> #(new_x, y)
      False -> island
    }
  })
}

fn update_islands(
  puzzle: Puzzle,
  update_island: fn(#(Int, Int)) -> #(Int, Int),
) -> Puzzle {
  let islands = set.map(puzzle.islands, update_island)
  let connections = {
    use acc, start, connections <- dict.fold(puzzle.connections, dict.new())
    dict.insert(acc, update_island(start), {
      use acc, end, bridge <- dict.fold(connections, dict.new())
      dict.insert(acc, update_island(end), bridge)
    })
  }
  let puzzle = Puzzle(..puzzle, islands:, connections:)

  // After moving islands around we need to redraw all bridges as those only
  // made sense for the old puzzle before we moved islands around!
  redraw_bridges(puzzle)
}

/// Redraws all the bridges in the puzzle from scratch starting form the given
/// islands and connections.
fn redraw_bridges(puzzle: Puzzle) -> Puzzle {
  let puzzle = Puzzle(..puzzle, bridge_cells: set.new())
  use puzzle, island, connected <- dict.fold(puzzle.connections, puzzle)
  use puzzle, other_island, bridge <- dict.fold(connected, puzzle)
  connect_islands(puzzle, island, other_island, bridge)
}

/// This is a struct to carry around the state needed by the puzzle generation
/// code.
type GrowState {
  GenerateState(
    left_to_generate: Int,
    free_islands: List(#(Int, Int)),
    bridge_generator: random.Generator(Bridge),
    seed: random.Seed,
  )
}

/// Given a puzzle and a list of islands we can grow from, this will try
/// expanding the puzzle by adding the given number of islands `to_generate`.
///
/// If it's not possible to generate that many new islands this will return an
/// error. Note this doesn't mean it's impossible in general! We might have just
/// been unlucky with the specific way in which we generated islands.
///
/// In case of an error this returns the updated seed so we can keep threading
/// it around
fn grow_loop(puzzle: Puzzle, state: GrowState) -> Result(Puzzle, random.Seed) {
  let GenerateState(
    left_to_generate:,
    free_islands:,
    bridge_generator:,
    seed: old_seed,
  ) = state

  let #(seed, island_to_grow_from) = pick_one(free_islands, old_seed)
  case left_to_generate <= 0, island_to_grow_from {
    // `to_generate` is telling us how many islands we still need to generate,
    // if it gets to 0 it means we're done!
    True, _ -> Ok(puzzle)
    // If there's no free islands then it's impossible to keep expanding the
    // puzzle, we just give up.
    _, Error(_) -> Error(seed)
    // Otherwise we'll have to generate a new island connected to the one at the
    // top of the list.
    False, Ok(island) -> {
      case move_in_random_direction(puzzle, seed, from: island) {
        // If we can't move in any direction from this island then it means it
        // is no longer free. We try to keep going with the remaining islands.
        #(seed, Error(_)) -> {
          let free_islands =
            list.filter(free_islands, keeping: fn(free_island) {
              free_island != island
            })
          let state = GenerateState(..state, seed:, free_islands:)
          grow_loop(puzzle, state)
        }

        // Otherwise we're good! We just have could generate a new random island
        // connected to the current one.
        // We add it to the puzzle and add one or two bridges connecting the
        // two.
        #(seed, Ok(new_island)) -> {
          let #(bridge, seed) = random.step(bridge_generator, seed)
          // We add the island to the puzzle and then connect the two islands.
          let puzzle =
            puzzle
            |> insert_island(new_island)
            |> connect_islands(island, new_island, bridge)

          // Now that we've added an island we can keep generating. We add this
          // newly added island to the ones we can choose to grow from!
          let state =
            GenerateState(
              left_to_generate: left_to_generate - 1,
              free_islands: [new_island, ..free_islands],
              bridge_generator:,
              seed:,
            )
          grow_loop(puzzle, state)
        }
      }
    }
  }
}

/// Adds the island to the puzzle.
fn insert_island(puzzle: Puzzle, island: #(Int, Int)) -> Puzzle {
  Puzzle(..puzzle, islands: set.insert(puzzle.islands, island))
}

/// This connects two islands with the given ids in the puzzle with the given
/// bridge.
fn connect_islands(
  puzzle: Puzzle,
  one: #(Int, Int),
  other: #(Int, Int),
  bridge: Bridge,
) -> Puzzle {
  // We first update the puzzle connections, saying that the two islands are now
  // connected.
  // This code seems duplicated because we want to insert the connection in both
  // directions: `one` is connected to `other`, and `other` is connected to
  // `one`.
  let connections =
    puzzle.connections
    |> dict.upsert(one, insert_or_create(_, other, bridge))
    |> dict.upsert(other, insert_or_create(_, one, bridge))

  case one, other {
    // Islands are always orthogonal to each other, in this case they are on the
    // same column. We mark as taken all the cells in the rows between them.
    #(x, y), #(other_x, other_y) if x == other_x -> {
      let y_min = int.min(y, other_y)
      let y_max = int.max(y, other_y)

      let bridge_cells =
        int.range(y_min + 1, y_max, puzzle.bridge_cells, fn(bridge_cells, y) {
          set.insert(bridge_cells, #(x, y))
        })
      Puzzle(..puzzle, connections:, bridge_cells:)
    }

    // Islands are always orthogonal to each other, in this case they are on the
    // same row. We mark as taken all the cells in the columns between them.
    #(x, y), #(other_x, other_y) if y == other_y -> {
      let x_min = int.min(x, other_x)
      let x_max = int.max(x, other_x)
      let bridge_cells =
        int.range(x_min + 1, x_max, puzzle.bridge_cells, fn(bridge_cells, x) {
          set.insert(bridge_cells, #(x, y))
        })
      Puzzle(..puzzle, connections:, bridge_cells:)
    }

    // We should never end up here if we haven't messed up the implementation!
    _, _ -> panic as "tried connecting two non-orthogonal islands"
  }
}

type Direction {
  Up
  Down
  Left
  Right
}

fn move_in_random_direction(
  puzzle: Puzzle,
  seed: random.Seed,
  from island: #(Int, Int),
) -> #(random.Seed, Result(#(Int, Int), Nil)) {
  let #(directions, seed) =
    random.shuffle([Up, Down, Left, Right])
    |> random.step(seed)

  move_in_direction(directions, puzzle, seed, from: island)
}

fn move_in_direction(
  directions: List(Direction),
  puzzle: Puzzle,
  seed: random.Seed,
  from island: #(Int, Int),
) -> #(random.Seed, Result(#(Int, Int), Nil)) {
  let #(x, y) = island

  case directions {
    // There's no direction left to grow to, this means that we can't grow in
    // any direction from where we are!
    [] -> #(seed, Error(Nil))

    [direction, ..rest] -> {
      let free_island = fn(x, y) {
        case is_occupied(puzzle, #(x, y)) {
          False -> Ok(#(x, y))
          True -> Error(Nil)
        }
      }

      // We take all the empty cells that go from the current one to the
      // direction we're given. For example if we're going left ('b' is a cell
      // that is taken by a bridge, 'i' by an island, '•' is an empty cell):
      //
      // ```
      // • b • • • i •
      //           ^ We're moving from there to the left
      //     ^ ^ ^ We want to take all the free cells we find until we reach a
      //           taken one. These are all possible places where to put an
      //           island connected to the current one
      // ^ We can't pick this one because there's a bridge in the way and we
      //   can't cross bridges! So this is why we stop as soon as we find a
      //   taken cell.
      // ```
      //
      let candidate_islands = case direction {
        Up ->
          range_take(from: y + 1, to: puzzle.height - 1, while: {
            free_island(x, _)
          })
        Down -> range_take(from: y - 1, to: 0, while: free_island(x, _))
        Left -> range_take(from: x - 1, to: 0, while: free_island(_, y))
        Right ->
          range_take(from: x + 1, to: puzzle.width - 1, while: free_island(_, y))
      }

      // Then we remove from the possible candidates all the cells that are
      // neighbouring with an existing island. We can't have two island
      // orthogonally adjacent to each other!
      let valid_islands =
        list.filter(candidate_islands, keeping: fn(point) {
          !neighbours_with_island(puzzle, point)
        })

      // Finally we pick one of the valid candidates at random.

      case pick_one(valid_islands, seed) {
        // If there's no candidate at all, it means we can't grow in this given
        // direction, so we will try and grow in one of the remaining ones!
        #(seed, Error(_)) -> move_in_direction(rest, puzzle, seed, island)
        #(seed, Ok(island)) -> #(seed, Ok(island))
      }
    }
  }
}

/// This will generate a puzzle with the exact shape, islands and connections
/// passed to the function.
///
/// > Note the this will not perform any checks as to the correctness of the
/// > given parameters, so make sure the width and height are sufficient and
/// > this is a valid Hashi puzzle.
///
pub fn from_islands_and_connections(
  width width: Int,
  height height: Int,
  islands islands: Set(#(Int, Int)),
  connections connections: List(#(#(Int, Int), #(Int, Int), Bridge)),
) -> Puzzle {
  let puzzle =
    Puzzle(
      width:,
      height:,
      islands:,
      connections: dict.new(),
      bridge_cells: set.new(),
    )

  use puzzle, #(start, end, bridge) <- list.fold(connections, puzzle)
  connect_islands(puzzle, start, end, bridge)
}

/// Represents an invalid solution to a hashi puzzle.
/// A solution can be invalid in two cases: not all islands are connected, or
/// some islands have too many bridges.
pub type InvalidSolution {
  /// There's islands that have the wrong number of bridges.
  IslandsHaveWrongBridges(Dict(#(Int, Int), WrongBridges))

  /// There's at least two groups of islands that are not connected.
  DisjointGroups(List(Set(#(Int, Int))))
}

pub type WrongBridges {
  WrongBridges(expected: Int, actual: Int)
}

/// Given a possible solution to the puzzle, this checks if it actually is a
/// correct solution or if there's something wrong with it.
///
/// A solution is a dictionary with the connections from one island to the
/// others. Make sure the solution only includes the islands for the puzzle or
/// you'll get an `InvalidSolution` with no info back!
///
pub fn check(
  given puzzle: Puzzle,
  solution solution: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
) -> Result(Nil, InvalidSolution) {
  let islands_with_wrong_bridges = islands_with_wrong_bridges(puzzle, solution)

  case dict.is_empty(islands_with_wrong_bridges) {
    False -> Error(IslandsHaveWrongBridges(islands_with_wrong_bridges))
    True ->
      case disjoint_groups(puzzle, solution) {
        [_] -> Ok(Nil)
        disjoint_groups -> Error(DisjointGroups(disjoint_groups))
      }
  }
}

/// This returns a set of islands that have more bridges than they should.
/// If the solution contains an island that is not in the original puzzle then
/// an error is returned!
fn islands_with_wrong_bridges(
  puzzle: Puzzle,
  solution: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
) -> Dict(#(Int, Int), WrongBridges) {
  // We go over all the islands in the puzzle and check they have the correct
  // amount of bridges
  use islands, island <- set.fold(puzzle.islands, dict.new())
  let assert Ok(expected) = island_rank(puzzle, island)
    as "island is in the puzzle"

  let actual = case dict.get(solution, island) {
    Error(_) -> 0
    Ok(connections) ->
      dict.fold(connections, 0, fn(bridges, _, bridge) {
        case bridge {
          Single -> bridges + 1
          Double -> bridges + 2
        }
      })
  }

  case actual == expected {
    True -> islands
    False -> dict.insert(islands, island, WrongBridges(expected:, actual:))
  }
}

fn disjoint_groups(
  puzzle: Puzzle,
  solution: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
) -> List(Set(#(Int, Int))) {
  use groups, island <- set.fold(puzzle.islands, [])

  // We start with a set containing the island and all of its immediate
  // neighbours.
  let island_and_neighbours = case dict.get(solution, island) {
    Error(_) -> set.from_list([island])
    Ok(reachables) ->
      dict.fold(reachables, set.from_list([island]), fn(group, island, _) {
        set.insert(group, island)
      })
  }

  // Then we merge it with any pre-existing set that has some intersection with
  // this one.
  merge_overlapping_sets(groups, island_and_neighbours)
}

fn merge_overlapping_sets(
  groups: List(Set(a)),
  new_group: Set(a),
) -> List(Set(a)) {
  merge_overlapping_sets_loop(groups, new_group, [])
}

fn merge_overlapping_sets_loop(
  groups: List(Set(a)),
  new_group: Set(a),
  acc: List(Set(a)),
) -> List(Set(a)) {
  case groups {
    [] -> [new_group, ..acc]
    [group, ..rest] ->
      case set.is_empty(set.intersection(group, new_group)) {
        // There's no intersection, the two groups stay separate.
        True -> merge_overlapping_sets_loop(rest, new_group, [group, ..acc])
        // There's an intersection, the two groups are merged together.
        False -> {
          let new_group = set.union(new_group, group)
          merge_overlapping_sets_loop(rest, new_group, acc)
        }
      }
  }
}

// UTILS -----------------------------------------------------------------------

/// This applies the mapping function to numbers from `start` to `end`
/// accumulating the `Ok` values produces along the way. As soon as the mapping
/// function produces an `Error`, this stops and returns the values accumulated
/// so far.
///
/// `start` and `end` are _inclusive!_
fn range_take(
  from start: Int,
  to end: Int,
  while build: fn(Int) -> Result(a, Nil),
) -> List(a) {
  case start > end {
    True -> range_take_loop(start, end, -1, build, [])
    False -> range_take_loop(start, end, 1, build, [])
  }
}

fn range_take_loop(
  current: Int,
  end: Int,
  delta: Int,
  build: fn(Int) -> Result(a, Nil),
  acc: List(a),
) -> List(a) {
  case build(current) {
    Error(_) -> acc
    Ok(value) if current == end -> [value, ..acc]
    Ok(value) ->
      range_take_loop(current + delta, end, delta, build, [value, ..acc])
  }
}

/// This returns true if `predicate` returns true for any of the numbers in
/// `[start, end]`.
fn range_any(
  from start: Int,
  to end: Int,
  so_that predicate: fn(Int) -> Bool,
) -> Bool {
  case start < end {
    True -> range_any_loop(start, end, 1, predicate)
    False -> range_any_loop(start, end, -1, predicate)
  }
}

fn range_any_loop(
  current: Int,
  end: Int,
  delta: Int,
  predicate: fn(Int) -> Bool,
) -> Bool {
  case predicate(current) {
    True -> True
    False if current == end -> False
    False -> range_any_loop(current + delta, end, delta, predicate)
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

/// If the given dictionary is none, this creates a dictionary with the given
/// key-value pair. Otherwise, that is inserted into the existing dictionary.
fn insert_or_create(
  dict: option.Option(Dict(key, value)),
  key: key,
  value: value,
) -> Dict(key, value) {
  case dict {
    option.Some(dict) -> dict.insert(dict, key, value)
    option.None -> dict.from_list([#(key, value)])
  }
}

fn pick_one(
  list: List(a),
  seed: random.Seed,
) -> #(random.Seed, Result(a, Nil)) {
  let #(sampled, seed) = random.step(random.sample(list, 1), seed)
  case sampled {
    [] -> #(seed, Error(Nil))
    [item, ..] -> #(seed, Ok(item))
  }
}

// (DE)SERIALISATION -----------------------------------------------------------

pub fn to_json(puzzle: Puzzle) {
  let Puzzle(width:, height:, islands:, connections:, bridge_cells: _) = puzzle

  let connections = {
    use acc, start, connections <- dict.fold(connections, dict.new())
    dict.insert(acc, start, {
      use acc, end, bridge <- dict.fold(connections, dict.new())
      dict.insert(acc, end, bridge)
    })
  }

  json.object([
    #("width", json.int(width)),
    #("height", json.int(height)),
    #(
      "islands",
      json.preprocessed_array({
        use islands, island <- set.fold(islands, [])
        [island_to_json(island), ..islands]
      }),
    ),
    #("connections", connections_to_json(connections)),
  ])
}

pub fn decoder() -> Decoder(Puzzle) {
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use islands <- decode.field(
    "islands",
    decode.list({
      use x <- decode.field(0, decode.int)
      use y <- decode.field(1, decode.int)
      decode.success(#(x, y))
    }),
  )
  use connections <- decode.field("connections", connections_decoder())
  let puzzle =
    Puzzle(
      width:,
      height:,
      islands: set.from_list(islands),
      connections:,
      bridge_cells: set.new(),
    )
    |> redraw_bridges
  decode.success(puzzle)
}

pub fn connections_to_json(
  connections: Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
) -> Json {
  json.preprocessed_array({
    use start, connections <- fold_to_list(connections)
    let island = island_to_json(start)
    let connections =
      json.preprocessed_array({
        use end, bridge <- fold_to_list(connections)
        json.preprocessed_array([
          island_to_json(end),
          bridge_to_json(bridge),
        ])
      })
    json.preprocessed_array([island, connections])
  })
}

pub fn connections_decoder() -> Decoder(
  Dict(#(Int, Int), Dict(#(Int, Int), Bridge)),
) {
  decode.list({
    use start <- decode.field(0, island_decoder())
    use connections <- decode.field(
      1,
      decode.list({
        use end <- decode.field(0, island_decoder())
        use bridge <- decode.field(1, bridge_decoder())
        decode.success(#(end, bridge))
      }),
    )
    decode.success(#(start, dict.from_list(connections)))
  })
  |> decode.map(dict.from_list)
}

fn bridge_to_json(bridge: Bridge) -> Json {
  case bridge {
    Single -> json.int(1)
    Double -> json.int(2)
  }
}

fn bridge_decoder() -> Decoder(Bridge) {
  use number <- decode.then(decode.int)
  case number {
    1 -> decode.success(Single)
    2 -> decode.success(Double)
    _ -> decode.failure(Single, "Bridge")
  }
}

fn island_to_json(island: #(Int, Int)) {
  let #(x, y) = island
  json.preprocessed_array([
    json.int(x),
    json.int(y),
  ])
}

fn island_decoder() -> Decoder(#(Int, Int)) {
  use x <- decode.field(0, decode.int)
  use y <- decode.field(1, decode.int)
  decode.success(#(x, y))
}

fn fold_to_list(dict: Dict(key, value), fun: fn(key, value) -> a) -> List(a) {
  dict.fold(dict, [], fn(values, key, value) { [fun(key, value), ..values] })
}
