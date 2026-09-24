extends Node3D
## 扩展自检：类是否注册、能否实例化、属性与方法的绑定是否可用。
## 任一项不通过就以非 0 退出码结束，可以直接当 CI 门槛用。

const CLASS_NAME := "LunaVideoStream"

var _failures := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[smoke] PASS  ", label, "  ", detail)
	else:
		_failures += 1
		printerr("[smoke] FAIL  ", label, "  ", detail)


func _ready() -> void:
	_check("扩展已加载且类已注册", ClassDB.class_exists(CLASS_NAME))
	if not ClassDB.class_exists(CLASS_NAME):
		_finish()
		return

	var stream = ClassDB.instantiate(CLASS_NAME)
	_check("类可实例化", stream != null, str(stream))
	if stream == null:
		_finish()
		return

	_check("继承了 VideoStream", stream is VideoStream, stream.get_class())

	var ping: String = stream.call("ping")
	_check("方法绑定可用", ping.begins_with("lunastream/"), ping)

	stream.set("decoder", 2)
	_check("枚举属性写入与回读", int(stream.get("decoder")) == 2, str(stream.get("decoder")))

	stream.set("decoder", 99)
	_check("越界枚举值被忽略", int(stream.get("decoder")) == 2, str(stream.get("decoder")))

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("[smoke] RESULT=PASS")
	else:
		printerr("[smoke] RESULT=FAIL failures=", _failures)
	# 让 deferred 的引用交还有机会执行（见 0022）：否则脚本在同一帧里
	# 创建又退出，插件那一次的延迟释放来不及跑，退出时报实例泄漏。
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)
