import gleam/erlang/reference.{type Reference}
import gleam/float
import gleam/int
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date}
import shared/calendar_extra.{
  Friday, Monday, Saturday, Sunday, Thursday, Tuesday, Wednesday,
}
import shared/hashi

/// Returns the file name to be used to store data about a puzzle for the given
/// day.
pub fn file_name(for date: Date) -> String {
  let year =
    date.year
    |> int.to_string
    |> string.pad_start(to: 4, with: "0")
  let month =
    calendar.month_to_int(date.month)
    |> int.to_string
    |> string.pad_start(to: 2, with: "0")
  let day =
    date.day
    |> int.to_string
    |> string.pad_start(to: 2, with: "0")
  year <> "-" <> month <> "-" <> day <> ".hashi"
}

/// Returns the default options to be used to generate a daily puzzle for the
/// given day.
pub fn default_options(for today: Date) -> hashi.Options {
  // The default parameters to use for each day. We ramp up difficulty as we
  // inch towards the weekend.
  case calendar_extra.day_of_the_week(today) {
    Monday ->
      hashi.new(width: 6, height: 6, islands: 15)
      |> hashi.with_double_bridge_ratio(0.4)
    Tuesday ->
      hashi.new(width: 6, height: 6, islands: 15)
      |> hashi.with_double_bridge_ratio(0.4)
    Wednesday ->
      hashi.new(width: 7, height: 7, islands: 17)
      |> hashi.with_double_bridge_ratio(0.4)
    Thursday ->
      hashi.new(width: 8, height: 8, islands: 21)
      |> hashi.with_double_bridge_ratio(0.5)
    Friday ->
      hashi.new(width: 9, height: 9, islands: 25)
      |> hashi.with_double_bridge_ratio(0.3)
    Saturday ->
      hashi.new(width: 10, height: 10, islands: 30)
      |> hashi.with_double_bridge_ratio(0.5)
    Sunday ->
      hashi.new(width: 9, height: 9, islands: 26)
      |> hashi.with_double_bridge_ratio(0.5)
  }
}

/// Given the content of a daily puzzle file, this returns the options used to
/// generate such puzzle.
pub fn parse_options(file_content: String) -> Result(hashi.Options, Nil) {
  case string.split(file_content, on: "\n") {
    [width, height, islands, double_bridge_ratio, _times] -> {
      use width <- result.try(int.parse(width))
      use height <- result.try(int.parse(height))
      use islands <- result.try(int.parse(islands))
      use double_bridge_ratio <- result.try(float.parse(double_bridge_ratio))

      hashi.new(width:, height:, islands:)
      |> hashi.with_double_bridge_ratio(double_bridge_ratio)
      |> Ok
    }

    _ -> Error(Nil)
  }
}

/// Given the options used to generate a daily puzzle, this turns them into a
/// binary that can be written to the puzzle's file.
pub fn serialise_options(options: hashi.Options) -> String {
  let hashi.Options(double_bridge_ratio:, width:, height:, islands:, seed: _) =
    options

  [
    int.to_string(width),
    int.to_string(height),
    int.to_string(islands),
    float.to_string(double_bridge_ratio),
  ]
  |> string.join("\n")
  |> string.append("\n")
}

// CACHING THE DAILY PUZZLE ----------------------------------------------------

pub opaque type Cache {
  Cache(table: Reference)
}

pub fn new_cache() -> Cache {
  Cache(table: create_cache_ets_table())
}

@external(erlang, "hashi_ffi", "create_cache_ets_table")
fn create_cache_ets_table() -> Reference

@external(erlang, "hashi_ffi", "get_cached")
pub fn get_cached(cache: Cache) -> Result(String, Nil)

@external(erlang, "hashi_ffi", "replace_cached")
pub fn replace_cached(cache: Cache, page: String) -> Nil
