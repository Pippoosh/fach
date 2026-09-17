package bnml

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode"

Error :: enum {
	None = 0,
	File_Read_Failed,
	Invalid_Indent_Sequence,
	Malformed_Line,
	Out_Of_Memory,
}

Node :: struct {
	key :      string,
	value :    string,
	children : [dynamic]^Node,
}

read_lines :: proc(
	path : string,
	allocator := context.allocator,
) -> (
	lines : [dynamic]string,
	file_data : []byte,
	err : Error,
) {
	file, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		if _, is_alloc := read_err.(runtime.Allocator_Error); is_alloc {
			return nil, nil, .Out_Of_Memory
		}
		return nil, nil, .File_Read_Failed
	}

	lines_ok, lines_err := make([dynamic]string, allocator)
	if lines_err != nil {
		delete(file, allocator)
		return nil, nil, .Out_Of_Memory
	}

	file_str := string(file)
	for line in strings.split_lines_iterator(&file_str) {
		if _, append_err := append(&lines_ok, line); append_err != nil {
			delete(lines_ok)
			delete(file, allocator)
			return nil, nil, .Out_Of_Memory
		}
	}

	return lines_ok, file, .None
}

strip :: proc(lines : ^[dynamic]string) {
	write_idx := 0
	for line in lines^ {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, ";") {
			continue
		}
		lines[write_idx] = trimmed
		write_idx += 1
	}
	resize(lines, write_idx)
}

@(private)
split_digits_prefix :: proc(line : string) -> (prefix : string, rest : string) {
	split_idx := len(line)
	for r, idx in line {
		if !unicode.is_digit(r) {
			split_idx = idx
			break
		}
	}
	return line[:split_idx], strings.trim_left_space(line[split_idx:])
}

@(private)
split_at_colon :: proc(s : string) -> (left : string, right : string, ok : bool) {
	for idx := 0; idx < len(s); idx += 1 {
		if s[idx] == ':' {
			bs_count := 0
			check_idx := idx - 1
			for check_idx >= 0 && s[check_idx] == '\\' {
				bs_count += 1
				check_idx -= 1
			}

			if bs_count % 2 == 0 {
				return strings.trim_space(s[:idx]), strings.trim_space(s[idx + 1:]), true
			}
		}
	}
	return strings.trim_space(s), "", false
}

validate :: proc(lines : []string) -> Error {
	last := -1
	for line in lines {
		prefix, _ := split_digits_prefix(line)
		if prefix == "" {
			return .Malformed_Line
		}
		prefix_num, ok := strconv.parse_int(prefix)
		if !ok {
			return .Malformed_Line
		}
		if prefix_num > last + 1 {
			return .Invalid_Indent_Sequence
		}
		last = prefix_num
	}
	return .None
}

@(private)
unescape :: proc(line : string, allocator := context.allocator) -> (string, Error) {
	sb : strings.Builder
	if _, init_err := strings.builder_init(&sb, allocator); init_err != nil {
		return "", .Out_Of_Memory
	}

	escaped := false
	for r in line {
		if !escaped && r == '\\' {
			escaped = true
			continue
		}
		if _, write_err := strings.write_rune(&sb, r); write_err != .None {
			strings.builder_destroy(&sb)
			return "", .Out_Of_Memory
		}
		escaped = false
	}
	return strings.to_string(sb), .None
}

parse_unchecked :: proc(
	lines : []string,
	allocator := context.allocator,
) -> (
	roots : [dynamic]^Node,
	err : Error,
) {
	fail :: proc(allocated : [dynamic]^Node, extra : ^Node, a : runtime.Allocator, err : Error) -> (roots : [dynamic]^Node, e : Error) {
		if extra != nil {
			destroy_node(extra, a)
		}
		allocated := allocated
		destroy_tree(&allocated, a)
		return nil, err
	}

	made, make_err := make([dynamic]^Node, allocator)
	if make_err != nil {
		return nil, .Out_Of_Memory
	}
	roots = made

	stack, stack_err := make([dynamic]^Node, allocator)
	if stack_err != nil {
		return fail(roots, nil, allocator, .Out_Of_Memory)
	}
	defer delete(stack)

	for line in lines {
		prefix, rest := split_digits_prefix(line)
		depth, _ := strconv.parse_int(prefix)
		key, val, _ := split_at_colon(rest)

		node, node_err := new(Node, allocator)
		if node_err != nil {
			return fail(roots, nil, allocator, .Out_Of_Memory)
		}

		unescaped, unescape_err := unescape(key, allocator)
		if unescape_err != .None {
			free(node, allocator)
			return fail(roots, nil, allocator, unescape_err)
		}
		node.key = unescaped

		cloned, clone_err := strings.clone(val, allocator)
		if clone_err != nil {
			delete(node.key, allocator)
			free(node, allocator)
			return fail(roots, nil, allocator, .Out_Of_Memory)
		}
		node.value = cloned

		children, child_err := make([dynamic]^Node, allocator)
		if child_err != nil {
			return fail(roots, node, allocator, .Out_Of_Memory)
		}
		node.children = children

		if depth == 0 {
			if _, append_err := append(&roots, node); append_err != nil {
				return fail(roots, node, allocator, .Out_Of_Memory)
			}
		} else {
			if depth - 1 >= len(stack) {
				return fail(roots, node, allocator, .Invalid_Indent_Sequence)
			}
			if _, append_err := append(&stack[depth - 1].children, node); append_err != nil {
				return fail(roots, node, allocator, .Out_Of_Memory)
			}
		}

		if resize_err := resize(&stack, depth + 1); resize_err != nil {
			return fail(roots, nil, allocator, .Out_Of_Memory)
		}
		stack[depth] = node
	}

	return roots, .None
}

parse :: proc(
	lines : []string,
	allocator := context.allocator,
) -> (
	roots : [dynamic]^Node,
	err : Error,
) {
	if err := validate(lines); err != .None {
		return nil, err
	}

	return parse_unchecked(lines, allocator)
}

print_node :: proc(node : ^Node, indent := 0) {
	if node == nil do return

	for _ in 0 ..< indent {
		fmt.print("  ")
	}

	if node.value != "" {
		fmt.printf("%s: %s\n", node.key, node.value)
	} else {
		fmt.printf("%s\n", node.key)
	}

	for child in node.children {
		print_node(child, indent + 1)
	}
}

print_tree :: proc(roots : []^Node) {
	for root in roots {
		print_node(root, 0)
	}
}

destroy_node :: proc(node : ^Node, allocator := context.allocator) {
	if node == nil do return
	for child in node.children {
		destroy_node(child, allocator)
	}
	delete(node.children)

	delete(node.key, allocator)
	delete(node.value, allocator)

	free(node, allocator)
}

destroy_tree :: proc(roots : ^[dynamic]^Node, allocator := context.allocator) {
	for root in roots {
		destroy_node(root, allocator)
	}
	delete(roots^)
}

@(private)
_traverse :: proc(node : ^Node, target_key : string, results : ^[dynamic]^Node) -> Error {
	if node == nil do return .None

	if node.key == target_key {
		if _, append_err := append(results, node); append_err != nil {
			return .Out_Of_Memory
		}
	}

	for child in node.children {
		if err := _traverse(child, target_key, results); err != .None {
			return err
		}
	}
	return .None
}

find_nodes :: proc(
	roots : []^Node,
	target_key : string,
	allocator := context.allocator,
) -> (
	results : [dynamic]^Node,
	err : Error,
) {
	made, make_err := make([dynamic]^Node, allocator)
	if make_err != nil {
		return nil, .Out_Of_Memory
	}
	results = made

	for root in roots {
		if trav_err := _traverse(root, target_key, &results); trav_err != .None {
			delete(results)
			return nil, trav_err
		}
	}
	return results, .None
}
