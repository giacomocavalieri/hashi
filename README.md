# 🏝️ Hashi

A little web app to play a new hashiwokakero puzzle daily.
You can play this live at
[hashi.giacomocavalieri.me](https://hashi.giacomocavalieri.me).

---

This is a full stack web app written in [Gleam](https://gleam.run). It includes:

- `backend`: the server generating a new unique puzzle each day and serving it.
- `frontend`: the interactive web applications to play the daily puzzle and the
  interactive tutorial.
- `shared`: the hashi puzzle generation logic and some other stuff shared by the
  backend and frontend.

## Development

To manage our environment we use [`direnv`](https://direnv.net), if you have
that installed you will be able to run some commands from the projects root:

- `dev` builds the frontend application and starts the hashi server to serve it.
- `build` builds the frontend application and exports the erlang deployment that
  can be used to deploy the server.

After running `build` you can start the server running
`./backend/build/erlang-shipment/entrypoint.sh` (you'll need to have Erlang
installed)!

> I really don't like LLMs and you won't see me using those to generate any kind
> of creative work, code included.
> Please, don't use those tools to write issues or PRs to this project!
