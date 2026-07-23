# With Language — Implementation Roadmap

- Language: D22 uniform keyed-map views + transparent origins + contextual Copy
  (**accepted 2026-07-23; implementation design and implementation still in
  progress; see spec v7.2 and `docs/decisions.md` D22**)

- App: Crux
- App: Weld (depends on Crux)
- App: Smallhold
- Migrate: Zlib
- Migrate: jq
- Migrate: SQLite
- Migrate: minicoro
- Feature: harden async engine (depends on minicoro)
- Feature: From Query Expressions (depends on JQ + SQLite)
