extends Node3D
## 播放烟测（0018）：**真的播一段流**。
##
## 与 importer_smoke 的分工：那个验证"导入器与呈现管线单独正确"，这个验证
## "把零件接起来之后，VideoStreamPlayer 真的能播"——前者是部件，后者是整机。
##
## 片源路径由构建步骤用 `--` 传进来（`OS.get_cmdline_user_args()`）。
## 需要带渲染上下文的 Godot：呈现管线要 RenderingDevice。

const CLASS_NAME := "LunaVideoStream"
const TARGET_FRAMES := 10  # 跑够这些帧就算"在播"
const MAX_FRAMES := 300    # 上限，免得失败时挂住

var _stream: Object = null
var _player: VideoStreamPlayer = null
var _failures := 0
var _frames := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("[playback] PASS  ", label, "  ", detail)
	else:
		_failures += 1
		printerr("[playback] FAIL  ", label, "  ", detail)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var path := ""
	if args.size() > 0:
		path = args[0]
		# 构建步骤传的是相对仓库根的路径，而 Godot 会 chdir 到工程目录（example/…），
		# 所以相对路径要先折算：仓库根 = 工程目录的上两级。
		if not path.is_absolute_path():
			path = ProjectSettings.globalize_path("res://").path_join("../../" + path).simplify_path()
	_check("构建步骤把片源路径传了进来", not path.is_empty(), path)
	if path.is_empty():
		_finish()
		return

	_stream = ClassDB.instantiate(CLASS_NAME)
	_stream.set("file", path)
	_player = VideoStreamPlayer.new()
	_player.stream = _stream
	add_child(_player)
	_player.play()
	_check("播放器进入播放态", _player.is_playing())

	# 跑若干渲染帧：每一帧 VideoStreamPlayer 会调 playback._update，
	# 里面走"取帧 → 导入 → 呈现 → 重指 Texture2DRD"。
	var elapsed := 0
	while elapsed < MAX_FRAMES:
		await get_tree().process_frame
		elapsed += 1
		# 从流那边问计数（Godot 4.6 没有 get_stream_playback，所以诊断入口挂在流上）。
		_frames = int(_stream.call("get_frames_presented"))
		if _frames >= TARGET_FRAMES:
			break

	var texture: Texture2D = _player.get_video_texture()
	_check("拿到了视频纹理（Texture2DRD）", texture != null, str(texture))
	if texture != null:
		_check("纹理尺寸来自片源", texture.get_width() > 0 and texture.get_height() > 0, \
			"%dx%d" % [texture.get_width(), texture.get_height()])
	_check("呈现的帧数在增长", _frames >= 1, "frames=%d（跑了 %d 帧）" % [_frames, elapsed])
	_check("播放位置在推进", _player.stream_position > 0.0, str(_player.stream_position))
	var last_error: String = _stream.call("get_last_error")
	_check("没有报错", last_error.is_empty(), last_error)
	_finish()


func _finish() -> void:
	if _player != null:
		_player.stop()
	print("[playback] 呈现 %d 帧" % _frames)
	if _failures == 0:
		print("[playback] RESULT=PASS")
	else:
		printerr("[playback] RESULT=FAIL failures=", _failures)
	_stream = null
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)
