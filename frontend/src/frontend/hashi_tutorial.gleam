import frontend/hashi_grid
import gleam/dict
import gleam/int
import gleam/list
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
  Model(steps: List(#(Int, Step)), total_steps: Int)
}

type Step {
  Step(description: String, grid: hashi_grid.Model)
}

fn how_to_draw_a_bridge() -> Step {
  let first = #(1, 3)
  let second = #(5, 3)

  Step(
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

fn how_to_draw_a_double_bridge() -> Step {
  let first = #(1, 3)
  let second = #(5, 3)

  Step(
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

fn what_the_island_number_is() -> Step {
  let first = #(0, 3)
  let second = #(3, 3)
  let third = #(6, 3)

  Step(
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

fn how_to_remove_a_bridge() -> Step {
  let first = #(1, 1)
  let second = #(5, 1)
  let third = #(1, 5)
  let fourth = #(5, 5)
  Step(
    "You can click on a bridge to remove it. Remove the excess bridges.",
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

fn bridges_cannot_be_diagonal_or_cross() -> Step {
  let first = #(5, 5)
  let second = #(5, 3)
  let third = #(1, 3)
  let fourth = #(1, 1)

  Step(
    description: "Bridges cannot go in diagonal or cross each other.",
    grid: hashi_grid.init(hashi_grid.InitState(
      puzzle: hashi.from_islands_and_connections(
        width: 7,
        height: 7,
        islands: set.from_list([first, second, third, fourth]),
        connections: [
          #(first, second, hashi.Single),
          #(second, third, hashi.Single),
          #(third, fourth, hashi.Single),
        ],
      ),
      connections: dict.new(),
    )),
  )
}

fn how_to_win() -> Step {
  Step(
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
  let steps = [
    how_to_draw_a_bridge(),
    how_to_draw_a_double_bridge(),
    what_the_island_number_is(),
    how_to_remove_a_bridge(),
    bridges_cannot_be_diagonal_or_cross(),
    how_to_win(),
  ]

  let model =
    Model(
      steps: list.index_map(steps, fn(step, index) { #(index, step) }),
      total_steps: list.length(steps),
    )

  let effect = effect.none()
  #(model, effect)
}

// UPDATE ----------------------------------------------------------------------

pub type Message {
  GridProducedMessage(hashi_grid.Message)
  TimeoutExpired
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message, model {
    GridProducedMessage(message), Model(steps: [#(_, step), ..], ..) -> {
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

    GridProducedMessage(_), Model(steps: [], ..) -> {
      #(model, effect.none())
    }

    TimeoutExpired, _ -> {
      let model = Model(..model, steps: list.drop(model.steps, 1))
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
    Model(steps: [], ..) -> #(model, effect.none())
    Model(steps: [#(_step_number, step), ..], ..) ->
      case hashi_grid.is_complete(step.grid) {
        True -> #(model, effect.none())
        False -> run()
      }
  }
}

fn set_grid(model: Model, grid: hashi_grid.Model) -> Model {
  case model {
    Model(steps: [#(n, step), ..steps], ..) ->
      Model(..model, steps: [#(n, Step(..step, grid:)), ..steps])
    Model(steps: [], ..) -> model
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
  let title = "🛟 Hashi tutorial"

  case model {
    Model(steps: [#(step_number, step), ..], total_steps:) ->
      html.main([attribute.class("center stack")], [
        html.div([attribute.class("center")], [
          html.h1([], [html.text(title)]),
          html.h2([], [
            html.text(
              int.to_string(step_number) <> " / " <> int.to_string(total_steps),
            ),
          ]),
        ]),
        html.p([], [html.text(step.description)]),
        hashi_grid.view(step.grid)
          |> element.map(GridProducedMessage),
        complete_tutorial_form("Skip tutorial"),
      ])

    Model(steps: [], ..) ->
      html.main([attribute.class("center stack")], [
        html.h1([], [html.text(title)]),
        html.p([], [
          html.text(
            "You've completed the tutorial, well done! You're ready to start playing now.",
          ),
        ]),
        complete_tutorial_form("Start playing"),
      ])
  }
}

fn complete_tutorial_form(text: String) -> Element(message) {
  html.form([attribute.method("post")], [
    html.input([
      attribute.class("button"),
      attribute.type_("submit"),
      attribute.value(text),
    ]),
  ])
}
