@tool
extends EditorPlugin

#region 常量与枚举
# NOTE 菜单按钮类型 id 枚举
enum MenuItemType {
	# 从值提取 local 变量
	CREATE_LOCAL_VARIABLE_FROM_VALUE = 111,
	# 从值提取 成员 变量
	CREATE_MEMBER_VARIABLE_FROM_VALUE = 222,
	# 创建变量声明 get set
	CREATE_VARIABLE_GET_AND_SET = 333,
	# 生成信号方法
	CREATE_SIGNAL_FUNCTION = 444,
	# 生成信号声明
	CREATE_SIGNAL = 555,
	# 生成成员变量声明
	CREATE_MEMBER_VARIABLE = 666,
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
#endregion

#region 变量
var variable_data : Dictionary
# NOTE 菜单数据
var all_data : Dictionary[MenuItemType, Array] = {}
# NOTE 代码编辑器
var script_editor: ScriptEditor
# NOTE 当前的 PopupMenu
var current_popup: PopupMenu
# NOTE 临时的代码CodeEdit
var temp_code_edit : CodeEdit
#endregion

#region 虚方法
func _enter_tree() -> void:
	# 获取代码编辑器
	script_editor = EditorInterface.get_script_editor()
	# 初始化代码编辑器
	_init_script_editor()
	EditorInterface.get_resource_filesystem().script_classes_updated.connect(_on_script_classes_updated)

func _exit_tree() -> void:
	# 如果信号链接，断开信号
	if script_editor and script_editor.is_connected("editor_script_changed", _on_script_changed):
		script_editor.disconnect("editor_script_changed", _on_script_changed)
	_cleanup_current_script()
	if EditorInterface.get_resource_filesystem().script_classes_updated.is_connected(_on_script_classes_updated):
		EditorInterface.get_resource_filesystem().script_classes_updated.disconnect(_on_script_classes_updated)
#endregion

#region 信号方法

func _on_script_classes_updated() -> void:
	var script_file_list : Array = _get_scripte_file_list("res://")
	variable_data = {}
	for i in script_file_list:
		var temp_data : Dictionary = _get_all_variable_from_script(i)
		variable_data = VariableDataMerger.merge_index_data(variable_data, temp_data)
	for i in script_file_list:
		_get_variable_all_references(i, "temp_code_edit", "res://addons/godot_ide_plus/godot_ide_plus.gd")
	print(variable_data)

# Script Editor 改变时信号
func _on_script_changed(script : Script) -> void:
	# 清除当前代码二级菜单信号链接
	_cleanup_current_script()
	# 刷新 Script Editor Base
	var current_editor : ScriptEditorBase = script_editor.get_current_editor()
	if not current_editor: return
	# 刷新临时代码编辑器
	temp_code_edit = null
	temp_code_edit = _find_code_edit(current_editor)
	if not temp_code_edit: return
	# 刷新当前 popup menu
	current_popup = null
	current_popup = _find_popup_menu(current_editor)
	if not current_popup: return
	# 链接信号 about_to_popup
	current_popup.about_to_popup.connect(_on_popup_about_to_show)

# FUNC Popup Menu 显示时信号
func _on_popup_about_to_show() -> void:
	# 刷新 Script Editor Base
	var current_editor : ScriptEditorBase = script_editor.get_current_editor()
	if not current_editor: return
	# 获取选择的文本
	var selected_text : String = _get_selected_text()
	if selected_text.is_empty(): return
	# 获取当前行文本
	var current_line_text : String = _get_current_line_text()
	# 排除注释开头的行
	if _is_begins_with_annotation_line(current_line_text): return
	var is_variable_value : bool = _is_variable_value(selected_text)
	var is_member_variable_declaration : bool = _is_variable_declaration(current_line_text)
	var is_local_variable_declaration : bool = _is_variable_declaration(current_line_text, false)
	var is_signal_function_name : bool = _is_connect_signal_func(current_line_text, selected_text)
	var is_signal_emit : bool = _is_siganl_emit(current_line_text)
	var is_variable_name : bool = _is_var_name(selected_text)
	var variable_value_type : String = _get_variable_value_type(selected_text)
	var is_script_block : bool = _is_script_block()
	if is_variable_value:
		# 将值提取为临时变量
		_create_menu_item(
			"提取为临时变量",
			[variable_value_type],
			MenuItemType.CREATE_LOCAL_VARIABLE_FROM_VALUE,
			true
		)
		# 将值提取为成员变量
		_create_menu_item(
			"提取为成员变量",
			[variable_value_type],
			MenuItemType.CREATE_MEMBER_VARIABLE_FROM_VALUE,
		)
	if is_member_variable_declaration :
		# 给成员变量生成 get set
		_create_menu_item(
			"生成 get set",
			[variable_value_type],
			MenuItemType.CREATE_VARIABLE_GET_AND_SET,
		)
	if is_signal_function_name :
		# 快速声明信号链接的方法
		_create_menu_item(
			"快速声明信号链接的方法",
			[],
			MenuItemType.CREATE_SIGNAL_FUNCTION,
		)
	if is_signal_emit :
		var signal_name : String = _get_signal_name(current_line_text)
		# 快速声明信号
		_create_menu_item(
			"快速声明信号",
			[signal_name],
			MenuItemType.CREATE_SIGNAL,
		)
	if is_variable_name :
		# WARNING 根据当前变量引用字典来判断是否可以显示成员变量声明
		#if selected_text in
		_create_menu_item(
			"生成成员变量",
			[selected_text],
			MenuItemType.CREATE_MEMBER_VARIABLE,
		)
		_create_menu_item(
			"生成临时变量",
			[selected_text],
			MenuItemType.CREATE_LOCAL_VARIABLE,
		)
	if is_local_variable_declaration :
		_create_menu_item(
			"提取为方法入参",
			[current_line_text, variable_value_type],
			MenuItemType.CREATE_FUNCTION_PARAMETER_FROM_LOCAL_VARIABLE,
		)
	_create_menu_item(
		"提取为方法",
		[],
		MenuItemType.CREATE_FUNCTION_FROM_CODE_BLOCK,
	)

# FUNC 当 Popup Menu 中的 item 被点击时的方法
func _on_menu_item_pressed(id: int, code_edit: CodeEdit):
	match id:
		MenuItemType.CREATE_LOCAL_VARIABLE_FROM_VALUE:
			_create_local_variable(all_data[id][0])
		MenuItemType.CREATE_MEMBER_VARIABLE_FROM_VALUE:
			_create_member_variable(all_data[id][0])
		MenuItemType.CREATE_VARIABLE_GET_AND_SET:
			_create_get_and_set(all_data[id][0])
		MenuItemType.CREATE_SIGNAL_FUNCTION:
			_create_signal_function()
		MenuItemType.CREATE_SIGNAL:
			_create_signal(all_data[id][0])
		MenuItemType.CREATE_MEMBER_VARIABLE:
			_create_member_var_declaration(all_data[id][0])
		MenuItemType.CREATE_LOCAL_VARIABLE:
			_create_local_var_declaration(all_data[id][0])
		MenuItemType.CREATE_FUNCTION_FROM_CODE_BLOCK:
			_create_function_from_code_block(all_data[id])
		MenuItemType.CREATE_FUNCTION_PARAMETER_FROM_LOCAL_VARIABLE:
			_create_function_parameter_from_local_variable(all_data[id])
#endregion

#region 工具方法
# FUNC 代码编辑器初始化
func _init_script_editor() -> void:
	script_editor.editor_script_changed.connect(_on_script_changed)
	script_editor.editor_script_changed.emit(script_editor.get_current_script())

# FUNC 清除当前代码二级菜单信号链接
func _cleanup_current_script():
	if current_popup and current_popup.is_connected("about_to_popup", _on_popup_about_to_show):
		current_popup.disconnect("about_to_popup", _on_popup_about_to_show)
	current_popup = null

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
func _find_class_and_extends_after() -> int:
	var scripts := temp_code_edit.text.split("\n")
	for i : int in scripts.size():
		if scripts[i].begins_with("#"): continue
		if scripts[i].contains("extends"):
			if scripts[i + 1].contains("class_name"): return i + 2
			return i + 1
		if scripts[i].contains("class_name"):
			if scripts[i + 1].contains("extends"): return i + 2
			return i + 1
	return 0

# FUNC 替换选中的代码片段
func _replace_selection(new_text: String, line_mode : bool = false) -> bool:
	var current_line : int = temp_code_edit.get_caret_line()
	# 选择的开始点、结束点
	var selection_start = temp_code_edit.get_selection_origin_column()
	var selection_end = temp_code_edit.get_selection_to_column()
	# 选择的开始行、结束行
	var selection_start_line = temp_code_edit.get_selection_from_line()
	var selection_end_line = temp_code_edit.get_selection_to_line()
	if line_mode:
		temp_code_edit.remove_text(selection_start_line, 0, selection_end_line, temp_code_edit.get_line(selection_start_line).length())
		temp_code_edit.insert_text(new_text, selection_start_line, 0)
		return true
	if selection_start == selection_end and selection_start_line == selection_end_line:
		return false
	temp_code_edit.remove_text(selection_start_line, selection_start, selection_end_line, selection_end)
	temp_code_edit.insert_text(new_text, selection_start_line, selection_start)
	return true

# FUNC 创建菜单按钮
func _create_menu_item(item_text: String, data : Array, item_type : MenuItemType, has_separator : bool = true) -> void:
	if has_separator: current_popup.add_separator()
	current_popup.add_item(item_text, item_type)
	# 将类型数据放入
	all_data[item_type] = data

	if current_popup.is_connected("id_pressed", _on_menu_item_pressed):
		current_popup.disconnect("id_pressed", _on_menu_item_pressed)
	current_popup.connect("id_pressed", _on_menu_item_pressed.bind(temp_code_edit))

# FUNC 将值提取为临时变量
func _create_local_variable(type : String) -> void:
	# 获取当前鼠标行
	var current_line : int = temp_code_edit.get_caret_line()
	# 当前鼠标行的文本
	var line_text : String = _get_current_line_text()
	# 选择的文本
	var selected_text : String = temp_code_edit.get_selected_text()

	var code_text: String = "\tvar new_value : %s = %s" % [type, selected_text]

	if _replace_selection("new_value"):
		temp_code_edit.insert_line_at(current_line, code_text)
		temp_code_edit.select(current_line, 5, current_line, 14)
		temp_code_edit.add_selection_for_next_occurrence()

# FUNC 将值提取为成员变量
func _create_member_variable(type : String) -> void:
	# 获取当前鼠标行
	var current_line : int = temp_code_edit.get_caret_line()
	# 当前鼠标行的文本
	var line_text : String = _get_current_line_text()
	# 选择的文本
	var selected_text : String = temp_code_edit.get_selected_text()

	var code_text: String = "\nvar new_value : %s = %s" % [type, selected_text]
	var var_line : int = _find_class_and_extends_after()
	if _replace_selection("new_value"):
		temp_code_edit.insert_line_at(var_line, code_text)
		temp_code_edit.select(var_line + 1, 4, var_line + 1, 13)
		temp_code_edit.add_selection_for_next_occurrence()

# FUNC 生成当前行变量声明的 get set
func _create_get_and_set(type : String) -> void:
	var current_line : int = temp_code_edit.get_caret_line()
	var line_text : String = temp_code_edit.get_line(current_line)
	var var_name : String = _get_variable_line_variable_name(line_text)
	var code_text: String = ":\n\tget:\n\t\treturn %s\n\tset(v):\n\t\t%s = v" % [var_name, var_name]
	temp_code_edit.insert_text(code_text, current_line, line_text.length())

# FUNC 生成当前信号连接的方法
func _create_signal_function() -> void:
	var selected_text = _get_selected_text()
	var code_text: String = "\nfunc %s() -> void:\n\tpass" % [selected_text]
	temp_code_edit.insert_line_at(temp_code_edit.get_line_count() - 1, code_text)

# FUNC 生成信号
func _create_signal(type : String) -> void:
	var code_text: String = "\nsignal %s()" % [type]
	var var_line : int = _find_class_and_extends_after()
	temp_code_edit.insert_line_at(var_line, code_text)

# FUNC 生成变量声明
func _create_member_var_declaration(variable_name : String) -> void:
	var code_text: String = "var %s : Variant" % [variable_name]
	var var_line : int = _find_class_and_extends_after()
	temp_code_edit.insert_line_at(var_line, code_text)
	var current_line_length : int = temp_code_edit.get_line(var_line).length()
	temp_code_edit.select(var_line, current_line_length - 7, var_line, current_line_length)

# FUNC 生成临时变量声明
func _create_local_var_declaration(variable_name : String) -> void:
	var current_line : int = temp_code_edit.get_caret_line()
	var code_text: String = "\tvar %s : Variant" % [variable_name]
	temp_code_edit.insert_line_at(current_line, code_text)
	var current_line_length : int = temp_code_edit.get_line(current_line).length()
	temp_code_edit.select(current_line, current_line_length - 7, current_line, current_line_length)

# FUNC 将代码块提取为成员方法
func _create_function_from_code_block(data : Array) -> void:
	var current_line : int = temp_code_edit.get_selection_from_line() + 1
	var code_block : String = ""
	var get_local_vars : Array = []
	var parameters : Array = []
	var var_name_arr : Array = _get_current_script_file_all_variable_name()
	for i in range(_get_code_block_start_and_end().x - 1, _get_code_block_start_and_end().y):
		var line_text : String = temp_code_edit.get_line(i)
		# 获取临时变量的名字
		if line_text.contains("var"):
			get_local_vars.append(_get_variable_line_variable_name(line_text))
		code_block = line_text if i == _get_code_block_start_and_end().x - 1 else code_block + "\n" + line_text
	# 得到所有变量名
	var lines : Array = code_block.split("\n")
	for l in lines:
		for var_parameter in _get_line_all_var(l):
			if var_parameter in parameters: continue
			parameters.append(var_parameter)
	# 排除其中已声明的临时变量
	for parameter in get_local_vars: if parameter in parameters: parameters.erase(parameter)
	# 排除其中已声明的成员变量
	for parameter in var_name_arr: if parameter in var_name_arr: parameters.erase(parameter)
	# 生成入参的文本
	var parameter_str : String = ""
	for i in parameters.size():
		if i == 0:
			parameter_str = parameters[i]
			continue
		parameter_str += ", " + parameters[i]
	var code_text : String = "\nfunc new_func_name(%s) -> void:\n%s" % [parameter_str, code_block]
	var code_line : int = temp_code_edit.get_line_count() - 1
	if _replace_selection("\tnew_func_name(%s)" % parameter_str, true):
		temp_code_edit.insert_line_at(temp_code_edit.get_line_count() - 1, code_text)
		temp_code_edit.select(current_line - 1, 1, current_line - 1, 14)
		temp_code_edit.add_selection_for_next_occurrence()

# FUNC 将临时变量提取为方法的参数
func _create_function_parameter_from_local_variable(data : Array) -> void:
	var line_text : String = data[0]
	var parameter : String = _get_variable_line_variable_name(line_text)
	var parameter_type : String = data[1]
	if parameter_type == "":
		parameter_type = _get_variable_line_variable_type(line_text)
	temp_code_edit.remove_line_at(temp_code_edit.get_caret_line())
	var func_line : int = temp_code_edit.get_caret_line()
	while true:
		if temp_code_edit.get_line(func_line).begins_with("func"): break
		func_line -= 1
	var func_line_text : String = temp_code_edit.get_line(func_line)
	var insert_index : int = func_line_text.find(")")

	var parameter_value : Variant = null
	if line_text.contains("="):
		parameter_value = line_text.erase(0, line_text.find("=") + 1).strip_edges()
		if func_line_text.find("(") + 1 != insert_index:
			temp_code_edit.insert_text(", %s : %s= %s" % [parameter, parameter_type, parameter_value], func_line, insert_index)
			return
		temp_code_edit.insert_text("%s : %s= %s" % [parameter, parameter_type, parameter_value], func_line, insert_index)
		return
	if func_line_text.find("(") + 1 != insert_index:
		temp_code_edit.insert_text(", %s : %s" % [parameter, parameter_type], func_line, insert_index)
		return
	temp_code_edit.insert_text("%s : %s" % [parameter, parameter_type], func_line, insert_index)

# FUNC 判断是否为变量值文本
func _is_variable_value(selected_text : String) -> bool:
	for i in VARIABLE_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(selected_text)
		if result: return true
	return false

# FUNC 判断是否为注释开头行
func _is_begins_with_annotation_line(line_text : String) -> bool:
	return line_text.strip_edges().begins_with("#")

# FUNC 判断选取是否为单行
func _is_selection_one_line() -> bool:
	if not temp_code_edit.get_line(temp_code_edit.get_selection_from_line()).begins_with("\t"): return false
	return temp_code_edit.get_selection_from_line() == temp_code_edit.get_selection_to_line()

# FUNC 当前选中的行是否满足代码块格式
func _is_script_block() -> bool:
	var start_and_end_line : Vector2i = _get_code_block_start_and_end()
	if _get_current_line_text().contains("func "): return false
	if _is_selection_one_line(): return false
	for i in range(start_and_end_line.x, start_and_end_line.y):
		if temp_code_edit.get_line(i - 1).is_empty(): continue
		if not temp_code_edit.get_line(i - 1).begins_with("\t"):
			return false
	return true

# FUNC 判断当前行是否为变量声明
func _is_variable_declaration(line_text : String, is_member : bool = true) -> bool:
	if not _is_selection_one_line(): return false
	if line_text.contains("func "): return false
	if not line_text.contains("var "): return false
	if _is_begins_with_annotation_line(line_text): return false
	if is_member:
		if line_text.begins_with("\t"): return false
	if line_text.ends_with(":"): return false
	for i in VARIABLE_DECLARATION_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(line_text)
		if result:
			return true
	return false

# FUNC 判断当前行是否为信号链接语句
func _is_connect_signal_func(line_text : String, selected_text : String) -> bool:
	if not line_text.contains("connect("): return false
	var regex = RegEx.new()
	regex.compile(ON_METHOD_REGEX_STR)
	var result = regex.search(selected_text)
	if result:
		return true
	return false

# FUNC 判断当前行是否为信号发射格式
func _is_siganl_emit(line_text : String) -> bool:
	return line_text.contains(".emit")

# FUNC 当前行是否满足变量名格式
func _is_var_name(selected_text : String) -> bool:
	var regex = RegEx.new()
	regex.compile(VARIABLE_NAME)
	var result = regex.search(selected_text)
	if result: return true
	return false

# FUNC 获取文件夹中所有脚本的路径
func _get_scripte_file_list(root_path : String) -> Array:
	var scripts := []
	var dir = DirAccess.open(root_path)
	if not dir: return []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		var full_path = root_path.path_join(file_name)

		if dir.current_is_dir() and full_path: # and not full_path.contains("res://addons/"):
			# 递归处理子目录
			scripts.append_array(_get_scripte_file_list(full_path))
		else:
			if file_name.get_extension() == "gd":
				scripts.append(full_path)
		file_name = dir.get_next()
	return scripts

# FUNC 获取当前脚本中的所有变量声明
func _get_current_script_file_all_variable_name() -> Array:
	var result_arr : Array = []
	for v in variable_data["script_path"][get_editor_interface().get_script_editor().get_current_script().resource_path]["variables"]:
		result_arr.append(v)
	return result_arr

# FUNC 获取变量声明中的变量名称
func _get_variable_line_variable_name(line_text : String) -> String:
	if not _is_variable_declaration(line_text, false): return ""
	var var_name : String = ""
	var erase_var : String = line_text.strip_edges().erase(0, 3)
	var var_name_end : int = erase_var.find(":")
	var_name = erase_var.erase(var_name_end, erase_var.length() - var_name_end).strip_edges()
	return var_name

# FUNC 获取变量声明中的变量类型
func _get_variable_line_variable_type(line_text : String) -> String:
	if not _is_variable_declaration(line_text, false): return ""
	var var_type : String = ""
	var erase_var : String = line_text.strip_edges().erase(0, line_text.find(":"))
	if erase_var.contains("="):
		erase_var = line_text.strip_edges().erase(line_text.find("="), line_text.length())
	var_type = erase_var.strip_edges()
	return var_type

# FUNC 获取路径脚本文件的变量声明数据
func _get_all_variable_from_script(script_path : String) -> Dictionary:
	var file : FileAccess = FileAccess.open(script_path, FileAccess.READ)
	var script_text : String = file.get_as_text()
	file.close()
	var scripts : Array = script_text.split("\n")
	var variables : Dictionary
	var global_index : Dictionary
	var current_script_data : Dictionary
	for line_text : String in scripts:
		if not _is_variable_declaration(line_text): continue
		var variable_name : String = _get_variable_line_variable_name(line_text)
		variables[variable_name] = {
			"declaration" : {
				"line" : scripts.find(line_text),
				"column": 4,
				"snippet": line_text,
				"type" : _get_variable_line_variable_name(line_text)
			},
			"references": [ ]
		}
		global_index[variable_name] = [script_path + "#" + variable_name]
	current_script_data["script_path"] = {script_path : {"variables" : variables}}
	current_script_data["global_index"] = global_index
	return current_script_data

# FUNC 获取路径脚本文件的变量变量引用数据
func _get_variable_all_references(script_path : String, variable_name : String, variable_script_path : String) -> void:
	var file : FileAccess = FileAccess.open(script_path, FileAccess.READ)
	var script_text : String = file.get_as_text()
	file.close()
	var scripts : Array = script_text.split("\n")
	var temp : Array
	for line_text : String in scripts:
		if not line_text.begins_with("\t"): continue
		if not line_text.contains(variable_name): continue
		var line_text_split : Array = line_text.strip_edges().split(" ")
		for i : String in line_text_split:
			if not i.contains(variable_name): continue
			if i.split(".").has(variable_name):
				if script_path == variable_script_path:
					temp.append({line_text.strip_edges() : scripts.find(line_text)})
					break
				if i.contains(variable_name + ".") or i.contains("." + variable_name):
					temp.append({line_text.strip_edges() : scripts.find(line_text)})
	variable_data["script_path"][variable_script_path]["variables"][variable_name]["references"].append(temp)

# FUNC 获取变量值文本的类型
func _get_variable_value_type(selected_text : String) -> String:
	for i in VARIABLE_REGEX_MAP.values():
		var regex = RegEx.new()
		regex.compile(i)
		var result = regex.search(selected_text)
		if result: return VARIABLE_REGEX_MAP.find_key(i)
	return ""

# FUNC 获取选中文本的信号名
func _get_signal_name(line_text : String) -> String:
	if line_text.contains(".emit"):
		var emit_start_index : int = line_text.find(".emit")
		var signal_name : String = line_text\
			.erase(emit_start_index, line_text.length() - emit_start_index)\
			.strip_edges()
		return signal_name
	return ""

# FUNC 获取当前选中的行开头、结尾
func _get_code_block_start_and_end() -> Vector2i:
	var code_start_line : int = temp_code_edit.get_selection_from_line() + 1
	var code_end_line : int = temp_code_edit.get_selection_to_line() + 1
	return Vector2i(code_start_line, code_end_line)

# FUNC 获取当前行文本中的所有变量名
func _get_line_all_var(line_text : String) -> Array:
	if line_text.begins_with("\t#"): return []
	var tokens := []
	if line_text.contains("(") and line_text.contains(")"):
		line_text = line_text.replace("(", "( ")
		line_text = line_text.replace(")", " ")
		line_text = line_text.replace(",", " ")
	for t : String in line_text.split(" "):
		if t in ["+", "-", "*", "/", "%", "=", ":", ":=", "+=", '-=', "*=", "/=", "%="]: continue
		if t.strip_edges() == "var": continue
		if t.contains("("): continue
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
		if t == "":
			continue
		tokens.append(t.strip_edges().get_slice(".", 0) if t.strip_edges().contains(".") else t.strip_edges())
	return tokens

# FUNC 获取当前光标下的单词
func _get_word_under_cursor() -> String:
	# 获取光标所在行
	var caret_line : int = temp_code_edit.get_caret_line()
	# 获取光标所在列
	var caret_column : int = temp_code_edit.get_caret_column()
	# 获取光标所在文本
	var line_text : String = temp_code_edit.get_line(caret_line)
	# 设置开始列
	var start : int = caret_column
	var end : int = caret_column
	while start > 0 and line_text[start - 1].is_subsequence_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"): start -= 1
	while end < line_text.length() and line_text[end].is_subsequence_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"): end += 1
	# 返回当前字符串的光标所在部分
	return line_text.substr(start, end - start)

# FUNC 获取当前行的文本：重构
func _get_current_line_text() -> String:
	return temp_code_edit.get_line(temp_code_edit.get_caret_line())

# FUNC 获取当前选择的文本
func _get_selected_text() -> String:
	var selected_text : String = temp_code_edit.get_selected_text().strip_edges()
	if selected_text.is_empty():
		selected_text = _get_word_under_cursor()
	return selected_text
#endregion
