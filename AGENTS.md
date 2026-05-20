# Repository Guidelines

## Project Structure & Module Organization

This repository contains a local meeting-search app built with Hono, SQLite, and FTS5. Server code lives in `src/`: `server.ts` defines HTTP routes, `archive.ts` handles ingest, `search.ts` owns search behavior, `db/local.ts` wraps `node:sqlite`, and `parsing/` contains archive, summary, and VTT parsers. The browser UI is in `ui/`, with shared client helpers in `ui/api.js` and `ui/shared.js`. Tests live in `test/*.test.ts`. `schema.sql` is the source of truth for local SQLite tables and virtual FTS tables. `supabase/` is legacy reference material, not the active local app path.

## Build, Test, and Development Commands

- `npm install`: install runtime and TypeScript dependencies.
- `npm run dev` or `npm start`: run the Hono server at `http://localhost:8787`.
- `npm test`: run all Node test files under `test/`.
- `npm run typecheck`: run `tsc --noEmit`.
- `API_URL=http://localhost:8787 ./utils/batch_insert_archive.sh utils/meetings.csv`: import archive rows into the local server.

The app requires Node 25 or newer for direct TypeScript execution and `node:sqlite`.

## Coding Style & Naming Conventions

Use TypeScript ES modules in `src/` and keep imports explicit with `.ts` extensions. Follow the existing style: two-space indentation in SQL blocks, no semicolons in TypeScript, single quotes, and small focused functions. Use camelCase for functions and variables, PascalCase for exported types, and descriptive test names. Keep SQLite SQL parameterized with `?` placeholders; do not interpolate user input into SQL.

## Testing Guidelines

Tests use Node’s built-in `node:test` plus `node:assert/strict`. Add tests near the behavior being changed, usually in `test/search.test.ts`, `test/archive.test.ts`, or `test/postgrest.test.ts`. Prefer temporary SQLite databases with `mkdtempSync(...)` so tests are isolated. For search or ingest changes, cover both the direct function and the API route when the route behavior changes.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects, such as `Add date search` or `Reduce cron frequency`. Keep commits focused and avoid mixing UI, schema, and unrelated cleanup unless the feature requires it. Pull requests should describe the user-visible behavior, list verification commands run, and include screenshots for UI changes when useful. Mention schema changes explicitly because `schema.sql` affects local database creation.

## Security & Configuration Tips

Local data is stored in `data/meetings.sqlite` by default; tests should override this with temporary paths or `SQLITE_PATH`. Do not commit generated databases, secrets, or local Supabase temp state. Treat `supabase/` migrations as historical reference unless a task explicitly targets the legacy stack.
