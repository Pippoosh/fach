package main

import "core:fmt"
import "core:os"
import "core:strings"
import bnml "vendor/bnml"

Visit :: struct {
	private: bool,
	name:    string,
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

usage :: proc() {
	fmt.eprintln("Usage: fach <init|run|get|dep|list> [args...]")
}

INIT_FACH_BNML :: `; A new fach.bnml
0 project

0 deps

0 entrypoints
`

cmd_init :: proc() {
	need_args("init", 2)
	if os.exists("fach.bnml") {
		die("fach.bnml already exists")
	}
	if err := os.write_entire_file("fach.bnml", INIT_FACH_BNML); err != nil {
		die("Error writing fach.bnml: %v", err)
	}
	fmt.println("Wrote fach.bnml")
}

main :: proc() {
	if len(os.args) < 2 {
		usage()
		os.exit(1)
	}

	if os.args[1] == "init" {
		cmd_init()
		return
	}

	lines, data, err := bnml.read_lines("fach.bnml")
	if err != .None {
		die("Error reading fach.bnml: %v", err)
	}
	defer {
		delete(lines)
		delete(data)
	}
	bnml.strip(&lines)

	roots, parse_err := bnml.parse(lines[:])
	if parse_err != .None {
		die("Error parsing fach.bnml: %v", parse_err)
	}
	defer bnml.destroy_tree(&roots)

	project := find_child(roots[:], "project")
	deps := find_child(roots[:], "deps")
	entrypoints := find_child(roots[:], "entrypoints")
	private := find_child(roots[:], "private")

	switch os.args[1] {
	case "run":
		need_args("run", 3)
		if project == nil || entrypoints == nil {
			die("Invalid schema: missing 'project' or 'entrypoints'")
		}
		code := exec_entrypoint(entrypoints, project, private, os.args[2])
		if code != 0 {
			os.exit(code)
		}
	case "get":
		need_args("get", 3)
		if project == nil {
			die("Invalid schema: missing 'project'")
		}
		fmt.println(find_path_value(project, os.args[2]))
	case "dep":
		need_args("dep", 2)
		if deps == nil {
			die("Invalid schema: missing 'deps'")
		}

		fmt.println("Dependencies:")
		for dep in deps.children {
			hint := strings.trim_space(dep.value)
			if hint != "" {
				fmt.printfln("  %-16s %s", dep.key, hint)
			} else {
				fmt.printfln("  %s", dep.key)
			}
		}

	case "list":
		need_args("list", 2)
		if entrypoints == nil {
			die("Invalid schema: missing 'entrypoints'")
		}

		fmt.println("Entrypoints:")
		for entrypoint in entrypoints.children {
			description := strings.trim_space(entrypoint.value)
			if description != "" {
				fmt.printfln("  %-16s %s", entrypoint.key, description)
			} else {
				fmt.printfln("  %s", entrypoint.key)
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

find_child :: proc(nodes: []^bnml.Node, key: string) -> ^bnml.Node {
	for node in nodes {
		if node.key == key {
			return node
		}
	}
	return nil
}

require_child :: proc(parent: ^bnml.Node, name: string, what: string) -> ^bnml.Node {
	if parent == nil {
		die("Unknown %s: %s", what, name)
	}
	node := find_child(parent.children[:], name)
	if node == nil {
		die("Unknown %s: %s", what, name)
	}
	return node
}

command_text :: proc(node: ^bnml.Node) -> string {
	if node.value == "" {
		return strings.clone(node.key)
	}
	return fmt.aprintf("%s: %s", node.key, node.value)
}

delete_strings :: proc(items: [dynamic]string) {
	for item in items {
		delete(item)
	}
	delete(items)
}

find_path_value :: proc(root: ^bnml.Node, loc: string) -> string {
	trimmed := strings.trim_space(loc)
	if root == nil || trimmed == "" {
		die("Missing project value: %s", loc)
	}

	parts := strings.split(trimmed, ".")
	defer delete(parts)

	node := root
	for part in parts {
		if part == "" {
			die("Missing project value: %s", loc)
		}
		child := find_child(node.children[:], part)
		if child == nil {
			die("Missing project value: %s", loc)
		}
		node = child
	}
	if len(node.children) > 0 {
		die("Missing project value: %s", loc)
	}
	return strings.trim_space(node.value)
}

sh_quote :: proc(s: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '\'')
	for r in s {
		if r == '\'' {
			strings.write_string(&b, `'"'"'`)
		} else {
			strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

wrap_regardless :: proc(cmds, rgds: string) -> string {
	q_cmds := sh_quote(cmds)
	defer delete(q_cmds)
	q_rgds := sh_quote(rgds)
	defer delete(q_rgds)
	return fmt.aprintf("(eval %s; _fach_ec=$?; (eval %s); exit $_fach_ec)", q_cmds, q_rgds)
}

// {{path}} is a quoted project value. [[ is a literal [.
substitute :: proc(raw: string, project: ^bnml.Node) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	i := 0
	for i < len(raw) {
		var_at := strings.index(raw[i:], "{{")
		esc_at := strings.index(raw[i:], "[[")

		next := -1
		is_var := false
		if var_at != -1 && (esc_at == -1 || var_at <= esc_at) {
			next = i + var_at
			is_var = true
		} else if esc_at != -1 {
			next = i + esc_at
		}

		if next == -1 {
			strings.write_string(&b, raw[i:])
			break
		}

		strings.write_string(&b, raw[i:next])
		if is_var {
			end := strings.index(raw[next:], "}}")
			if end == -1 {
				strings.write_string(&b, raw[next:])
				break
			}
			path := strings.trim_space(raw[next + 2:next + end])
			quoted := sh_quote(find_path_value(project, path))
			defer delete(quoted)
			strings.write_string(&b, quoted)
			i = next + end + 2
		} else {
			strings.write_byte(&b, '[')
			i = next + 2
		}
	}

	return strings.clone(strings.to_string(b))
}

parse_whole_ref :: proc(raw: string) -> (name: string, private: bool, ok: bool) {
	s := strings.trim_space(raw)
	if strings.has_prefix(s, "[[") && strings.has_suffix(s, "]]") && len(s) >= 4 {
		return strings.trim_space(s[2:len(s) - 2]), true, true
	}
	if strings.has_prefix(s, "[") && strings.has_suffix(s, "]") && len(s) >= 2 {
		return strings.trim_space(s[1:len(s) - 1]), false, true
	}
	return "", false, false
}

resolve_line :: proc(
	raw: string,
	project: ^bnml.Node,
	entrypoints: ^bnml.Node,
	private: ^bnml.Node,
	visited: ^[dynamic]Visit,
) -> string {
	if name, is_private, ok := parse_whole_ref(raw); ok {
		if is_private {
			return build_entrypoint(
				require_child(private, name, "private"),
				project,
				entrypoints,
				private,
				visited,
				true,
			)
		}
		return build_entrypoint(
			require_child(entrypoints, name, "entrypoint"),
			project,
			entrypoints,
			private,
			visited,
			false,
		)
	}
	return substitute(raw, project)
}

build_entrypoint :: proc(
	ep: ^bnml.Node,
	project: ^bnml.Node,
	entrypoints: ^bnml.Node,
	private: ^bnml.Node,
	visited: ^[dynamic]Visit,
	is_private: bool,
) -> string {
	own: [dynamic]Visit
	defer delete(own)
	v := visited
	if v == nil {
		v = &own
	}

	for item in v^ {
		if item.private == is_private && item.name == ep.key {
			die("Circular dependency: %s", ep.key)
		}
	}
	append(v, Visit{private = is_private, name = ep.key})
	defer pop(v)

	cmds_node: ^bnml.Node
	rgds_node: ^bnml.Node
	for child in ep.children {
		switch child.key {
		case "cmds":
			if cmds_node != nil {
				die("Invalid entrypoint '%s': duplicate cmds", ep.key)
			}
			cmds_node = child
		case "regardless":
			if rgds_node != nil {
				die("Invalid entrypoint '%s': duplicate regardless", ep.key)
			}
			rgds_node = child
		case:
			die("Invalid entrypoint '%s': unexpected '%s'", ep.key, child.key)
		}
	}
	if cmds_node == nil || len(cmds_node.children) == 0 {
		die("Invalid entrypoint '%s': missing cmds", ep.key)
	}

	cmds := make([dynamic]string)
	defer delete_strings(cmds)
	for child in cmds_node.children {
		line := command_text(child)
		defer delete(line)
		append(&cmds, resolve_line(line, project, entrypoints, private, v))
	}
	full := strings.join(cmds[:], " && ")

	if rgds_node != nil && len(rgds_node.children) > 0 {
		rgds := make([dynamic]string)
		defer delete_strings(rgds)
		for child in rgds_node.children {
			line := command_text(child)
			defer delete(line)
			append(&rgds, resolve_line(line, project, entrypoints, private, v))
		}
		joined := strings.join(rgds[:], "; ")
		defer delete(joined)
		wrapped := wrap_regardless(full, joined)
		delete(full)
		full = wrapped
	}

	return full
}

exec_entrypoint :: proc(
	entrypoints: ^bnml.Node,
	project: ^bnml.Node,
	private: ^bnml.Node,
	name: string,
) -> int {
	full := build_entrypoint(
		require_child(entrypoints, name, "entrypoint"),
		project,
		entrypoints,
		private,
		nil,
		false,
	)
	defer delete(full)

	process, process_err := os.process_start(
		{
			command = {"/bin/sh", "-c", full},
			stdout = os.stdout,
			stderr = os.stderr,
			stdin = os.stdin,
		},
	)
	if process_err != nil {
		die("OS error: %v", process_err)
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		die("OS error: %v", wait_err)
	}
	return int(state.exit_code)
}
