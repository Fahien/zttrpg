# ZTTRPG

ZTTRPG is a web application for a tabletop role-playing game (TTRPG). It is written in Zig and stores its data in PostgreSQL. The server keeps a roster of characters. A browser page shows the roster and adds new characters.

## Requirements

- Zig 0.16.0
- PostgreSQL, with a local database named `zttrpg`

The build system downloads and compiles libpq. You do not install libpq yourself.

## Setup

1. Start PostgreSQL.
2. Create the database:

   ```sh
   createdb zttrpg
   ```

3. Apply the database migrations:

   ```sh
   zig build migration
   ```

The migration tool runs each `.sql` file in the `db/` directory in name order. It records each applied file in the `schema_migrations` table. It does not run a file twice.

## Run

Run the server from the repository root:

```sh
zig build run
```

The server listens on `http://127.0.0.1:8080`. Open this address in a browser. The home page links to the characters page, which shows the roster and a form to add a character.

Note: the server reads static files from `src/web/`, relative to the current directory. If you start the binary from a different directory, static files do not load.

## Test

Run all tests:

```sh
zig build test
```

## Pages

The server serves three kinds of page and asset:

| Path | Content |
|---|---|
| `/` | The home page. It links to the characters page. |
| `/characters` | The characters page: the roster table and the form to add a character. |
| `/static/{file}` | A file from `src/web/static/`, such as the CSS and the JavaScript. |

## HTTP API

A character has an `id`, a `name`, and a `level` from 1 to 100. The API uses JSON.

The `/characters` path returns two different representations. If the request has the header `Accept: application/json`, the server returns the roster as JSON. If it does not, the server returns the characters page as HTML. The other paths always return JSON.

Note: the server compares the `Accept` header with the exact text `application/json`. A list of several media types, such as `application/json, */*`, does not match.

| Method | Path | Action |
|---|---|---|
| GET | `/characters` | List all characters. |
| POST | `/characters` | Create a character from a JSON body. Returns status 201 and the new character. |
| GET | `/characters/{id}` | Get one character. |
| PUT | `/characters/{id}` | Replace the name and the level of one character. |
| DELETE | `/characters/{id}` | Delete one character. |

The server returns status 400 for an invalid body, 404 for an unknown ID, and 405 for a method that the path does not support.

Examples:

```sh
# Get the roster as JSON.
curl -H "Accept: application/json" http://127.0.0.1:8080/characters

# Create a character.
curl -X POST http://127.0.0.1:8080/characters \
  -d '{"name": "Grog", "level": 3}'
```

## Project structure

| Path | Content |
|---|---|
| `src/main.zig` | HTTP server, routes, and request handlers. |
| `src/root.zig` | The `zttrpg` module: character types and database queries. |
| `src/pq.zig` | Minimal Zig bindings for libpq. |
| `src/migration.zig` | The migration tool. |
| `src/web/` | HTML pages, and the CSS and JavaScript in `static/`. |
| `db/` | SQL migration files. |

## License

MIT. See [LICENSE.md](LICENSE.md).
