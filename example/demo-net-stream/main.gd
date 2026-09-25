extends Node2D
## LunaStream 网络流 Demo：把一路网络流拉下来，用 `VideoStreamPlayer` 播出来。
##
## 这是个 **2D** 工程。`VideoStreamPlayer` 本身是 Control，引擎把它当 2D 画；
## 3D 里的用法不一样（拿 `stream.get_texture()` 当贴图给材质），见 README。
##
## 直接跑（窗口）：
##   /Applications/Godot.app/Contents/MacOS/Godot --path example/demo-net-stream
## 脚本化跑（不弹窗口，跑完自己退出，打印 RESULT=PASS/FAIL）：
##   … --headless --path example/demo-net-stream -- --url rtmp://… --seconds 10
## 窗口跑 + 截图（验证"画面上真的有画面"）：
##   … --path example/demo-net-stream -- --snapshot /tmp/demo.png

const STREAM_CLASS := "LunaVideoStream"

## 起始地址列表（顶栏里可以随时改成别的）。
##
## 第一条是本机 RTSP：由 `serve-rtsp.sh` 起，**保证有画面**，用来验 RTSP 这条路
##（插件对 RTSP 一律走 TCP，见 src/ffsw/ffsw_shim.c）。
##
## 后面几条是 2026-09-25 实测拉通过的**公网 RTMP**（h264，只取视频轨）。注意：
## 当天 10:2x 还在出 1920x1080，10:5x 再去连就握手失败了——公开测试流就是这样，
## 活着时能用，死了就换一条。协议这件事是插件的事，跟流从哪来无关。
const DEFAULT_URLS: Array[String] = [
	"rtsp://127.0.0.1:8554/live", # 本机 RTSP（example/demo-net-stream/serve-rtsp.sh）
	"rtmp://95.67.11.153/klive/stream", # 公网 RTMP 1920x1080（实测过，会飘）
	"rtmp://212.92.13.108/live/livestream1", # 公网 RTMP 960x540（实测过，会飘）
	"rtmp://stream1.antenaplay.ro/live/MireasaExtra", # 公网 RTMP 854x480（实测过，会飘）
]

## 状态码与 core 的 `playback_state.State` 一致。
const STATE_NAMES := ["idle", "opening", "playing", "stalled", "failed", "off"]

var _stream: Object = null
var _player: VideoStreamPlayer = null
var _url_edit: LineEdit = null
var _info: Label = null

# 命令行参数（`--` 之后的那些）
var _url := ""
var _auto_play := true
var _quit_after_seconds := 0.0
var _snapshot_path := ""
var _snapshot_after_seconds := 0.0 # 想让截图落在片中（而不是开头的黑场）就设它
var _decoder := -1 # -1 = 不改，用插件默认的 auto

# 运行态
var _state := 0
var _frames := 0
var _stats: Dictionary = {}
var _started_msec := 0
var _finishing := false


func _ready() -> void:
	_parse_args()
	_build_video_layer()
	_build_ui()

	if _url.is_empty():
		_url = DEFAULT_URLS[0]
	_url_edit.text = _url
	_started_msec = Time.get_ticks_msec()

	if _auto_play:
		_play(_url)
	else:
		_set_info("空转中（--no-autoplay）：填一个流地址，点“播放”。")


func _process(_delta: float) -> void:
	if _stream != null:
		_refresh_info()
	if _finishing:
		return
	# 截图模式：等画面真的出来（30 帧）再拍；如果一直没画面（比如源连不上），
	# 6 秒后也拍一张——那种情况下的截图正好用来展示诊断信息。
	# `--snapshot-after N` 再把"拍"推迟到第 N 秒，好让画面落在片中而不是开场黑场。
	if not _snapshot_path.is_empty() and _elapsed_seconds() >= _snapshot_after_seconds:
		if _frames >= 30 or _elapsed_seconds() >= 6.0:
			_capture_and_finish()
			return
	if _quit_after_seconds > 0.0 and _elapsed_seconds() >= _quit_after_seconds:
		_finish()


# --- 场景搭建 -------------------------------------------------------------

func _build_video_layer() -> void:
	# 视频单独一层，UI 再叠在它上面（layer 大的在上面）。
	var video_layer := CanvasLayer.new()
	video_layer.name = "Video"
	video_layer.layer = 0
	add_child(video_layer)

	_player = VideoStreamPlayer.new()
	_player.name = "Player"
	_player.expand = true # 撑满整块区域，按窗口大小缩放
	_player.set_anchors_preset(Control.PRESET_FULL_RECT)
	video_layer.add_child(_player)


func _build_ui() -> void:
	var ui_layer := CanvasLayer.new()
	ui_layer.name = "UI"
	ui_layer.layer = 1
	add_child(ui_layer)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12
	box.offset_top = 12
	box.offset_right = -12
	box.offset_bottom = -12
	# 容器本身不吃鼠标事件，但里面的 LineEdit / Button 照常能点。
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(box)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	_url_edit = LineEdit.new()
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_url_edit.placeholder_text = "rtmp:// / rtsp:// / http(s):// / 本地文件路径"
	_url_edit.text_submitted.connect(_on_url_submitted)
	row.add_child(_url_edit)

	var play_button := Button.new()
	play_button.text = "播放"
	play_button.pressed.connect(_on_play_pressed)
	row.add_child(play_button)

	var stop_button := Button.new()
	stop_button.text = "停止"
	stop_button.pressed.connect(_stop)
	row.add_child(stop_button)

	_info = Label.new()
	_info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_info.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 背景是视频，纯白字会糊在亮画面上，所以描边。
	_info.add_theme_color_override("font_outline_color", Color.BLACK)
	_info.add_theme_constant_override("outline_size", 6)
	_info.add_theme_font_size_override("font_size", 16)
	box.add_child(_info)


# --- 播放控制 -------------------------------------------------------------

func _on_play_pressed() -> void:
	_play(_url_edit.text)


func _on_url_submitted(text: String) -> void:
	_play(text)


func _play(url: String) -> void:
	var target := url.strip_edges()
	if target.is_empty():
		return

	_stop()
	_frames = 0
	_state = 0
	_stats = {}
	_started_msec = Time.get_ticks_msec()

	_stream = ClassDB.instantiate(STREAM_CLASS)
	# `file` 就是"路径或 URI"——这是 VideoStream 自己的定义，本地文件与网络流走同一个口。
	_stream.set("file", target)
	if _decoder >= 0:
		_stream.set("decoder", _decoder)
	# 0019 的重连参数对公网直播流有用：卡住 4 秒算停滞，退避重连最多 3 次。
	_stream.set_stall_timeout_ms(4000)
	_stream.set_reconnect_max_attempts(3)
	_stream.set_reconnect_backoff_max_ms(2000)
	_stream.state_changed.connect(_on_state_changed)
	_stream.frame_ready.connect(_on_frame_ready)
	_stream.stats_updated.connect(_on_stats_updated)

	_player.stream = _stream
	_player.play()
	print("[demo] playing ", target)


func _stop() -> void:
	if _player != null:
		_player.stop()
		_player.stream = null
	# 脚本这份引用也要松开，否则退出时 Godot 会报实例泄漏（0022）。
	_stream = null
	_state = 0
	if _info != null and not _finishing:
		_set_info("已停止。")


func _on_state_changed(state: int) -> void:
	_state = state
	print("[demo] state -> ", state, " (", _state_name(state), ")")


func _on_frame_ready() -> void:
	_frames += 1


func _on_stats_updated(stats: Dictionary) -> void:
	_stats = stats


# --- 命令行参数 -----------------------------------------------------------

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--url":
				if i + 1 < args.size():
					i += 1
					_url = args[i]
			"--seconds":
				if i + 1 < args.size():
					i += 1
					_quit_after_seconds = float(args[i])
			"--snapshot":
				if i + 1 < args.size():
					i += 1
					_snapshot_path = args[i]
			"--snapshot-after":
				if i + 1 < args.size():
					i += 1
					_snapshot_after_seconds = float(args[i])
			"--no-autoplay":
				_auto_play = false
			"--decoder":
				# 0=auto 1=hardware 2=software，与插件的 `decoder` 枚举一致。
				if i + 1 < args.size():
					i += 1
					match args[i]:
						"auto":
							_decoder = 0
						"hardware", "hw":
							_decoder = 1
						"software", "sw":
							_decoder = 2
						_:
							_decoder = int(args[i])
			_:
				pass
		i += 1


# --- 收尾 ----------------------------------------------------------------

func _capture_and_finish() -> void:
	_finishing = true
	# 必须等这一帧画完，否则拿到的是上一帧（甚至空白）。
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_snapshot_path)
	print("[demo] snapshot ", _snapshot_path, " -> ", "OK" if err == OK else "失败 " + str(err))
	_finish()


func _finish() -> void:
	if _finishing and _stream == null:
		return
	_finishing = true
	# 判据与窗口跑一致：**出现过画面**（帧在涨）且状态走到了 playing。
	var ok := _frames > 0 and (_state == 2 or int(_stats.get("frames_presented", 0)) > 0)
	print("[demo] frames=", _frames, " state=", _state, " (", _state_name(_state), ") stats=", _stats)
	print("[demo] RESULT=", "PASS" if ok else "FAIL")

	if _player != null:
		_player.stop()
		_player.stream = null
	_stream = null
	# 松手之后等一帧，让 deferred 的引用交还有机会执行（0022）。
	await get_tree().process_frame
	get_tree().quit(0 if ok else 1)


# --- 显示 ----------------------------------------------------------------

func _refresh_info() -> void:
	var text := "状态 %s   帧 %d" % [_state_name(_state), _frames]
	if not _stats.is_empty():
		text += "   呈现 %d   位置 %.2fs" % [
			int(_stats.get("frames_presented", 0)),
			float(_stats.get("position_seconds", 0.0)),
		]
		var stalls := int(_stats.get("stalls", 0))
		var reconnects := int(_stats.get("reconnects", 0))
		if stalls > 0 or reconnects > 0:
			text += "   停滞 %d   重连 %d" % [stalls, reconnects]
	var last_error: String = _stream.call("get_last_error")
	if not last_error.is_empty():
		text += "\n错误：" + last_error
	_set_info(text)


func _set_info(text: String) -> void:
	if _info != null:
		_info.text = text


func _state_name(state: int) -> String:
	if state >= 0 and state < STATE_NAMES.size():
		return STATE_NAMES[state]
	return "?"


func _elapsed_seconds() -> float:
	return float(Time.get_ticks_msec() - _started_msec) / 1000.0
