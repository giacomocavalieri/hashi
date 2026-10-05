import gleam/time/calendar.{
  April, August, December, February, January, July, June, March, May, November,
  October, September,
}

pub type DayOfWeek {
  Monday
  Tuesday
  Wednesday
  Thursday
  Friday
  Saturday
  Sunday
}

pub fn day_of_the_week(date: calendar.Date) -> DayOfWeek {
  let calendar.Date(year:, month:, day:) = date
  case do_day_of_the_week(year, calendar.month_to_int(month), day) {
    1 -> Monday
    2 -> Tuesday
    3 -> Wednesday
    4 -> Thursday
    5 -> Friday
    6 -> Saturday
    _ -> Sunday
  }
}

pub fn next_day(date: calendar.Date) -> calendar.Date {
  let calendar.Date(year:, month:, day:) = date
  let last_day_of_month = last_day_of_month(month, year)
  case day == last_day_of_month {
    False -> calendar.Date(year:, month:, day: day + 1)
    True ->
      case month {
        January -> calendar.Date(year:, month: February, day: 1)
        February -> calendar.Date(year:, month: March, day: 1)
        March -> calendar.Date(year:, month: April, day: 1)
        April -> calendar.Date(year:, month: May, day: 1)
        May -> calendar.Date(year:, month: June, day: 1)
        June -> calendar.Date(year:, month: July, day: 1)
        July -> calendar.Date(year:, month: August, day: 1)
        August -> calendar.Date(year:, month: September, day: 1)
        September -> calendar.Date(year:, month: October, day: 1)
        October -> calendar.Date(year:, month: November, day: 1)
        November -> calendar.Date(year:, month: December, day: 1)
        December -> calendar.Date(year: year + 1, month: January, day: 1)
      }
  }
}

pub fn previous_day(date: calendar.Date) -> calendar.Date {
  let calendar.Date(year:, month:, day:) = date
  case day == 1 {
    False -> calendar.Date(year:, month:, day: day - 1)
    True ->
      case month {
        January ->
          calendar.Date(
            year: year - 1,
            month: December,
            day: last_day_of_month(December, year - 1),
          )
        February ->
          calendar.Date(
            year:,
            month: January,
            day: last_day_of_month(January, year),
          )
        March ->
          calendar.Date(
            year:,
            month: February,
            day: last_day_of_month(February, year),
          )
        April ->
          calendar.Date(
            year:,
            month: March,
            day: last_day_of_month(March, year),
          )
        May ->
          calendar.Date(
            year:,
            month: April,
            day: last_day_of_month(April, year),
          )
        June ->
          calendar.Date(year:, month: May, day: last_day_of_month(May, year))
        July ->
          calendar.Date(year:, month: June, day: last_day_of_month(June, year))
        August ->
          calendar.Date(year:, month: July, day: last_day_of_month(July, year))
        September ->
          calendar.Date(
            year:,
            month: October,
            day: last_day_of_month(August, year),
          )
        October ->
          calendar.Date(
            year:,
            month: September,
            day: last_day_of_month(September, year),
          )
        November ->
          calendar.Date(
            year:,
            month: October,
            day: last_day_of_month(October, year),
          )
        December ->
          calendar.Date(
            year: year + 1,
            month: November,
            day: last_day_of_month(November, year),
          )
      }
  }
}

fn last_day_of_month(month: calendar.Month, year: Int) -> Int {
  case month {
    January | March | May | July | August | October | December -> 31
    November | April | June | September -> 30
    February ->
      case calendar.is_leap_year(year) {
        True -> 29
        False -> 28
      }
  }
}

@external(erlang, "calendar", "day_of_the_week")
fn do_day_of_the_week(year: Int, month: Int, day: Int) -> Int
