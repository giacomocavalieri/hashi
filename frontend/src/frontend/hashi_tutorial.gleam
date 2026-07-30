import frontend/hashi_grid
import gleam/dict
import gleam/int
import gleam/set
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import shared/hashi

pub fn main() -> Result(lustre.Runtime(Message), lustre.Error) {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}

// MODEL -----------------------------------------------------------------------

pub opaque type Model {
  Tutorial(step: Step)
  CompletedTutorial
}

type Step {
  Step1(description: String, grid: hashi_grid.Model)
  Step2(description: String, grid: hashi_grid.Model)
  Step3(description: String, grid: hashi_grid.Model)
  Step4(description: String, grid: hashi_grid.Model)
  Step5(description: String, grid: hashi_grid.Model)
}

fn step_1() -> Step {
  let first = #(1, 3)
  let second = #(5, 3)

  Step1(
    "These are islands. Click on one and move to the other to build a bridge between them.",
    grid: hashi_grid.init(hashi_grid.InitState(
      puzzle: hashi.from_islands_and_connections(
        width: 7,
        height: 7,
        islands: set.from_list([first, second]),
        connections: [#(first, second, hashi.Single)],
      ),
      connections: dict.new(),
    )),
  )
}

fn step_2() -> Step {
  let first = #(1, 3)
  let second = #(5, 3)

  Step2(
    "Islands can be connected by at most two bridges. Try and draw another one.",
    grid: hashi_grid.init(hashi_grid.InitState(
      puzzle: hashi.from_islands_and_connections(
        width: 7,
        height: 7,
        islands: set.from_list([first, second]),
        connections: [#(first, second, hashi.Double)],
      ),
      connections: dict.from_list([
        #(first, dict.from_list([#(second, hashi.Single)])),
        #(second, dict.from_list([#(first, hashi.Single)])),
      ]),
    )),
  )
}

fn step_3() -> Step {
  let first = #(0, 3)
  let second = #(3, 3)
  let third = #(6, 3)

  Step3(
    "Each island has a number. That's how many bridges it needs to have.",
    grid: hashi_grid.init(hashi_grid.InitState(
      puzzle: hashi.from_islands_and_connections(
        width: 7,
        height: 7,
        islands: set.from_list([first, second, third]),
        connections: [
          #(first, second, hashi.Single),
          #(second, third, hashi.Single),
        ],
      ),
      connections: dict.new(),
    )),
  )
}

fn step_4() -> Step {
  let first = #(1, 1)
  let second = #(5, 1)
  let third = #(1, 5)
  let fourth = #(5, 5)
  Step4(
    "You can click on a bridge to remove it.",
    grid: hashi_grid.init(hashi_grid.InitState(
      puzzle: hashi.from_islands_and_connections(
        width: 7,
        height: 7,
        islands: set.from_list([first, second, third, fourth]),
        connections: [
          #(first, second, hashi.Double),
          #(second, fourth, hashi.Single),
          #(first, third, hashi.Single),
        ],
      ),
      connections: dict.from_list([
        #(
          first,
          dict.from_list([
            #(second, hashi.Double),
            #(third, hashi.Single),
          ]),
        ),
        #(
          second,
          dict.from_list([
            #(first, hashi.Double),
            #(fourth, hashi.Single),
          ]),
        ),
        #(
          third,
          dict.from_list([
            #(first, hashi.Single),
            #(fourth, hashi.Double),
          ]),
        ),
        #(
          fourth,
          dict.from_list([
            #(second, hashi.Single),
            #(third, hashi.Double),
          ]),
        ),
      ]),
    )),
  )
}

fn step_5() -> Step {
  Step5(
    "To win all islands must be connected and have the right number of bridges.",
    grid: hashi_grid.init(hashi_grid.InitState(
      puzzle: hashi.new(width: 7, height: 7, islands: 8)
        |> hashi.with_seed(12)
        |> hashi.generate,
      connections: dict.from_list([]),
    )),
  )
}

pub fn init(_nil: Nil) -> #(Model, Effect(Message)) {
  let model = Tutorial(step_1())
  let effect = effect.none()
  #(model, effect)
}

fn next_step(model: Model) -> Model {
  case model {
    Tutorial(Step1(..)) -> Tutorial(step_2())
    Tutorial(Step2(..)) -> Tutorial(step_3())
    Tutorial(Step3(..)) -> Tutorial(step_4())
    Tutorial(Step4(..)) -> Tutorial(step_5())
    Tutorial(Step5(..)) -> CompletedTutorial
    CompletedTutorial -> CompletedTutorial
  }
}

// UPDATE ----------------------------------------------------------------------

pub type Message {
  GridProducedMessage(hashi_grid.Message)
  TimeoutExpired
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message, model {
    GridProducedMessage(message), Tutorial(step) -> {
      use <- skip_if_complete(model)
      let #(grid, effect) = hashi_grid.update(step.grid, message)
      let model = set_grid(model, grid)
      let effect = effect.map(effect, GridProducedMessage)
      let other_effects = case hashi_grid.is_complete(grid) {
        True -> [after(1000, fn() { TimeoutExpired })]
        False -> []
      }
      let effect = effect.batch([effect, ..other_effects])
      #(model, effect)
    }

    GridProducedMessage(_), CompletedTutorial -> {
      #(model, effect.none())
    }

    TimeoutExpired, _ -> {
      let model = next_step(model)
      let effect = effect.none()
      #(model, effect)
    }
  }
}

fn skip_if_complete(
  model: Model,
  run: fn() -> #(Model, Effect(Message)),
) -> #(Model, Effect(Message)) {
  case model {
    CompletedTutorial -> #(model, effect.none())
    Tutorial(step:) ->
      case hashi_grid.is_complete(step.grid) {
        True -> #(model, effect.none())
        False -> run()
      }
  }
}

fn set_grid(model: Model, grid: hashi_grid.Model) -> Model {
  case model {
    Tutorial(Step1(..) as step) -> Tutorial(Step1(..step, grid:))
    Tutorial(Step2(..) as step) -> Tutorial(Step2(..step, grid:))
    Tutorial(Step3(..) as step) -> Tutorial(Step3(..step, grid:))
    Tutorial(Step4(..) as step) -> Tutorial(Step4(..step, grid:))
    Tutorial(Step5(..) as step) -> Tutorial(Step5(..step, grid:))
    CompletedTutorial -> CompletedTutorial
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

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Message) {
  case model {
    Tutorial(step:) ->
      html.main([attribute.class("center stack")], [
        html.div([attribute.class("center")], [
          html.h1([], [html.text("Hashi tutorial")]),
          html.h2([], [html.text(int.to_string(step_number(step)) <> " / 5")]),
        ]),
        html.h3([], [html.text(step.description)]),
        hashi_grid.view(step.grid)
          |> element.map(GridProducedMessage),
        complete_tutorial_form("Skip tutorial"),
      ])

    CompletedTutorial ->
      html.main([attribute.class("center stack")], [
        html.div([attribute.class("center")], [
          html.h1([], [html.text("Hashi tutorial")]),
        ]),
        html.h3([], [
          html.text(
            "You've completed the tutorial, well done! You're ready to start playing now.",
          ),
        ]),
        complete_tutorial_form("Start playing"),
      ])
  }
}

fn complete_tutorial_form(text: String) -> Element(message) {
  html.form([attribute.action("/tutorial"), attribute.method("post")], [
    html.input([
      attribute.class("button"),
      attribute.type_("submit"),
      attribute.value(text),
    ]),
  ])
}

fn step_number(step: Step) -> Int {
  case step {
    Step1(..) -> 1
    Step2(..) -> 2
    Step3(..) -> 3
    Step4(..) -> 4
    Step5(..) -> 5
  }
}
