# variable_merger.gd
class_name VariableDataMerger extends RefCounted

# 增强健壮性的合并函数
static func merge_index_data(existing_data: Dictionary, new_data: Dictionary) -> Dictionary:
	# 1. 空值安全处理
	if existing_data.is_empty():
		return new_data.duplicate(true) if new_data else {}
	if not new_data:
		return existing_data.duplicate(true)

	# 2. 创建深拷贝
	var result = existing_data.duplicate(true)

	# 3. 安全合并 script_path
	if new_data.has("script_path") and typeof(new_data.script_path) == TYPE_DICTIONARY:
		# 确保结果中有script_path字段
		if not result.has("script_path"):
			result["script_path"] = {}

		for script_path in new_data.script_path:
			# 新脚本路径不存在时直接添加
			if not result.script_path.has(script_path):
				result.script_path[script_path] = new_data.script_path[script_path].duplicate(true)
				continue

			# 合并同脚本的变量数据
			var existing_vars = result.script_path[script_path].variables
			var new_vars = new_data.script_path[script_path].variables

			# 确保variables字段存在
			if not existing_vars:
				existing_vars = {}
				result.script_path[script_path].variables = existing_vars

			for var_name in new_vars:
				# 变量不存在时直接添加
				if not existing_vars.has(var_name):
					existing_vars[var_name] = new_vars[var_name].duplicate(true)
				else:
					# 合并引用列表
					var existing_refs = existing_vars[var_name].references
					var new_refs = new_vars[var_name].references

					for ref_path in new_refs:
						if not ref_path in existing_refs:
							existing_refs.append(ref_path)

	# 4. 安全合并 global_index
	if new_data.has("global_index") and typeof(new_data.global_index) == TYPE_DICTIONARY:
		# 确保结果中有global_index字段
		if not result.has("global_index"):
			result["global_index"] = {}

		var result_global_index = result.global_index

		for var_name in new_data.global_index:
			# 初始化不存在的条目
			if not result_global_index.has(var_name):
				result_global_index[var_name] = []

			# 合并路径列表
			var existing_entries = result_global_index[var_name]
			var new_entries = new_data.global_index[var_name]

			for path in new_entries:
				if not path in existing_entries:
					existing_entries.append(path)

	return result

# 判断引用是否已存在
static func _contains_reference(ref_list: Array, new_ref: Dictionary) -> bool:
	for ref in ref_list:
		if ref.file == new_ref.file and ref.line == new_ref.line:
			return true
	return false
