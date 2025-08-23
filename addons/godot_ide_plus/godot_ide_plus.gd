@tool
extends EditorPlugin

var all_data : Dictionary[MenuItemType, Array] = {}
# NOTE 代码编辑器
var script_editor: ScriptEditor
# NOTE 当前的 PopupMenu
var current_popup: PopupMenu

# NOTE 菜单按钮类型 id 枚举
enum MenuItemType {
	# 从值提取 local 变量
	CREATE_LOCAL_VARIABLE_FROM_VALUE = 111,
	# 从值提取 成员 变量
	CREATE_VARIABLE_FROM_VALUE = 222,
	# 创建变量声明
	CREATE_VARIABLE_GET_AND_SET = 333,
	# 生成信号方法
	CREATE_SIGNAL_FUNCTION = 444,
	# 生成信号声明
	CREATE_SIGNAL = 555,
	# 生成成员变量声明
	CREATE_VARIABLE = 666,
	# 生成临时变量声明
	CREATE_LOCAL_VARIABLE = 777,
	# 从代码块中提取成员方法
	CREATE_FUNCTION_FROM_CODE_BLOCK = 888,
	# 从临时变量声明提取为方法参数
	CREATE_FUNCTION_PARAMETER_FROM_LOCAL_VARIABLE = 999,
}

# NOTE 变量名
const VARIABLE_NAME : String = "^[\\p{L}_][\\p{L}\\p{N}_]*$"

# NOTE 声明方式正则表达式映射表
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

# NOTE 变量类型正则表达式映射表
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

# NOTE 信号连接方法名称正则表达式
const ON_METHOD_REGEX_STR = "^_on_[a-zA-Z0-9]+(?:_[a-zA-Z0-9]+)*$"

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

# FUNC 查找类名声明和继承声明的下一行
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

# FUNC 获取变量声明中的变量类型
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

# FUNC 获取变量声明中的变量名称
func get_var_line_var_name(line_text : String) -> String:
	var var_name : String = ""
	var erase_var = line_text.erase(0, 3 + line_text.count("\t")) if line_text.contains("\t") else line_text.erase(0, 3)
	var var_name_end : int = erase_var.find(":")
	var_name = erase_var.erase(var_name_end, erase_var.length() - var_name_end).strip_edges()
	return var_name

# FUNC 获取当前行的所有变量名称
func get_line_all_var(line_text : String) -> Array:
	if line_text.begins_with("\t#"): return []
	var tokens := []
	for t : String in line_text.split(" "):
		if t in ["+", "-", "*", "/", "%", "=", ":", ":="]: continue
		if t.strip_edges() == "var": continue
		if t in VARIABLE_REGEX_MAP.keys(): continue
		if t.contains("#"): break
		if t.is_valid_int() or t.is_valid_float() or t.contains("\""): continue
		if t.strip_edges() in tokens: continue
		if t.begins_with(":"): continue
		if t.contains("connect("): continue
		if t.contains("emit("): continue
		if t.ends_with(":"):
			tokens.append(t.remove_chars(":"))
			continue
		tokens.append(t.strip_edges())
	return tokens

func _on_script_changed(script : Script) -> void:
	_cleanup_current_script()
	var current_editor = script_editor.get_current_editor()
	if not current_editor: return
	var code_edit = _find_code_edit(current_editor)
	if not code_edit: return
	# 自定义二级菜单相关信号链接
	current_popup = _find_popup_menu(current_editor)
	if not current_popup: return
	current_popup.about_to_popup.connect(_on_popup_about_to_show)

# FUNC 文本是否符合变量值的格式
func is_variable(selected_text : String) -> Array:
	for i in VARIABLE_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(selected_text)
		if result:
			return [true, VARIABLE_REGEX_MAP.find_key(i)]
	return [false]

# FUNC 文本是否符合变量声明的格式
func is_variable_declaration(line_text : String) -> bool:
	if line_text.begins_with(" ") or line_text.begins_with("\t"): return false
	if line_text.ends_with(":"): return false
	for i in VARIABLE_DECLARATION_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(line_text)
		if result:
			return true
	return false

func is_selection_one_line(code_edit : CodeEdit) -> bool:
	return code_edit.get_selection_from_line() == code_edit.get_selection_to_line()

# FUNC 文本是否符合变量声明的格式
func is_local_variable_declaration(code_edit : CodeEdit, line_text : String) -> bool:
	if line_text.contains("func "): return false
	if not is_selection_one_line(code_edit): return false
	if line_text.strip_edges().begins_with("#"): return false
	if not line_text.begins_with("\t"): return false
	if line_text.ends_with(":"): return false
	for i in VARIABLE_DECLARATION_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(line_text)
		if result:
			return true
	return false

# FUNC 当前行是否满足信号连接
func is_connect_signal_func(line_text : String, selected_text : String) -> bool:
	if not line_text.contains("connect"): return false
	var regex = RegEx.new()
	regex.compile(ON_METHOD_REGEX_STR)
	var result = regex.search(selected_text)
	if result:
		return true
	return false

# FUNC 当前行是否满足信号发射格式
func is_siganl_emit(line_text : String) -> Array:
	if line_text.contains(".emit"):
		var emit_start_index : int = line_text.find(".emit")
		var signal_name : String = line_text\
			.erase(emit_start_index, line_text.length() - emit_start_index)\
			.strip_edges()
		return [true, signal_name]
	return [false]

# FUNC 当前行是否满足变量名格式
func is_var_name(selected_text : String) -> bool:
	var regex = RegEx.new()
	regex.compile(VARIABLE_NAME)
	var result = regex.search(selected_text)
	if result: return true
	return false

# FUNC 当前选中的行是否满足代码块格式
func is_scrpit_block(code_edit : CodeEdit) -> Array:
	var code_start_line : int = code_edit.get_selection_from_line() + 1
	var code_end_line : int = code_edit.get_selection_to_line() + 1
	if get_current_line_text(code_edit).contains("func "): return [false]
	if code_start_line == code_end_line\
	and code_edit.get_selection_from_column() == code_edit.get_selection_to_column():
		return [false]
	for i in range(code_start_line, code_end_line):
		if code_edit.get_line(i - 1).is_empty(): continue
		if not code_edit.get_line(i - 1).begins_with("\t"):
			return [false]
	return [true, code_start_line, code_end_line]

# FUNC Popup Menu 显示时信号
func _on_popup_about_to_show() -> void:
	var current_editor : ScriptEditorBase = script_editor.get_current_editor()
	if not current_editor: return

	var code_edit = _find_code_edit(current_editor)
	if not code_edit: return

	var selected_text = _get_selected_text(code_edit)
	if selected_text.is_empty(): return
	var line_text : String = get_current_line_text(code_edit)
	if line_text.strip_edges().begins_with("#"): return
	var var_name_dic : Dictionary = get_current_script_vars(code_edit)
	var var_name_arr : Array = []
	for i in var_name_dic["name_and_types"]:
		var_name_arr.append(i[0])
	var is_script_block_arr : Array = is_scrpit_block(code_edit)
	if is_script_block_arr.pop_at(0):
		_create_menu_item(
			"提取为成员方法",
			code_edit,
			is_script_block_arr,
			MenuItemType.CREATE_FUNCTION_FROM_CODE_BLOCK,
			true
		)
	var is_variables : Array = is_variable(selected_text)
	var var_type : String
	if not line_text.contains("func "):
		var_type = get_variable_declaration_type(line_text)
	if is_local_variable_declaration(code_edit, line_text):
		_create_menu_item(
			"提取为方法参数",
			code_edit,
			[line_text, var_type],
			MenuItemType.CREATE_FUNCTION_PARAMETER_FROM_LOCAL_VARIABLE,
			true
		)
	if is_variables[0] and var_type.length() > 0:
		_create_menu_item(
			"提取为临时变量",
			code_edit,
			[is_variables[1]],
			MenuItemType.CREATE_LOCAL_VARIABLE_FROM_VALUE,
			true
		)
		_create_menu_item(
			"提取为成员变量",
			code_edit,
			[is_variables[1]],
			MenuItemType.CREATE_VARIABLE_FROM_VALUE,
		)
	# NOTE 信号发射判断
	var is_signal_emit_arr : Array = is_siganl_emit(line_text)
	if is_signal_emit_arr[0]:
		_create_menu_item(
			"生成信号",
			code_edit,
			[is_signal_emit_arr[1]],
			MenuItemType.CREATE_SIGNAL,
			true
		)
	elif is_connect_signal_func(line_text, selected_text):
		_create_menu_item(
			"生成信号连接方法",
			code_edit,
			[],
			MenuItemType.CREATE_SIGNAL_FUNCTION,
			true
		)
	elif is_variable_declaration(line_text):
		_create_menu_item(
			"生成 getter setter",
			code_edit,
			[var_type],
			MenuItemType.CREATE_VARIABLE_GET_AND_SET,
			true
		)
	else :
		if is_var_name(selected_text):
			if selected_text not in var_name_arr:
				_create_menu_item(
					"生成成员变量",
					code_edit,
					[selected_text],
					MenuItemType.CREATE_VARIABLE,
					true
				)
			_create_menu_item(
				"生成临时变量",
				code_edit,
				[selected_text],
				MenuItemType.CREATE_LOCAL_VARIABLE,
				selected_text in var_name_arr
			)

# FUNC 创建菜单按钮
func _create_menu_item(item_text: String, code_edit: CodeEdit, data : Array, item_type : MenuItemType, has_separator : bool = false) -> void:
	if has_separator: current_popup.add_separator()
	current_popup.add_item(item_text, item_type)
	all_data[item_type] = data

	if current_popup.is_connected("id_pressed", _on_menu_item_pressed):
		current_popup.disconnect("id_pressed", _on_menu_item_pressed)
	current_popup.connect("id_pressed", _on_menu_item_pressed.bind(code_edit))

# FUNC 替换选中的代码片段
func replace_selection(code_edit: CodeEdit, new_text: String, line_mode : bool = false) -> bool:
	var current_line : int = code_edit.get_caret_line()
	var selection_start = code_edit.get_selection_origin_column()
	var selection_end = code_edit.get_selection_to_column()
	var selection_start_line = code_edit.get_selection_from_line()
	var selection_end_line = code_edit.get_selection_to_line()
	# 检查是否有选中内容
	if line_mode:
		code_edit.remove_text(selection_start_line, 0, selection_end_line, selection_end)
		code_edit.insert_text(new_text, selection_start_line, 0)
		return true
	if selection_start == selection_end and selection_start_line == selection_end_line:
		return false
	code_edit.remove_text(selection_start_line, selection_start, selection_end_line, selection_end)
	code_edit.insert_text(new_text, selection_start_line, selection_start)
	return true

# FUNC 将值提取为临时变量
func create_local_variable(code_edit: CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = get_current_line_text(code_edit)
	var selected_text : String = code_edit.get_selected_text()

	var code_text: String = "\tvar new_value : %s = %s" % [type, selected_text]

	if replace_selection(code_edit, "new_value"):
		code_edit.insert_line_at(current_line, code_text)
		code_edit.select(current_line, 5, current_line, 14)
		code_edit.add_selection_for_next_occurrence()

# FUNC 将值提取为全局变量
func create_global_variable(code_edit: CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = get_current_line_text(code_edit)
	var selected_text : String = code_edit.get_selected_text()

	var code_text: String = "var new_value : %s = %s" % [type, selected_text]
	var var_line : int = _find_class_and_extends_after(code_edit)
	if replace_selection(code_edit, "new_value"):
		code_edit.insert_line_at(var_line, code_text)
		code_edit.select(var_line, 4, var_line, 13)
		code_edit.add_selection_for_next_occurrence()

# FUNC 生成当前行变量声明的 get set
func create_get_and_set(code_edit: CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = code_edit.get_line(current_line)

	var var_name : String = get_var_line_var_name(line_text)
	var code_text: String = ":\n\tget:\n\t\treturn %s\n\tset(v):\n\t\t%s = v" % [var_name, var_name]
	code_edit.insert_text(code_text, current_line, line_text.length())

# FUNC 生成当前信号连接的方法
func create_signal_function(code_edit: CodeEdit) -> void:
	var selected_text = _get_selected_text(code_edit)
	var code_text: String = "func %s() -> void:\n\tpass" % [selected_text]
	code_edit.insert_line_at(code_edit.get_line_count() - 1, code_text)

# FUNC 生成信号
func create_signal(code_edit : CodeEdit, type : String) -> void:
	var code_text: String = "signal %s()" % [type]
	var var_line : int = _find_class_and_extends_after(code_edit)
	code_edit.insert_line_at(var_line, code_text)

# FUNC 生成变量声明
func create_var_declaration(code_edit : CodeEdit, type : String) -> void:
	var code_text: String = "var %s : Variant" % [type]
	var var_line : int = _find_class_and_extends_after(code_edit)
	code_edit.insert_line_at(var_line, code_text)
	var current_line_length : int = code_edit.get_line(var_line).length()
	code_edit.select(var_line, current_line_length - 7, var_line, current_line_length)

# FUNC 生成临时变量声明
func create_local_var_declaration(code_edit : CodeEdit, type : String) -> void:
	var current_line : int = code_edit.get_caret_line()
	var code_text: String = "\tvar %s : Variant" % [type]
	code_edit.insert_line_at(current_line, code_text)
	var current_line_length : int = code_edit.get_line(current_line).length()
	code_edit.select(current_line, current_line_length - 7, current_line, current_line_length)

# FUNC 将代码块提取为成员方法
func create_function_from_code_block(code_edit : CodeEdit, data : Array) -> void:
	var current_line : int = code_edit.get_selection_from_line()\
		if code_edit.get_selection_from_line() < code_edit.get_selection_to_line()\
		else code_edit.get_selection_to_line()
	var code_block : String = ""
	var get_local_vars : Array = []
	var parameters : Array = []
	var var_name_dic : Dictionary = get_current_script_vars(code_edit)
	var var_name_arr : Array = []
	# 获取全局变量的名字
	for i in var_name_dic["name_and_types"]:
		var_name_arr.append(i[0])
	for i in range(data[0], data[1] + 1):
		var line_text : String = code_edit.get_line(i - 1)
		# 获取临时变量的名字
		if line_text.contains("var"):
			get_local_vars.append(get_var_line_var_name(line_text))
		# 得到所有变量名
		for var_parameter in get_line_all_var(line_text):
			if var_parameter in parameters: continue
			parameters.append(var_parameter)
		for parameter in get_local_vars:
			if parameter in parameters: parameters.erase(parameter)
		for parameter in var_name_arr:
			if parameter in var_name_arr: parameters.erase(parameter)
		if i == data[0]:
			code_block = line_text
			continue
		code_block += "\n" + line_text
	var parameter_str : String = ""
	for i in parameters.size():
		if i == 0:
			parameter_str = parameters[i]
			continue
		parameter_str += ", " + parameters[i]
	var code_text : String = "func new_func_name(%s) -> void:\n%s" % [parameter_str, code_block]
	var code_line : int = code_edit.get_line_count() - 1
	if replace_selection(code_edit, "\tnew_func_name()", true):
		code_edit.insert_line_at(code_edit.get_line_count() - 1, code_text)
		code_edit.select(current_line, 1, current_line, 14)
		code_edit.add_selection_for_next_occurrence()

# FUNC 将临时变量提取为方法的参数
func create_function_parameter_from_local_variable(code_edit : CodeEdit, data : Array) -> void:
	var line_text : String = data[0]
	var parameter : String = get_var_line_var_name(line_text)
	var parameter_type : String = data[1]
	code_edit.remove_line_at(code_edit.get_caret_line())
	var func_line : int = code_edit.get_caret_line()
	while true:
		if code_edit.get_line(func_line).begins_with("func"): break
		func_line -= 1
	var func_line_text : String = code_edit.get_line(func_line)
	var insert_index : int = func_line_text.find(")")

	var parameter_value : Variant = null
	if line_text.contains("="):
		parameter_value = line_text.erase(0, line_text.find("=") + 1).strip_edges()
		if func_line_text.find("(") + 1 != insert_index:
			code_edit.insert_text(", %s : %s = %s" % [parameter, parameter_type, parameter_value], func_line, insert_index)
			return
		code_edit.insert_text("%s : %s = %s" % [parameter, parameter_type, parameter_value], func_line, insert_index)
		return
	if func_line_text.find("(") + 1 != insert_index:
		code_edit.insert_text(",%s : %s" % [parameter, parameter_type], func_line, insert_index)
		return
	code_edit.insert_text("%s : %s" % [parameter, parameter_type], func_line, insert_index)


# FUNC 当 Popup Menu 中的 item 被点击时的方法
func _on_menu_item_pressed(id: int, code_edit: CodeEdit):
	match id:
		MenuItemType.CREATE_LOCAL_VARIABLE_FROM_VALUE:
			create_local_variable(code_edit, all_data[id][0])
		MenuItemType.CREATE_VARIABLE_FROM_VALUE:
			create_global_variable(code_edit, all_data[id][0])
		MenuItemType.CREATE_VARIABLE_GET_AND_SET:
			create_get_and_set(code_edit, all_data[id][0])
		MenuItemType.CREATE_SIGNAL_FUNCTION:
			create_signal_function(code_edit)
		MenuItemType.CREATE_SIGNAL:
			create_signal(code_edit, all_data[id][0])
		MenuItemType.CREATE_VARIABLE:
			create_var_declaration(code_edit, all_data[id][0])
		MenuItemType.CREATE_LOCAL_VARIABLE:
			create_local_var_declaration(code_edit, all_data[id][0])
		MenuItemType.CREATE_FUNCTION_FROM_CODE_BLOCK:
			create_function_from_code_block(code_edit, all_data[id])
		MenuItemType.CREATE_FUNCTION_PARAMETER_FROM_LOCAL_VARIABLE:
			create_function_parameter_from_local_variable(code_edit, all_data[id])

# FUNC 清理当前脚本二级窗口连接
func _cleanup_current_script():
	if current_popup and current_popup.is_connected("about_to_popup", _on_popup_about_to_show):
		current_popup.disconnect("about_to_popup", _on_popup_about_to_show)
	current_popup = null

# FUNC 获取当前脚本的声明的变量
func get_current_script_vars(code_edit : CodeEdit) -> Dictionary:
	var var_name_arr : Dictionary = {"name_and_types" : []}
	var scripts := code_edit.text.split("\n")
	for i : int in scripts.size():
		if scripts[i].begins_with(" ") or scripts[i].begins_with("\t"): continue
		if scripts[i].contains("func"): continue
		if scripts[i].begins_with("#"): continue
		if scripts[i].is_empty(): continue
		if not scripts[i].contains("var"): continue
		var var_name : String = get_var_line_var_name(scripts[i])
		var var_type : String
		# WARNING 获取类型
		var_name_arr["name_and_types"].append([var_name, var_type])
	return var_name_arr

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
	var selected_text : String = _code_edit.get_selected_text().strip_edges()
	if selected_text.is_empty():
		selected_text = get_word_under_cursor(_code_edit)
	return selected_text
