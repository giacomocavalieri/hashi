pub opaque type History(a) {
  History(previous: List(a), current: a, future: List(a))
}

pub fn new(from value: a) -> History(a) {
  History(previous: [], current: value, future: [])
}

pub fn current(history: History(a)) -> a {
  history.current
}

pub fn delete(history: History(a)) -> History(a) {
  History(previous: [], current: history.current, future: [])
}

pub fn push(to history: History(a), new value: a) -> History(a) {
  let History(previous:, current:, future: _) = history
  History(previous: [current, ..previous], current: value, future: [])
}

pub fn step_back(history: History(a)) -> History(a) {
  case history {
    History(previous: [], ..) -> history
    History(previous: [new_current, ..previous], current:, future:) ->
      History(previous:, current: new_current, future: [current, ..future])
  }
}

pub fn step_forward(history: History(a)) -> History(a) {
  case history {
    History(future: [], ..) -> history
    History(previous:, current:, future: [new_current, ..future]) ->
      History(previous: [current, ..previous], current: new_current, future:)
  }
}

pub fn can_step_back(history: History(a)) -> Bool {
  history.previous != []
}

pub fn can_step_forward(history: History(a)) -> Bool {
  history.future != []
}
