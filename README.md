# fach

A small task runner. Commands live in `fach.bnml` next to your project.

```
fach init
fach run build
fach list
fach get name
fach dep
```

Requires [Odin](https://odin-lang.org/). Config is [BNML](https://github.com/Pippoosh/bnml).

## Build

From the repository root:

```sh
odin build . -out:fach
```

Put the binary on your `PATH`, or run it as `./fach`.

## `fach.bnml`

fach reads `fach.bnml` from the current directory. Blank lines and whole-line `;` comments are ignored. `fach init` writes a starter file instead of reading one.

| Command | Needs | What it does |
| --- | --- | --- |
| `fach init` | — | Write a starter `fach.bnml` (error if one already exists) |
| `fach run <name>` | `project`, `entrypoints` | Run a public entrypoint |
| `fach list` | `entrypoints` | List public entrypoints |
| `fach get <path>` | `project` | Print a leaf `project` value (`name`, `out.dir`, …) |
| `fach dep` | `deps` | List `deps` |

`private` is optional. `run` only takes a public name; a public entrypoint can inline a private one with `[[name]]`.

```
0 project
1 name: hello
1 version: 0.1.0

0 deps
1 odin: The Odin compiler

0 entrypoints
1 build: compile the binary
2 cmds
3 odin build . -out:{{name}}
2 regardless
3 echo done

0 private
1 clean
2 cmds
3 rm -rf {{name}}
```

See `examples/fach.bnml` for a fuller file.

### Entrypoints

Each public or private entrypoint has `cmds` (required) and optional `regardless` (always runs after `cmds`; every `regardless` line runs; the exit code is still that of `cmds`). `cmds` share one shell, so `cd` and `export` persist into later cmds and into `regardless`.

The optional value on the entrypoint line (`1 build: compile the binary`) is a description for `fach list`. The same pattern on a dep is a hint for `fach dep`.

Command text is the BNML key. If you need a colon in the command, write it as `key: value` — BNML splits on the first unescaped colon, and fach joins the key and value back with `: `.

Inside commands:

- `{{path}}` — substitute a leaf `project` value (quoted for the shell). Dots walk children: `{{out.dir}}`
- `[name]` — as a whole command, inline that public entrypoint
- `[[name]]` — as a whole command, inline a `private` entrypoint
- `[[` — a literal `[`

`[name]` and `[[name]]` only inline when the whole line is that ref. `cd src && [build]` is not an inline; use two children (`cd src`, then `[build]`).

Public and private inlines share a cycle check. Missing values, missing entrypoints, and missing privates are errors.

## Layout

```
main.odin     CLI
examples/     sample fach.bnml
vendor/bnml/  BNML parser (https://github.com/Pippoosh/bnml)
```
