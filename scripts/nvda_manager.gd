extends Node
class_name HobbitNVDAManager

# Signal emitted when NVDA state changes (started or stopped)
signal nvda_status_changed(active: bool)

# State
var is_nvda_active: bool = false
var bridge_process_pid: int = -1
var bridge_pipe: FileAccess = null
var bridge_available: bool = false

# History and repetitive reading buffers
var last_speech_text: String = ""
var last_event_text: String = ""
var current_location_text: String = ""
var current_exits_text: String = ""
var current_items_npcs_text: String = ""
var current_status_text: String = ""

# Audio ducking timer and state
var _ducking_timer: SceneTreeTimer = null
var _bbcode_regex: RegEx = null
var _heartbeat_timer: Timer = null

func _ready() -> void:
	# Compile BBCode stripper regex
	_bbcode_regex = RegEx.new()
	_bbcode_regex.compile("\\[[^\\]]*\\]")
	
	# Start native bridge
	_start_bridge()
	
	# Heartbeat timer to periodically check if NVDA was opened or closed during play
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.wait_time = 2.5
	_heartbeat_timer.one_shot = false
	_heartbeat_timer.autostart = true
	_heartbeat_timer.timeout.connect(_on_heartbeat_timeout)
	add_child(_heartbeat_timer)

func _exit_tree() -> void:
	_stop_bridge()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_stop_bridge()

# -----------------------------------------------------------------------------
# Bridge Process Management
# -----------------------------------------------------------------------------

func _find_bridge_executable() -> String:
	var possible_paths: Array[String] = []
	
	# 1. Inside project root (for editor and headless runs)
	var p_res = ProjectSettings.globalize_path("res://native/x64/nvda_bridge.exe")
	possible_paths.append(p_res)
	
	# 2. In base directory of running executable (for exported builds)
	var exe_dir = OS.get_executable_path().get_base_dir()
	possible_paths.append(exe_dir + "/nvda_bridge.exe")
	possible_paths.append(exe_dir + "/native/x64/nvda_bridge.exe")
	
	# 3. Development workspace fallback
	possible_paths.append("G:/Coding/The Hobbit Remake/Hobbit_1982_Remake_NVDA/native/x64/nvda_bridge.exe")
	
	for path in possible_paths:
		var norm = path.replace("\\", "/")
		if FileAccess.file_exists(norm):
			return norm
			
	return ""

func _start_bridge() -> void:
	var bridge_path = _find_bridge_executable()
	if bridge_path.is_empty():
		print("[NVDAManager] nvda_bridge.exe not found on disk. Operating in fallback mode.")
		bridge_available = false
		return
		
	# Execute bridge with stdio pipe
	var pipe_res = OS.execute_with_pipe(bridge_path, [])
	if pipe_res.is_empty() or not pipe_res.has("stdio"):
		print("[NVDAManager] Failed to launch nvda_bridge.exe with pipe.")
		bridge_available = false
		return
		
	bridge_pipe = pipe_res["stdio"]
	bridge_process_pid = pipe_res.get("pid", -1)
	
	# Read ready handshake
	if bridge_pipe and bridge_pipe.is_open():
		var line = bridge_pipe.get_line()
		var handshake = JSON.parse_string(line)
		if handshake and typeof(handshake) == TYPE_DICTIONARY and handshake.get("status") == "ready":
			print("[NVDAManager] nvda_bridge.exe connected successfully (v%s, PID %d)" % [
				handshake.get("version", "3.0"), bridge_process_pid
			])
			bridge_available = true
			# Check immediate NVDA status
			check_nvda_status()
		else:
			print("[NVDAManager] Invalid handshake from bridge: %s" % line)
			bridge_available = false

func _stop_bridge() -> void:
	if bridge_pipe and bridge_pipe.is_open():
		_send_command({"cmd": "quit"})
		bridge_pipe.close()
		bridge_pipe = null
	if bridge_process_pid > 0:
		OS.kill(bridge_process_pid)
		bridge_process_pid = -1
	bridge_available = false
	is_nvda_active = false

func _send_command(payload: Dictionary) -> Dictionary:
	if not bridge_pipe or not bridge_pipe.is_open():
		return {}
		
	var json_str = JSON.stringify(payload)
	bridge_pipe.store_string(json_str + "\n")
	bridge_pipe.flush()
	
	var line = bridge_pipe.get_line().strip_edges()
	if line.is_empty():
		return {}
		
	var parsed = JSON.parse_string(line)
	if parsed and typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}

# -----------------------------------------------------------------------------
# Status and Heartbeat
# -----------------------------------------------------------------------------

func check_nvda_status() -> bool:
	if not bridge_available:
		is_nvda_active = false
		return false
		
	var resp = _send_command({"cmd": "test"})
	var was_active = is_nvda_active
	is_nvda_active = bool(resp.get("active", false))
	
	if was_active != is_nvda_active:
		print("[NVDAManager] NVDA status changed: active = %s (code %s)" % [
			str(is_nvda_active), str(resp.get("code", 0))
		])
		nvda_status_changed.emit(is_nvda_active)
		
	return is_nvda_active

func _on_heartbeat_timeout() -> void:
	check_nvda_status()

# -----------------------------------------------------------------------------
# Speech, Braille and Audio Ducking API
# -----------------------------------------------------------------------------

func clean_bbcode(text: String) -> String:
	if text.is_empty():
		return ""
	if _bbcode_regex == null:
		_bbcode_regex = RegEx.new()
		_bbcode_regex.compile("\\[[^\\]]*\\]")
	var clean = _bbcode_regex.sub(text, "", true)
	clean = clean.replace("\t", " ")
	while "  " in clean:
		clean = clean.replace("  ", " ")
	return clean.strip_edges()

func speak(text: String, interrupt: bool = false, is_english: bool = false) -> void:
	var clean_text = clean_bbcode(text)
	if clean_text.is_empty():
		return
		
	last_speech_text = clean_text
	
	# Apply audio ducking to background music for clarity
	_trigger_audio_ducking(clean_text)
	
	if is_nvda_active and bridge_available:
		# Send directly to NVDA Screen Reader via RPC bridge
		var resp = _send_command({
			"cmd": "speak",
			"text": clean_text,
			"interrupt": interrupt
		})
		# Also send to Braille display if available
		_send_command({
			"cmd": "braille",
			"text": clean_text
		})
	else:
		# Fallback: if user enabled accessibility in settings and NVDA is NOT running,
		# use Windows TTS via Godot DisplayServer (never active if NVDA is running!)
		var gs = get_node_or_null("/root/GameState")
		if gs and gs.get("is_accessibility_mode"):
			_fallback_tts_speak(clean_text, interrupt, is_english)

func cancel_speech() -> void:
	if is_nvda_active and bridge_available:
		_send_command({"cmd": "cancel"})
	else:
		if DisplayServer.tts_is_speaking():
			DisplayServer.tts_stop()
	_cancel_audio_ducking()

func braille(text: String) -> void:
	var clean_text = clean_bbcode(text)
	if is_nvda_active and bridge_available and not clean_text.is_empty():
		_send_command({"cmd": "braille", "text": clean_text})

func _trigger_audio_ducking(text: String) -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am and am.has_method("set_ducking"):
		am.set_ducking(true)
		
	# Estimate speech duration based on word count / characters
	var estimated_sec = clampf(float(text.length()) * 0.065, 1.2, 10.0)
	
	if is_inside_tree() and get_tree():
		_ducking_timer = get_tree().create_timer(estimated_sec)
		_ducking_timer.timeout.connect(func():
			var am_res = get_node_or_null("/root/AudioManager")
			if am_res and am_res.has_method("set_ducking"):
				am_res.set_ducking(false)
		)

func _cancel_audio_ducking() -> void:
	var am = get_node_or_null("/root/AudioManager")
	if am and am.has_method("set_ducking"):
		am.set_ducking(false)

func _fallback_tts_speak(text: String, interrupt: bool, is_english: bool) -> void:
	if interrupt and DisplayServer.tts_is_speaking():
		DisplayServer.tts_stop()
		
	var voices = DisplayServer.tts_get_voices()
	var selected_voice = ""
	for v in voices:
		var lang = v.get("language", "").to_lower()
		var v_id = v.get("id", "")
		if is_english:
			if "en" in lang or "english" in lang:
				selected_voice = v_id
				break
		else:
			if "ru" in lang or "russian" in lang:
				selected_voice = v_id
				break
				
	if selected_voice.is_empty() and voices.size() > 0:
		selected_voice = voices[0].get("id", "")
		
	DisplayServer.tts_speak(text, selected_voice, 50, 1.0, 1.0, false)

# -----------------------------------------------------------------------------
# Accessibility Announcements for UI Controls & Screens
# -----------------------------------------------------------------------------

func announce_screen(screen_title: String, hint: String = "", is_en: bool = false) -> void:
	var msg = screen_title
	if not hint.is_empty():
		msg += ". " + hint
	speak(msg, true, is_en)

func announce_control(control: Control, extra_state: String = "", is_en: bool = false) -> void:
	if not control or not control.is_visible_in_tree():
		return
		
	var desc = get_control_description(control, extra_state, is_en)
	if not desc.is_empty():
		speak(desc, true, is_en)

func get_control_description(control: Control, extra_state: String = "", is_en: bool = false) -> String:
	if not control:
		return ""
		
	var text = ""
	var role = ""
	var state = ""
	
	if control is Button:
		text = control.text
		if text.is_empty() and control.tooltip_text:
			text = control.tooltip_text
		role = "button" if is_en else "кнопка"
		if control.disabled:
			state = "disabled" if is_en else "недоступно"
		elif control is CheckBox or control is CheckButton:
			role = "checkbox" if is_en else "флажок"
			state = ("checked" if control.button_pressed else "not checked") if is_en else ("отмечено" if control.button_pressed else "не отмечено")
			
	elif control is Slider:
		var pct = int(round(control.value * 100.0))
		role = "slider" if is_en else "ползунок"
		state = ("%d percent" % pct) if is_en else ("%d процентов" % pct)
		text = control.name
		
	elif control is LineEdit:
		role = "input line" if is_en else "строка ввода"
		if not control.text.is_empty():
			text = control.text
		elif not control.placeholder_text.is_empty():
			text = control.placeholder_text
			
	elif control is OptionButton:
		role = "dropdown list" if is_en else "раскрывающийся список"
		text = control.get_item_text(control.selected)
		state = ("item %d of %d" % [control.selected + 1, control.item_count]) if is_en else ("элемент %d из %d" % [control.selected + 1, control.item_count])
		
	elif control is Label or control is RichTextLabel:
		text = control.text
		role = "text" if is_en else "текст"
		
	var result = text
	if not role.is_empty():
		result += ", " + role
	if not state.is_empty():
		result += ", " + state
	if not extra_state.is_empty():
		result += ". " + extra_state
		
	return clean_bbcode(result)

# -----------------------------------------------------------------------------
# Game World Narration & Shortcuts (F1 - F7, PageUp / PageDown)
# -----------------------------------------------------------------------------

func repeat_location(gs: HobbitGameState) -> void:
	if not gs or not gs.rooms.has(gs.current_room_id):
		return
	var room = gs.rooms[gs.current_room_id]
	var is_en = gs.is_english()
	var title = gs.get_room_name(room)
	var desc = gs.get_room_desc(room)
	var full = (("Location: %s. %s") if is_en else ("Локация: %s. %s")) % [title, desc]
	current_location_text = full
	speak(full, true, is_en)

func repeat_last_event(is_en: bool = false) -> void:
	if last_event_text.is_empty():
		speak("No recent events." if is_en else "Окно событий: пока нет новых записей.", true, is_en)
	else:
		speak(("Recent event: " if is_en else "Событие: ") + last_event_text, true, is_en)

func announce_exits(gs: HobbitGameState) -> void:
	if not gs or not gs.rooms.has(gs.current_room_id):
		return
	var room = gs.rooms[gs.current_room_id]
	var is_en = gs.is_english()
	var raw_exits = room.get("exits", [])
	
	var exit_list: Array = []
	if raw_exits is Array:
		exit_list = raw_exits
	elif raw_exits is Dictionary:
		for k in raw_exits.keys():
			var v = raw_exits[k]
			if v is Dictionary:
				var d = v.duplicate()
				d["direction"] = k
				exit_list.append(d)
				
	if exit_list.is_empty():
		var no_ex = "No visible exits here." if is_en else "Здесь нет видимых путей."
		current_exits_text = no_ex
		speak(no_ex, true, is_en)
		return
		
	var exit_names: Array[String] = []
	for ex in exit_list:
		var dir_name = str(ex.get("direction", ""))
		var dest = int(ex.get("dest", 0))
		var via_obj = int(ex.get("via_obj", 0))
		var dir_str = dir_name
		
		if not is_en:
			var dir_ru = ex.get("direction_ru", "")
			if not str(dir_ru).is_empty():
				dir_str = str(dir_ru)
			else:
				match dir_name.to_lower():
					"north": dir_str = "север"
					"south": dir_str = "юг"
					"east": dir_str = "восток"
					"west": dir_str = "запад"
					"northeast": dir_str = "северо-восток"
					"northwest": dir_str = "северо-запад"
					"southeast": dir_str = "юго-восток"
					"southwest": dir_str = "юго-запад"
					"up": dir_str = "вверх"
					"down": dir_str = "вниз"
					_: dir_str = dir_name
					
		var extra = ""
		if dest > 0 and gs.rooms.has(dest):
			if via_obj > 0 and gs.items.has(via_obj):
				var door = gs.items[via_obj]
				var d_name = gs.get_item_name(door)
				var d_open = door.get("is_open", false)
				extra = (" (%s, open)" % d_name) if d_open else (" (%s, closed)" % d_name)
				if not is_en:
					extra = (" (%s, открыто)" % d_name) if d_open else (" (%s, закрыто)" % d_name)
		else:
			extra = " (blocked)" if is_en else " (заблокировано)"
			
		exit_names.append(dir_str + extra)
		
	var msg = ("Exits: " if is_en else "Доступные пути: ") + ", ".join(exit_names) + "."
	current_exits_text = msg
	speak(msg, true, is_en)

func announce_items_and_npcs(gs: HobbitGameState) -> void:
	if not gs or not gs.rooms.has(gs.current_room_id):
		return
	var is_en = gs.is_english()
	var rid = gs.current_room_id
	
	# Items in room
	var item_names: Array[String] = []
	for iid in gs.items.keys():
		var item = gs.items[iid]
		if int(item.get("location", -999)) == rid:
			item_names.append(gs.get_item_name(item))
			
	# NPCs in room
	var npc_names: Array[String] = []
	for nid in gs.npcs.keys():
		var npc = gs.npcs[nid]
		if int(npc.get("location", -999)) == rid and not npc.get("is_dead", false):
			npc_names.append(gs.get_npc_name(npc))
			
	var parts: Array[String] = []
	if not npc_names.is_empty():
		parts.append(("Present characters: " if is_en else "Здесь находятся: ") + ", ".join(npc_names))
	else:
		parts.append("No one else is here." if is_en else "Поблизости никого нет.")
		
	if not item_names.is_empty():
		parts.append(("Visible objects: " if is_en else "Заметные предметы: ") + ", ".join(item_names))
	else:
		parts.append("No items lying around." if is_en else "Предметов на полу не видно.")
		
	var msg = ". ".join(parts) + "."
	current_items_npcs_text = msg
	speak(msg, true, is_en)

func announce_status(gs: HobbitGameState) -> void:
	if not gs:
		return
	var is_en = gs.is_english()
	var hp = gs.player_health
	var str_val = gs.player_strength
	var turns = gs.turn_count
	var phase_name = ""
	
	match gs.day_phase:
		0: phase_name = "Day" if is_en else "День"
		1: phase_name = "Dusk" if is_en else "Сумерки"
		2: phase_name = "Night" if is_en else "Ночь"
		3: phase_name = "Dawn" if is_en else "Рассвет"
		
	var mode_name = gs.get_current_mode_name()
	
	var msg = ""
	if is_en:
		msg = "Hobbit Status: Health %d of 100. Strength: %d. Time: %s. Turn: %d. Mode: %s." % [
			hp, str_val, phase_name, turns, mode_name
		]
	else:
		msg = "Состояние хоббита: Здоровье %d из 100. Сила: %d. Время суток: %s. Ход: %d. Режим: %s." % [
			hp, str_val, phase_name, turns, mode_name
		]
		
	current_status_text = msg
	speak(msg, true, is_en)

func announce_help(is_en: bool = false) -> void:
	var help_text = ""
	if is_en:
		help_text = "Accessibility Shortcuts: F1: Help. F2: Repeat current location. F3 or F4: Repeat last event. F5: Read exits. F6: Read characters and items. F7: Read Hobbit status. PageUp and PageDown: Scroll message log. Tab: Navigate controls. Enter: Activate."
	else:
		help_text = "Горячие клавиши доступности: F1: Справка. F2: Повторить описание локации. F3 или F4: Повторить последнее событие. F5: Доступные пути и выходы. F6: Персонажи и предметы вокруг. F7: Состояние хоббита. PageUp и PageDown: Листать журнал событий. Tab: Перемещение по элементам. Enter: Активировать."
	speak(help_text, true, is_en)
