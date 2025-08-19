@tool
extends EditorPlugin

var script_editor: ScriptEditor
var current_popup: PopupMenu

const CALLBACK_MENU_PRIORITY = 1500
enum CALLBACK_TYPES { FUNCTION, VARIABLE }

func _enable_plugin() -> void:
	# Add autoloads here.
	pass

func _disable_plugin() -> void:
	# Remove autoloads here.
	pass

func _enter_tree() -> void:
	script_editor = EditorInterface.get_script_editor()
	script_editor.editor_script_changed.connect(_on_script_changed)
	script_editor.editor_script_changed.emit(script_editor.get_current_script())

func _exit_tree() -> void:
	if script_editor and script_editor.is_connected("editor_script_changed", _on_script_changed):
		script_editor.disconnect("editor_script_changed", _on_script_changed)
	_cleanup_current_script()

func _find_code_edit(node: Node) -> CodeEdit:
	if node is CodeEdit: return node
	for child in node.get_children():
		var result = _find_code_edit(child)
		if result: return result
	return null


func _find_popup_menu(node: Node) -> PopupMenu:
	if node is PopupMenu: return node
	for child in node.get_children():
		var result = _find_popup_menu(child)
		if result: return result
	return null

func _on_script_changed(script : Script) -> void:
	_cleanup_current_script()
	var current_editor = script_editor.get_current_editor()
	if not current_editor: return
	var code_edit = _find_code_edit(current_editor)
	if not code_edit: return
	current_popup = _find_popup_menu(current_editor)
	if not current_popup: return
	current_popup.connect("about_to_popup", _on_popup_about_to_show)

func _on_popup_about_to_show() -> void:
	var current_editor : ScriptEditorBase = script_editor.get_current_editor()
	if not current_editor: return

	var code_edit = _find_code_edit(current_editor)
	if not code_edit: return

	var selected_text = _get_selected_text(code_edit)
	if selected_text.is_empty():
		return

	var current_line = get_current_line_text(code_edit)

	#if utils.should_show_create_variable(code_edit, current_line, VARIABLE_NAME_REGEX, _get_editor_settings()):
	_create_menu_item(
		"提取为临时变量",
		code_edit,
		CALLBACK_TYPES.VARIABLE
	)

# FUNC 创建菜单按钮
func _create_menu_item(item_text: String, code_edit: CodeEdit, callback_type: CALLBACK_TYPES) -> void:
	current_popup.add_separator()
	current_popup.add_item(item_text, 1500)

	if current_popup.is_connected("id_pressed", _on_menu_item_pressed):
		current_popup.disconnect("id_pressed", _on_menu_item_pressed)
	current_popup.connect("id_pressed", _on_menu_item_pressed.bind(code_edit, 1500, callback_type))

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

func create_variable(code_edit: CodeEdit) -> void:
	var current_line : int = code_edit.get_caret_line()
	var line_text : String = code_edit.get_line(current_line)
	var selected_text : String = code_edit.get_selected_text()

	var end_column : int = line_text.length()

	var code_text: String = "\tvar new_value := %s" % [selected_text]

	replace_selection(code_edit, "new_value")
	code_edit.insert_line_at(current_line, code_text)
	code_edit.select(current_line, 5, current_line, 14)
	code_edit.add_selection_for_next_occurrence()

func _on_menu_item_pressed(id: int, code_edit: CodeEdit, target_index: int, callback_type: CALLBACK_TYPES):
	create_variable(code_edit)

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
