extends Node3D
## CPU 帧导入器自检（0013）。
##
## 需要**真实的渲染上下文**，所以不能加 --headless：导入器要创建 RD 纹理、
## 上传并回读，headless 下连 RenderingDevice 都没有。
##
## 检查项在扩展侧（LunaSelfTest），这里只负责驱动与按退出码报告。
## 必须分两帧：主线程拿到的是**非本地** RenderingDevice，texture_update 要等
## 引擎在帧末提交后才真正生效，所以回读只能在下一帧做（扩展侧有详细注释）。

const CLASS_NAME := "LunaSelfTest"

var _selftest: Object = null
var _failures := 0
var _declared_failures := 0
var _checks := 0


func _ready() -> void:
	if not ClassDB.class_exists(CLASS_NAME):
		printerr("[importer] FAIL  自检类未注册（扩展没加载？）")
		_failures = 1
		_finish()
		return

	_selftest = ClassDB.instantiate(CLASS_NAME)
	print("[importer] 第一阶段：导入与池语义")
	_report(_selftest.call("run"))

	# 让引擎把这一帧提交下去，纹理里才有我们写进去的字节。
	await get_tree().process_frame
	print("[importer] 第二阶段：回读比对")
	_report(_selftest.call("verify"))

	_finish()


func _report(text: String) -> void:
	for raw_line in text.split("\n"):
		var line := String(raw_line)
		if line.is_empty():
			continue
		if line.begins_with("PASS "):
			_checks += 1
			print("[importer] ", line)
		elif line.begins_with("FAIL "):
			_checks += 1
			_failures += 1
			printerr("[importer] ", line)
		elif line.begins_with("TOTAL_FAILURES="):
			_declared_failures += int(line.split("=")[1])
		else:
			print("[importer] （", line, "）")


func _finish() -> void:
	# 扩展侧自报的失败数与脚本侧数出来的必须一致，否则说明结果文本被截断或解析错了。
	if _declared_failures != _failures:
		printerr("[importer] FAIL  扩展侧失败数 ", _declared_failures, " 与脚本侧 ", _failures, " 不一致")
		_failures += 1
	print("[importer] 检查 ", _checks, " 项")
	if _failures == 0:
		print("[importer] RESULT=PASS")
	else:
		printerr("[importer] RESULT=FAIL failures=", _failures)
	_selftest = null
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)
