# Hashi

A little web app to play a new hashiwokakero puzzle daily.

## Development

To manage our environment we use [`direnv`](https://direnv.net), if you have
that installed you will be able to run some commands from the projects root:

- `dev` builds the frontend application and starts the hashi server to serve it.
- `build` builds the frontend application and exports the erlang deployment that
  can be used to deploy the server.
