@tool
extends EditorPlugin

var script_editor: ScriptEditor
var current_popup: PopupMenu

enum MenuItemType {
	CREATE_LOCAL_VARIABLE = 999,
	CREATE_VARIABLE = 1111,
	CREATE_VARIABLE_DECLARATION = 2222,
}
const VARIABLE_DECLARATION_REGEX_MAP : Dictionary = {
	# 基本变量声明 (var a)
	"1": r"var\s+([a-zA-Z_][a-zA-Z0-9_]*)",

	# 带类型注解 (var a : int)
	"2": r"var\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*([a-zA-Z_][a-zA-Z0-9_]*)",

	# 带赋值 (var a = 1)
	"3": r"var\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(\S+)",

	# 完整声明 (var a : int = 1)
	"4": r"var\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(\S+)",

	# 短变量声明 (var a := 1)
	"5": r"var\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*:=\s*(\S+)"
}

# Godot 变量类型正则表达式映射表
const VARIABLE_REGEX_MAP: Dictionary = {
	# 基础标量类型
	"null": "^null$",
	"bool": "^(true|false)$",
	"int": "^-?\\d+$",
	"float": "^-?(\\d+\\.\\d*|\\.\\d+|\\d+)([eE][-+]?\\d+)?$",
	"String": '^"(?:[^"\\\\]|\\\\["\\\\tnr])*"$',  # 支持完整转义序列

	# 集合类型
	"Array": "^\\[\\s*(?:[^\\[\\]]*(?:\\[[^\\[\\]]*\\][^\\[\\]]*)*)?\\s*\\]$",
	"Dictionary": "^\\{\\s*(?:(?:\"(?:[^\"\\\\]|\\\\[\"\\\\tnr])*\"\\s*:\\s*[^,{}]*(?:,(?!\\s*[\\]}])|(?=\\s*\\})))\\s*)*\\}$",

	# 向量/数学类型
	"Vector2": "^Vector2\\(\\s*-?\\d*\\.?\\d+\\s*,\\s*-?\\d*\\.?\\d+\\s*\\)$",
	"Vector3": "^Vector3\\(\\s*-?\\d*\\.?\\d+\\s*,\\s*-?\\d*\\.?\\d+\\s*,\\s*-?\\d*\\.?\\d+\\s*\\)$",
	"Color": "^Color\\(\\s*\\d*\\.?\\d+\\s*,\\s*\\d*\\.?\\d+\\s*,\\s*\\d*\\.?\\d+\\s*(?:,\\s*\\d*\\.?\\d+\\s*)?\\)$",
	"Rect2": "^Rect2\\(\\s*-?\\d*\\.?\\d+\\s*,\\s*-?\\d*\\.?\\d+\\s*,\\s*-?\\d*\\.?\\d+\\s*,\\s*-?\\d*\\.?\\d+\\s*\\)$",

	# 引擎对象类型
	"NodePath": "^NodePath\\(\\s*\"(?:[^\"\\\\]|\\\\[\"\\\\tnr])*\"\\s*\\)$",
	"rid": "^RID\\(\\s*\\)$",  # RID 使用空构造函数
	"StringName": "^StringName\\(\\s*\"(?:[^\"\\\\]|\\\\[\"\\\\tnr])*\"\\s*\\)$"
}

func _enter_tree() -> void:
	script_editor = EditorInterface.get_script_editor()
	script_editor.editor_script_changed.connect(_on_script_changed)
	script_editor.editor_script_changed.emit(script_editor.get_current_script())

func _exit_tree() -> void:
	if script_editor and script_editor.is_connected("editor_script_changed", _on_script_changed):
		script_editor.disconnect("editor_script_changed", _on_script_changed)
	_cleanup_current_script()

# FUNC 查找代码编辑器
func _find_code_edit(node: Node) -> CodeEdit:
	if node is CodeEdit: return node
	for child in node.get_children():
		var result = _find_code_edit(child)
		if result: return result
	return null

# FUNC 查找右键菜单
func _find_popup_menu(node: Node) -> PopupMenu:
	if node is PopupMenu: return node
	for child in node.get_children():
		var result = _find_popup_menu(child)
		if result: return result
	return null

func _find_class_and_extends_after(code_edit: CodeEdit) -> int:
	var scripts := code_edit.text.split("\n")
	for i : int in scripts.size():
		if scripts[i].begins_with("#"): continue
		if scripts[i].contains("extends"):
			if scripts[i + 1].contains("class_name"): return i + 2
			return i + 1
		if scripts[i].contains("class_name"):
			if scripts[i + 1].contains("extends"): return i + 2
			return i + 1
	return 0

func get_variable_declaration_type(line_text : String) -> String:
	if not line_text.contains(":"): return "Variant"
	if line_text.contains("="):
		var value_start_index : int = line_text.find("=")
		var value_string : String = line_text.erase(0, value_start_index + 1).strip_edges()
		var type_string : String = is_variable(value_string)[1]
		if type_string == "int":
			type_string = "int" if line_text.contains("int") else "float"
		return is_variable(value_string)[1]
	var value_start_index : int = line_text.find(":")
	var type_string : String = line_text.erase(0, value_start_index + 1).strip_edges()
	return type_string

func get_var_line_var_name(line_text : String) -> String:
	var var_name : String = ""
	var erase_var = line_text.erase(0, 3)
	var var_name_end : int = erase_var.find(":")
	var_name = erase_var.erase(var_name_end, erase_var.length() - var_name_end).strip_edges()
	return var_name

func _on_script_changed(script : Script) -> void:
	_cleanup_current_script()
	var current_editor = script_editor.get_current_editor()
	if not current_editor: return
	var code_edit = _find_code_edit(current_editor)
	if not code_edit: return
	current_popup = _find_popup_menu(current_editor)
	if not current_popup: return
	current_popup.connect("about_to_popup", _on_popup_about_to_show)

# FUNC 文本是否符合变量值的格式
func is_variable(selected_text : String) -> Array:
	for i in VARIABLE_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(selected_text)
		if result:
			return [true, VARIABLE_REGEX_MAP.find_key(i)]
	return [false]

func is_variable_declaration(line_text : String) -> bool:
	if line_text.begins_with(" ") or line_text.begins_with("\t"): return false
	for i in VARIABLE_DECLARATION_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(line_text)
		if result:
			return true
	return false

func _on_popup_about_to_show() -> void:
	var current_editor : ScriptEditorBase = script_editor.get_current_editor()
	if not current_editor: return

	var code_edit = _find_code_edit(current_editor)
	if not code_edit: return

	var selected_text = _get_selected_text(code_edit)
	if selected_text.is_empty(): return

	var current_line = get_current_line_text(code_edit)

	var is_variables : Array = is_variable(selected_text)
	if is_variables[0]:
		_create_menu_item(
			"提取为临时变量",
			code_edit,
			is_variables[1],
			MenuItemType.CREATE_LOCAL_VARIABLE,
			true
		)
		_create_menu_item(
			"提取为全局变量",
			code_edit,
			is_variables[1],
			MenuItemType.CREATE_VARIABLE,
		)

	var line_text : String = get_current_line_text(code_edit)
	if is_variable_declaration(line_text):
		var var_type : String = get_variable_declaration_type(line_text)
		_create_menu_item(
			"生成 getter setter",
			code_edit,
			var_type,
			MenuItemType.CREATE_VARIABLE_DECLARATION,
			true
		)

# FUNC 创建菜单按钮
func _create_menu_item(item_text: String, code_edit: CodeEdit, type : String, item_type : MenuItemType, has_separator : bool = false) -> void:
	if has_separator: current_popup.add_separator()
	current_popup.add_item(item_text, item_type)

	if current_popup.is_connected("id_pressed", _on_menu_item_pressed):
		current_popup.disconnect("id_pressed", _on_menu_item_pressed)
	current_popup.connect("id_pressed", _on_menu_item_pressed.bind(code_edit, type))

func replace_selection(code_edit: CodeEdit, new_text: String) -> bool:
	var current_line : int = code_edit.get_caret_line()
	var selection_start = code_edit.get_selection_origin_column()
	var selection_end = code_edit.get_selection_to_column()
	var selection_start_line = code_edit.get_selection_origin_line()
	var selection_end_line = code_edit.get_selection_to_line()
	# 检查是否有选中内容
	if selection_start == selection_end and selection_start_line == selection_end_line:
		return false
	code_edit.remove_text(selection_start_line, selection_start, selection_end_line, selection_end)
	code_edit.insert_text(new_text, selection_start_line, selection_start)
	return true

func create_local_variable(code_edit: CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = get_current_line_text(code_edit)
	var selected_text : String = code_edit.get_selected_text()

	var code_text: String = "\tvar new_value : %s = %s" % [type, selected_text]

	replace_selection(code_edit, "new_value")
	code_edit.insert_line_at(current_line, code_text)
	code_edit.select(current_line, 5, current_line, 14)
	code_edit.add_selection_for_next_occurrence()

func create_global_variable(code_edit: CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = get_current_line_text(code_edit)
	var selected_text : String = code_edit.get_selected_text()

	var code_text: String = "var new_value : %s = %s" % [type, selected_text]
	var var_line : int = _find_class_and_extends_after(code_edit)
	replace_selection(code_edit, "new_value")
	code_edit.insert_line_at(var_line, code_text)
	code_edit.select(var_line, 4, var_line, 13)
	code_edit.add_selection_for_next_occurrence()

func create_get_and_set(code_edit: CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = code_edit.get_line(current_line)

	var var_name : String = get_var_line_var_name(line_text)
	var code_text: String = ":\n\tget:\n\t\treturn %s\n\tset(v):\n\t\t%s = v" % [var_name, var_name]
	code_edit.insert_text(code_text, current_line, line_text.length())

func _on_menu_item_pressed(id: int, code_edit: CodeEdit, type : String):
	if id == MenuItemType.CREATE_LOCAL_VARIABLE:
		create_local_variable(code_edit, type)
	if id == MenuItemType.CREATE_VARIABLE:
		create_global_variable(code_edit, type)
	if id == MenuItemType.CREATE_VARIABLE_DECLARATION:
		create_get_and_set(code_edit, type)

# FUNC 清理当前脚本二级窗口连接
func _cleanup_current_script():
	if current_popup and current_popup.is_connected("about_to_popup", _on_popup_about_to_show):
		current_popup.disconnect("about_to_popup", _on_popup_about_to_show)
	current_popup = null

# FUNC 获取当前行代码
func get_current_line_text(_code_edit: CodeEdit) -> String:
	return _code_edit.get_line(_code_edit.get_caret_line())

# FUNC 获取光标所在的字段
func get_word_under_cursor(code_edit: CodeEdit) -> String:
	var caret_line = code_edit.get_caret_line()
	var caret_column = code_edit.get_caret_column()
	var line_text = code_edit.get_line(caret_line)

	var start = caret_column
	while start > 0 and line_text[start - 1].is_subsequence_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"):
		start -= 1

	var end = caret_column
	while end < line_text.length() and line_text[end].is_subsequence_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"):
		end += 1

	return line_text.substr(start, end - start)

# FUNC 获取选择的字段
func _get_selected_text(_code_edit: CodeEdit) -> String:
	var selected_text = _code_edit.get_selected_text().strip_edges()
	if selected_text.is_empty():
		selected_text = get_word_under_cursor(_code_edit)
	return selected_text
