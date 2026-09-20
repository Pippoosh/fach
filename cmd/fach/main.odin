package main

import "core:fmt"
import "core:os"
import fach "../.."

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

die_err :: proc(err: fach.Error) -> ! {
	die("%s", err.text)
}

usage :: proc() {
	fmt.eprintln("Usage: fach <init|run|get|dep|list> [args...]")
}

load_config :: proc() -> fach.File {
	file, err := fach.load()
	if err.kind != .None {
		die_err(err)
	}
	return file
}

main :: proc() {
	if len(os.args) < 2 {
		usage()
		os.exit(1)
	}

	switch os.args[1] {
	case "init":
		need_args("init", 2)
		if err := fach.init(); err.kind != .None {
			die_err(err)
		}
		fmt.println("Wrote fach.bnml")

	case "run":
		need_args("run", 3)
		file := load_config()
		defer fach.destroy(&file)
		code, err := fach.run(file, os.args[2])
		if err.kind != .None {
			die_err(err)
		}
		if code != 0 {
			os.exit(code)
		}

	case "get":
		need_args("get", 3)
		file := load_config()
		defer fach.destroy(&file)
		value, err := fach.get(file, os.args[2])
		if err.kind != .None {
			die_err(err)
		}
		fmt.println(value)

	case "dep":
		need_args("dep", 2)
		file := load_config()
		defer fach.destroy(&file)
		deps, err := fach.list_deps(file)
		if err.kind != .None {
			die_err(err)
		}
		defer delete(deps)

		fmt.println("Dependencies:")
		for dep in deps {
			if dep.hint != "" {
				fmt.printfln("  %-16s %s", dep.name, dep.hint)
			} else {
				fmt.printfln("  %s", dep.name)
			}
		}

	case "list":
		need_args("list", 2)
		file := load_config()
		defer fach.destroy(&file)
		entrypoints, err := fach.list_entrypoints(file)
		if err.kind != .None {
			die_err(err)
		}
		defer delete(entrypoints)

		fmt.println("Entrypoints:")
		for entrypoint in entrypoints {
			if entrypoint.description != "" {
				fmt.printfln("  %-16s %s", entrypoint.name, entrypoint.description)
			} else {
				fmt.printfln("  %s", entrypoint.name)
			}
		}

	case:
		fmt.eprintln("Unknown command:", os.args[1])
		usage()
		os.exit(1)
	}
}

need_args :: proc(cmd: string, n: int) {
	if len(os.args) != n {
		if len(os.args) < n {
			fmt.eprintfln("Not enough args for '%s'", cmd)
		} else {
			fmt.eprintfln("Too many args for '%s'", cmd)
		}
		usage()
		os.exit(1)
	}
}
