import backend/calendar_extra.{
  Friday, Monday, Saturday, Sunday, Thursday, Tuesday, Wednesday,
}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/string
import gleam/time/calendar.{type Date}
import hashi

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
      |> hashi.with_double_bridge_ratio(0.5)
    Wednesday ->
      hashi.new(width: 7, height: 7, islands: 17)
      |> hashi.with_double_bridge_ratio(0.6)
    Thursday ->
      hashi.new(width: 8, height: 8, islands: 21)
      |> hashi.with_double_bridge_ratio(0.6)
    Friday ->
      hashi.new(width: 9, height: 9, islands: 25)
      |> hashi.with_double_bridge_ratio(0.7)
    Saturday ->
      hashi.new(width: 10, height: 10, islands: 30)
      |> hashi.with_double_bridge_ratio(0.7)
    Sunday ->
      hashi.new(width: 9, height: 9, islands: 26)
      |> hashi.with_double_bridge_ratio(0.6)
  }
}

/// Given the content of a daily puzzle file, this returns the options used to
/// generate such puzzle.
pub fn parse_options(file_content: BitArray) -> Result(hashi.Options, Nil) {
  case file_content {
    <<
      width:8-unsigned,
      height:8-unsigned,
      islands:8-unsigned,
      double_bridge_ratio:64-float,
      0:8,
      _:bits,
    >> ->
      hashi.new(width:, height:, islands:)
      |> hashi.with_double_bridge_ratio(double_bridge_ratio)
      |> Ok

    _ -> Error(Nil)
  }
}

/// Given the options used to generate a daily puzzle, this turns them into a
/// binary that can be written to the puzzle's file.
pub fn serialise_options(options: hashi.Options) -> BitArray {
  let hashi.Options(double_bridge_ratio:, width:, height:, islands:, seed: _) =
    options

  <<
    width:8,
    height:8,
    islands:8,
    double_bridge_ratio:64-float,
    0:8,
  >>
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
