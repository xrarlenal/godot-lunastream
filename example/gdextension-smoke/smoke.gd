extends Node3D
## 扩展自检：类是否注册、能否实例化、属性与方法的绑定是否可用。
## 任一项不通过就以非 0 退出码结束，可以直接当 CI 门槛用。

const CLASS_NAME := "LunaVideoStream"

var _failures := 0
var _stream: Object = null


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

	_stream = ClassDB.instantiate(CLASS_NAME)
	# 注意：这里必须是成员变量，不能再用局部别名兜一层——局部变量会在
	# _ready 因 await 挂起期间继续持有引用，把 0022 的延迟释放抵消掉。
	_check("类可实例化", _stream != null, str(_stream))
	if _stream == null:
		_finish()
		return

	_check("继承了 VideoStream", _stream is VideoStream, _stream.get_class())

	var ping: String = _stream.call("ping")
	_check("方法绑定可用", ping.begins_with("lunastream/"), ping)

	_stream.set("decoder", 2)
	_check("枚举属性写入与回读", int(_stream.get("decoder")) == 2, str(_stream.get("decoder")))

	_stream.set("decoder", 99)
	_check("越界枚举值被忽略", int(_stream.get("decoder")) == 2, str(_stream.get("decoder")))

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("[smoke] RESULT=PASS")
	else:
		printerr("[smoke] RESULT=FAIL failures=", _failures)
	# 先松开脚本这份引用，再等一帧，让 deferred 的引用交还有机会执行（见 0022）。
	# 少了任何一步，退出时都会报实例泄漏。
	_stream = null
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)
