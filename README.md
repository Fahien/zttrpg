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

The server listens on `http://127.0.0.1:8080`. Open this address in a browser to see the character roster.

Note: the server reads static files from `src/web/`, relative to the current directory. If you start the binary from a different directory, static files do not load.

## Test

Run all tests:

```sh
zig build test
```

## HTTP API

The API uses JSON. A character has an `id`, a `name`, and a `level` from 1 to 100.

| Method | Path | Action |
|---|---|---|
| GET | `/` | Serve the roster page. |
| GET | `/characters` | List all characters. |
| POST | `/characters` | Create a character from a JSON body. |
| GET | `/characters/{id}` | Get one character. |
| PUT | `/characters/{id}` | Update one character from a JSON body. |
| DELETE | `/characters/{id}` | Delete one character. |
| GET | `/static/{file}` | Serve a file from `src/web/static/`. |

Example:

```sh
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
| `src/web/` | HTML page, CSS, and JavaScript for the roster. |
| `db/` | SQL migration files. |

## License

MIT. See [LICENSE.md](LICENSE.md).
