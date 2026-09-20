package fach

import "core:fmt"
import "core:os"
import "core:strings"
import bnml "vendor/bnml"

CONFIG_FILE :: "fach.bnml"

STARTER :: `; A new fach.bnml
0 project

0 deps

0 entrypoints
`

Error_Kind :: enum {
	None = 0,
	Already_Exists,
	Write_Failed,
	Read_Failed,
	Parse_Failed,
	Missing_Schema,
	Unknown_Name,
	Missing_Value,
	Circular_Dependency,
	Invalid_Entrypoint,
	OS_Error,
}

Error :: struct {
	kind: Error_Kind,
	text: string,
}

File :: struct {
	lines:       [dynamic]string,
	data:        []byte,
	roots:       [dynamic]^bnml.Node,
	project:     ^bnml.Node,
	deps:        ^bnml.Node,
	entrypoints: ^bnml.Node,
	private:     ^bnml.Node,
}

Dep :: struct {
	name: string,
	hint: string,
}

Entrypoint :: struct {
	name:        string,
	description: string,
}

@(private)
Visit :: struct {
	private: bool,
	name:    string,
}

@(private)
fail :: proc(kind: Error_Kind, format: string, args: ..any) -> Error {
	return Error{kind = kind, text = fmt.aprintf(format, ..args)}
}

init :: proc(path := CONFIG_FILE) -> Error {
	if os.exists(path) {
		return fail(.Already_Exists, "%s already exists", path)
	}
	if err := os.write_entire_file(path, STARTER); err != nil {
		return fail(.Write_Failed, "Error writing %s: %v", path, err)
	}
	return {}
}

load :: proc(path := CONFIG_FILE) -> (file: File, err: Error) {
	lines, data, read_err := bnml.read_lines(path)
	if read_err != .None {
		return {}, fail(.Read_Failed, "Error reading %s: %v", path, read_err)
	}

	bnml.strip(&lines)

	roots, parse_err := bnml.parse(lines[:])
	if parse_err != .None {
		delete(lines)
		delete(data)
		return {}, fail(.Parse_Failed, "Error parsing %s: %v", path, parse_err)
	}

	return File{
		lines = lines,
		data = data,
		roots = roots,
		project = find_child(roots[:], "project"),
		deps = find_child(roots[:], "deps"),
		entrypoints = find_child(roots[:], "entrypoints"),
		private = find_child(roots[:], "private"),
	}, {}
}

destroy :: proc(file: ^File) {
	delete(file.lines)
	delete(file.data)
	bnml.destroy_tree(&file.roots)
	file^ = {}
}

get :: proc(file: File, path: string) -> (string, Error) {
	if file.project == nil {
		return "", fail(.Missing_Schema, "Invalid schema: missing 'project'")
	}
	return find_path_value(file.project, path)
}

list_deps :: proc(file: File, allocator := context.allocator) -> ([]Dep, Error) {
	if file.deps == nil {
		return nil, fail(.Missing_Schema, "Invalid schema: missing 'deps'")
	}

	items := make([]Dep, len(file.deps.children), allocator)
	for dep, i in file.deps.children {
		items[i] = Dep {
			name = dep.key,
			hint = strings.trim_space(dep.value),
		}
	}
	return items, {}
}

list_entrypoints :: proc(file: File, allocator := context.allocator) -> ([]Entrypoint, Error) {
	if file.entrypoints == nil {
		return nil, fail(.Missing_Schema, "Invalid schema: missing 'entrypoints'")
	}

	items := make([]Entrypoint, len(file.entrypoints.children), allocator)
	for entrypoint, i in file.entrypoints.children {
		items[i] = Entrypoint {
			name = entrypoint.key,
			description = strings.trim_space(entrypoint.value),
		}
	}
	return items, {}
}

run :: proc(file: File, name: string) -> (int, Error) {
	if file.project == nil || file.entrypoints == nil {
		return 1, fail(.Missing_Schema, "Invalid schema: missing 'project' or 'entrypoints'")
	}
	return exec_entrypoint(file.entrypoints, file.project, file.private, name)
}

@(private)
find_child :: proc(nodes: []^bnml.Node, key: string) -> ^bnml.Node {
	for node in nodes {
		if node.key == key {
			return node
		}
	}
	return nil
}

@(private)
require_child :: proc(parent: ^bnml.Node, name: string, what: string) -> (^bnml.Node, Error) {
	if parent == nil {
		return nil, fail(.Unknown_Name, "Unknown %s: %s", what, name)
	}
	node := find_child(parent.children[:], name)
	if node == nil {
		return nil, fail(.Unknown_Name, "Unknown %s: %s", what, name)
	}
	return node, {}
}

@(private)
find_path_value :: proc(root: ^bnml.Node, loc: string) -> (string, Error) {
	trimmed := strings.trim_space(loc)
	if root == nil || trimmed == "" {
		return "", fail(.Missing_Value, "Missing project value: %s", loc)
	}

	parts := strings.split(trimmed, ".")
	defer delete(parts)

	node := root
	for part in parts {
		if part == "" {
			return "", fail(.Missing_Value, "Missing project value: %s", loc)
		}
		child := find_child(node.children[:], part)
		if child == nil {
			return "", fail(.Missing_Value, "Missing project value: %s", loc)
		}
		node = child
	}
	if len(node.children) > 0 {
		return "", fail(.Missing_Value, "Missing project value: %s", loc)
	}
	return strings.trim_space(node.value), {}
}

@(private)
command_text :: proc(node: ^bnml.Node) -> string {
	if node.value == "" {
		return strings.clone(node.key)
	}
	return fmt.aprintf("%s: %s", node.key, node.value)
}

@(private)
delete_strings :: proc(items: [dynamic]string) {
	for item in items {
		delete(item)
	}
	delete(items)
}

@(private)
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

@(private)
wrap_regardless :: proc(cmds, rgds: string) -> string {
	q_cmds := sh_quote(cmds)
	defer delete(q_cmds)
	q_rgds := sh_quote(rgds)
	defer delete(q_rgds)
	return fmt.aprintf("(eval %s; _fach_ec=$?; (eval %s); exit $_fach_ec)", q_cmds, q_rgds)
}

// {{path}} is a quoted project value. [[ is a literal [.
@(private)
substitute :: proc(raw: string, project: ^bnml.Node) -> (string, Error) {
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
			value, err := find_path_value(project, path)
			if err.kind != .None {
				return "", err
			}
			quoted := sh_quote(value)
			defer delete(quoted)
			strings.write_string(&b, quoted)
			i = next + end + 2
		} else {
			strings.write_byte(&b, '[')
			i = next + 2
		}
	}

	return strings.clone(strings.to_string(b)), {}
}

@(private)
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

@(private)
resolve_line :: proc(
	raw: string,
	project: ^bnml.Node,
	entrypoints: ^bnml.Node,
	private: ^bnml.Node,
	visited: ^[dynamic]Visit,
) -> (string, Error) {
	if name, is_private, ok := parse_whole_ref(raw); ok {
		if is_private {
			ep, err := require_child(private, name, "private")
			if err.kind != .None {
				return "", err
			}
			return build_entrypoint(ep, project, entrypoints, private, visited, true)
		}
		ep, err := require_child(entrypoints, name, "entrypoint")
		if err.kind != .None {
			return "", err
		}
		return build_entrypoint(ep, project, entrypoints, private, visited, false)
	}
	return substitute(raw, project)
}

@(private)
build_entrypoint :: proc(
	ep: ^bnml.Node,
	project: ^bnml.Node,
	entrypoints: ^bnml.Node,
	private: ^bnml.Node,
	visited: ^[dynamic]Visit,
	is_private: bool,
) -> (string, Error) {
	own: [dynamic]Visit
	defer delete(own)
	v := visited
	if v == nil {
		v = &own
	}

	for item in v^ {
		if item.private == is_private && item.name == ep.key {
			return "", fail(.Circular_Dependency, "Circular dependency: %s", ep.key)
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
				return "", fail(.Invalid_Entrypoint, "Invalid entrypoint '%s': duplicate cmds", ep.key)
			}
			cmds_node = child
		case "regardless":
			if rgds_node != nil {
				return "", fail(.Invalid_Entrypoint, "Invalid entrypoint '%s': duplicate regardless", ep.key)
			}
			rgds_node = child
		case:
			return "", fail(.Invalid_Entrypoint, "Invalid entrypoint '%s': unexpected '%s'", ep.key, child.key)
		}
	}
	if cmds_node == nil || len(cmds_node.children) == 0 {
		return "", fail(.Invalid_Entrypoint, "Invalid entrypoint '%s': missing cmds", ep.key)
	}

	cmds := make([dynamic]string)
	defer delete_strings(cmds)
	for child in cmds_node.children {
		line := command_text(child)
		defer delete(line)
		resolved, err := resolve_line(line, project, entrypoints, private, v)
		if err.kind != .None {
			return "", err
		}
		append(&cmds, resolved)
	}
	full := strings.join(cmds[:], " && ")

	if rgds_node != nil && len(rgds_node.children) > 0 {
		rgds := make([dynamic]string)
		defer delete_strings(rgds)
		for child in rgds_node.children {
			line := command_text(child)
			defer delete(line)
			resolved, err := resolve_line(line, project, entrypoints, private, v)
			if err.kind != .None {
				delete(full)
				return "", err
			}
			append(&rgds, resolved)
		}
		joined := strings.join(rgds[:], "; ")
		defer delete(joined)
		wrapped := wrap_regardless(full, joined)
		delete(full)
		full = wrapped
	}

	return full, {}
}

@(private)
exec_entrypoint :: proc(
	entrypoints: ^bnml.Node,
	project: ^bnml.Node,
	private: ^bnml.Node,
	name: string,
) -> (int, Error) {
	ep, ep_err := require_child(entrypoints, name, "entrypoint")
	if ep_err.kind != .None {
		return 1, ep_err
	}

	full, err := build_entrypoint(ep, project, entrypoints, private, nil, false)
	if err.kind != .None {
		return 1, err
	}
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
		return 1, fail(.OS_Error, "OS error: %v", process_err)
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		return 1, fail(.OS_Error, "OS error: %v", wait_err)
	}
	return int(state.exit_code), {}
}
