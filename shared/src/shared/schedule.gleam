import gleam/time/calendar.{type Date}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import shared/calendar_extra

/// Given a day, this tells us when the _next_ puzzle is going to happen.
///
pub fn next_puzzle_time(today: Date) -> Timestamp {
  let time =
    calendar.TimeOfDay(hours: 8, minutes: 0, seconds: 0, nanoseconds: 0)
  timestamp.from_calendar(calendar_extra.next_day(today), time, offset())
}

/// Returns what today is for the generator. This is based on the Italian
/// offset!
pub fn today() -> Date {
  let #(today, _) = timestamp.to_calendar(timestamp.system_time(), offset())
  today
}

/// Returns the offset used to figure out time of generation and what "today"
/// means. This is the Italian offset +2 because I'm from Italy and it's the
/// most comfortable to me :)
fn offset() -> Duration {
  duration.hours(2)
}
