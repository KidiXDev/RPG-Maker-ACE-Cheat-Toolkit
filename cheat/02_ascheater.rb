# =============================================================================
# RPG Maker VX Ace Cheat Toolkit - AsCheater module
# -----------------------------------------------------------------------------
# Injected at the top of Scripts/Scene_Base.rb. A single call `AsCheater.update`
# is inserted at the start of Scene_Base#update.
#
# Press CTRL + C in game to open the cheat menu. While it is open, AsCheater
# runs its own modal loop (Graphics.update / Input.update), so the underlying
# scene is frozen and the menu overlays on top. Navigate with the arrow keys,
# confirm with Enter / Z / Space, and go back / close with Esc.
#
# The menu is driven directly from physical key state (GetKeyboardState), so it
# works even when a game remaps RPG Maker's logical Input keys.
#
# Toggle cheats (god mode / no-clip / speed) are implemented as class hooks in
# 03_cheat_hooks.rb and apply continuously, even when the menu is closed.
# =============================================================================

module AsCheater
  # Bit set in a GetKeyboardState entry when the key is held (0x80).
  DOWN_MASK = (0x8 << 0x04)

  # Virtual-key codes (https://learn.microsoft.com/windows/win32/inputdev/virtual-key-codes)
  VK_CONTROL = 0x11
  VK_C       = 0x43
  VK_RETURN  = 0x0D
  VK_SPACE   = 0x20
  VK_Z       = 0x5A
  VK_ESCAPE  = 0x1B
  VK_LEFT    = 0x25
  VK_RIGHT   = 0x27
  VK_UP      = 0x26
  VK_DOWN    = 0x28
  VK_LSHIFT  = 0xA0
  VK_RSHIFT  = 0xA1

  MENU_KEYS = {
    confirm: [VK_RETURN, VK_SPACE, VK_Z],
    cancel:  [VK_ESCAPE],
    up:      [VK_UP],
    down:    [VK_DOWN],
    left:    [VK_LEFT],
    right:   [VK_RIGHT],
  }

  LOADABLE_ASAC_INDEXES = %w[q w e]
  LIST_CAP = 256       # cap rows to keep window bitmaps within texture limits
  FLASH_FRAMES = 150   # how long feedback toasts stay visible

  # noinspection RubyResolve
  GetKeyboardState = Win32API.new("user32.dll", "GetKeyboardState", "I", "I")

  # noinspection RubyResolve
  @key_state     = DL::CPtr.new(DL.malloc(256), 256)
  @ctrl_was_down = false
  @prev_down     = {}
  @input         = {}

  @menu_open  = false
  @stack      = []
  @help       = nil
  @flash_text = ""
  @flash_timer = 0

  @saved_map_id = -1
  @saved_x      = 0
  @saved_y      = 0
  @loaded_asac_files = {}

  # Persistent toggle state (read by the class hooks in 03_cheat_hooks.rb).
  @god_mode = false
  @no_clip  = false
  @speed_mult = 1
  @battle_speed_mult = 1
  @base_frame_rate = nil

  class << self
    attr_reader :god_mode, :no_clip
  end

  # ---- keyboard helpers ----------------------------------------------------
  def self.key_down?(vk)
    (@key_state[vk] & DOWN_MASK) == DOWN_MASK
  end

  def self.shift_down?
    key_down?(VK_LSHIFT) || key_down?(VK_RSHIFT)
  end

  def self.ctrl_c_down?
    GetKeyboardState.call(@key_state.to_i)
    key_down?(VK_CONTROL) && key_down?(VK_C)
  end

  def self.toggle_pressed?
    down = ctrl_c_down?
    edge = down && !@ctrl_was_down
    @ctrl_was_down = down
    edge
  end

  def self.refresh_menu_input
    MENU_KEYS.each do |name, vks|
      down = vks.any? { |vk| key_down?(vk) }
      @input[name] = down && !@prev_down[name]
      @prev_down[name] = down
    end
  end

  def self.menu_confirm?
    @input[:confirm] || Input.trigger?(:C)
  end

  def self.menu_cancel?
    @input[:cancel] || Input.trigger?(:B)
  end

  def self.in_game?
    !$game_party.nil?
  end

  def self.onoff(flag)
    flag ? "ON" : "OFF"
  end

  # ---- entry point (called from Scene_Base#update) -------------------------
  def self.update
    apply_persistent_effects

    if toggle_pressed?
      @menu_open ? close_menu : open_menu
    end
    return unless @menu_open

    while @menu_open
      Graphics.frame_rate = @base_frame_rate if @base_frame_rate # normal menu speed
      Graphics.update
      Input.update
      if toggle_pressed?
        close_menu
        break
      end
      update_menu
    end
    Input.update
  end

  # Continuously-applied effects (speed hack). God mode / no-clip are handled by
  # the class hooks, which simply read @god_mode / @no_clip.
  def self.apply_persistent_effects
    @base_frame_rate ||= Graphics.frame_rate
    mult = @speed_mult
    if $game_party && $game_party.in_battle && @battle_speed_mult > mult
      mult = @battle_speed_mult
    end
    desired = @base_frame_rate * mult
    Graphics.frame_rate = desired if Graphics.frame_rate != desired
  rescue StandardError
    # never let a persistent effect crash the game loop
  end

  # ---- menu lifecycle ------------------------------------------------------
  def self.open_menu
    unless in_game?
      @menu_open = false
      return
    end
    @menu_open = true
    @flash_text = ""
    @flash_timer = 0
    @help = Window_CheatHelp.new(0, 0, Graphics.width)
    @stack = []
    push_command_page("Cheat Menu", method(:root_commands))
  end

  def self.close_menu
    @stack.each { |page| page[:window].dispose }
    @stack.clear
    @help.dispose if @help
    @help = nil
    @menu_open = false
    @ctrl_was_down = true
  end

  def self.menu_y
    @help ? @help.height : 0
  end

  def self.list_height
    Graphics.height - menu_y
  end

  def self.flash(message, ok = true)
    return unless message
    @flash_text = message.to_s
    @flash_timer = FLASH_FRAMES
    ok ? Sound.play_ok : Sound.play_buzzer
  end

  # ---- page stack ----------------------------------------------------------
  def self.push_command_page(title, builder, controls = "Up/Down: Move   Enter/Z: Select   Esc: Back")
    @stack.last[:window].visible = false unless @stack.empty?
    window = Window_CheatCommand.new(0, menu_y, builder.call)
    @stack.push(window: window, type: :command, title: title, controls: controls, builder: builder)
  end

  def self.push_list_page(title, rows, formatter, handlers, controls, icon_proc = nil)
    @stack.last[:window].visible = false unless @stack.empty?
    window = Window_CheatList.new(0, menu_y, Graphics.width, list_height)
    window.set_data(rows, formatter, icon_proc)
    @stack.push(window: window, type: :list, title: title, controls: controls, handlers: handlers)
  end

  def self.pop_page
    page = @stack.pop
    page[:window].dispose if page
    if @stack.empty?
      close_menu
    else
      top = @stack.last[:window]
      top.visible = true
      top.activate
    end
  end

  def self.refresh_current_command_page
    page = @stack.last
    return unless page && page[:type] == :command && page[:builder]
    idx = page[:window].index
    page[:window].dispose
    window = Window_CheatCommand.new(0, menu_y, page[:builder].call)
    window.select([idx, window.item_max - 1].min) if window.item_max > 0
    page[:window] = window
  end

  # ---- per-frame menu update ----------------------------------------------
  def self.update_menu
    page = @stack.last
    return unless page
    refresh_menu_input
    page[:window].update

    if @flash_timer > 0
      @flash_timer -= 1
    else
      @flash_text = ""
    end
    @help.set_all(page[:title], page[:controls], @flash_text) if @help

    if page[:type] == :list
      handle_list_input(page[:window], page)
    else
      handle_command_input(page[:window])
    end
  end

  def self.handle_command_input(window)
    if menu_cancel?
      Sound.play_cancel
      pop_page
    elsif menu_confirm?
      dispatch(window.current_symbol)
    end
  end

  def self.handle_list_input(window, page)
    if menu_cancel?
      Sound.play_cancel
      pop_page
      return
    end

    handlers = page[:handlers]
    key = nil
    key = :confirm if menu_confirm? && handlers[:confirm]
    key ||= :right if @input[:right] && handlers[:right]
    key ||= :left if @input[:left] && handlers[:left]
    return unless key

    row = window.current_row
    unless row
      Sound.play_buzzer
      return
    end

    begin
      message = handlers[key].call(row)
      window.redraw_current if @menu_open && !window.disposed?
      flash(message, true) if message
    rescue StandardError => e
      flash("Error: #{e.message}", false)
    end
  end

  # ---- command-page builders ----------------------------------------------
  def self.root_commands
    [
      ["Party & Stats",            :menu_party],
      ["Gold & Items",             :menu_items],
      ["Battle",                   :menu_battle],
      ["World / Teleport",         :menu_world],
      ["Toggles (God/Clip/Speed)", :menu_toggles],
      ["Switches & Variables",     :menu_data],
      ["Custom Scripts (asac)",    :menu_scripts],
      ["Save game to slot 2",      :save],
      ["Close",                    :close],
    ]
  end

  def self.party_menu_commands
    [
      ["Heal & revive all party", :party_heal],
      ["Set all party HP to 1",   :party_hp1],
      ["Stat editor",             :stat_pick],
      ["Back",                    :back],
    ]
  end

  def self.items_menu_commands
    [
      ["Gain 10,000 Gold",   :gold_10k],
      ["Gain 100,000 Gold",  :gold_100k],
      ["Edit owned items",   :owned_items],
      ["Item spawner",       :spawn_menu],
      ["Back",               :back],
    ]
  end

  def self.battle_menu_commands
    [
      ["Kill all enemies",        :enemy_kill],
      ["Set all enemies HP to 1", :enemy_hp1],
      ["Heal all enemies",        :enemy_heal],
      ["Back",                    :back],
    ]
  end

  def self.world_menu_commands
    [
      ["Teleport to map...",     :map_list],
      ["Save current position",  :tp_save],
      ["Load saved position",    :tp_load],
      ["Back",                   :back],
    ]
  end

  def self.toggle_menu_commands
    [
      ["God Mode: #{onoff(@god_mode)}",            :tog_god],
      ["No Clip: #{onoff(@no_clip)}",              :tog_clip],
      ["Game Speed: #{@speed_mult}x",              :tog_speed],
      ["Battle Speed: #{@battle_speed_mult}x",     :tog_bspeed],
      ["Back",                                     :back],
    ]
  end

  def self.data_menu_commands
    [
      ["Switches explorer",  :switches],
      ["Variables explorer", :variables],
      ["Back",               :back],
    ]
  end

  def self.spawn_menu_commands
    [
      ["Spawn Items",   :spawn_items],
      ["Spawn Weapons", :spawn_weapons],
      ["Spawn Armors",  :spawn_armors],
      ["Back",          :back],
    ]
  end

  def self.script_menu_commands
    [
      ["Run asac.q.rb",      :asac_q],
      ["Run asac.w.rb",      :asac_w],
      ["Run asac.e.rb",      :asac_e],
      ["Reload asac.*.rb",   :asac_reload],
      ["Back",               :back],
    ]
  end

  # ---- command dispatch ----------------------------------------------------
  def self.dispatch(symbol)
    dispatch_action(symbol)
  rescue StandardError => e
    flash("Error: #{e.message}", false)
  end

  def self.dispatch_action(symbol)
    case symbol
    when :menu_party    then push_command_page("Party & Stats", method(:party_menu_commands))
    when :menu_items    then push_command_page("Gold & Items", method(:items_menu_commands))
    when :menu_battle   then push_command_page("Battle", method(:battle_menu_commands))
    when :menu_world    then push_command_page("World / Teleport", method(:world_menu_commands))
    when :menu_toggles  then push_command_page("Toggles", method(:toggle_menu_commands))
    when :menu_data     then push_command_page("Switches & Variables", method(:data_menu_commands))
    when :menu_scripts  then push_command_page("Custom Scripts", method(:script_menu_commands))
    when :spawn_menu    then push_command_page("Item Spawner", method(:spawn_menu_commands))
    when :close         then close_menu
    when :back          then Sound.play_cancel; pop_page

    when :save          then flash(save_to_slot2)

    when :party_heal
      $game_party.all_members.each(&:recover_all)
      flash("Healed & revived #{$game_party.all_members.size} member(s)")
    when :party_hp1
      $game_party.all_members.each { |a| a.hp = 1 if a.alive? }
      flash("Set party HP to 1")
    when :stat_pick     then open_stat_picker

    when :gold_10k
      $game_party.gain_gold(10_000)
      flash("Gold +10,000  (now #{$game_party.gold})")
    when :gold_100k
      $game_party.gain_gold(100_000)
      flash("Gold +100,000  (now #{$game_party.gold})")
    when :owned_items   then open_owned_items
    when :spawn_items   then open_spawn_list(:items)
    when :spawn_weapons then open_spawn_list(:weapons)
    when :spawn_armors  then open_spawn_list(:armors)

    when :enemy_kill
      return unless require_battle
      $game_troop.alive_members.each { |e| e.hp = 0 }
      flash("Killed all enemies")
    when :enemy_hp1
      return unless require_battle
      $game_troop.alive_members.each { |e| e.hp = 1 }
      flash("Set all enemies HP to 1")
    when :enemy_heal
      return unless require_battle
      $game_troop.members.each(&:recover_all)
      flash("Healed all enemies")

    when :map_list  then open_map_list
    when :tp_save   then save_position
    when :tp_load   then load_position
    when :switches  then open_switch_explorer
    when :variables then open_variable_explorer

    when :tog_god
      @god_mode = !@god_mode
      refresh_current_command_page
      flash("God Mode #{onoff(@god_mode)}")
    when :tog_clip
      @no_clip = !@no_clip
      refresh_current_command_page
      flash("No Clip #{onoff(@no_clip)}")
    when :tog_speed
      @speed_mult = @speed_mult >= 4 ? 1 : @speed_mult + 1
      refresh_current_command_page
      flash("Game Speed #{@speed_mult}x")
    when :tog_bspeed
      @battle_speed_mult = @battle_speed_mult >= 4 ? 1 : @battle_speed_mult + 1
      refresh_current_command_page
      flash("Battle Speed #{@battle_speed_mult}x")

    when :asac_q then flash(eval_asac_file("q"), @loaded_asac_files["q"] ? true : false)
    when :asac_w then flash(eval_asac_file("w"), @loaded_asac_files["w"] ? true : false)
    when :asac_e then flash(eval_asac_file("e"), @loaded_asac_files["e"] ? true : false)
    when :asac_reload
      load_asac_files
      flash("Reloaded #{@loaded_asac_files.size} asac script(s)")

    else Sound.play_buzzer
    end
  end

  def self.require_battle
    return true if $game_party.in_battle
    flash("Not in battle", false)
    false
  end

  # ---- list openers --------------------------------------------------------
  def self.step_amount
    shift_down? ? 10 : 1
  end

  def self.open_owned_items
    rows = ($game_party.items + $game_party.weapons + $game_party.armors).compact
    if rows.empty?
      flash("Inventory is empty", false)
      return
    end
    formatter = proc { |o| "#{o.name}   x#{$game_party.item_number(o)}" }
    icon = proc { |o| o.icon_index }
    add = proc do |o|
      $game_party.gain_item(o, step_amount)
      "#{o.name}: #{$game_party.item_number(o)}"
    end
    remove = proc do |o|
      $game_party.gain_item(o, -step_amount)
      "#{o.name}: #{$game_party.item_number(o)}"
    end
    push_list_page("Owned Items (#{rows.size})", rows.first(LIST_CAP), formatter,
                   { confirm: add, right: add, left: remove },
                   "Right/Enter: +   Left: -   Shift: x10   Esc: Back", icon)
  end

  def self.open_spawn_list(kind)
    data = case kind
           when :items   then $data_items
           when :weapons then $data_weapons
           when :armors  then $data_armors
           end
    rows = data.compact.select { |o| !o.name.to_s.empty? }
    if rows.empty?
      flash("No #{kind} in database", false)
      return
    end
    truncated = rows.size > LIST_CAP
    formatter = proc { |o| "#{o.name}   (have #{$game_party.item_number(o)})" }
    icon = proc { |o| o.icon_index }
    add = proc do |o|
      $game_party.gain_item(o, step_amount)
      "#{o.name}: #{$game_party.item_number(o)}"
    end
    remove = proc do |o|
      $game_party.gain_item(o, -step_amount)
      "#{o.name}: #{$game_party.item_number(o)}"
    end
    title = "Spawn #{kind.to_s.capitalize} (#{rows.size}#{truncated ? ", showing #{LIST_CAP}" : ''})"
    push_list_page(title, rows.first(LIST_CAP), formatter,
                   { confirm: add, right: add, left: remove },
                   "Right/Enter: +   Left: -   Shift: x10   Esc: Back", icon)
  end

  def self.open_map_list
    infos = $data_mapinfos
    rows = []
    infos.each_key { |id| rows << [id, infos[id].name] } if infos
    rows.sort_by! { |pair| pair[0] }
    if rows.empty?
      flash("No map info found", false)
      return
    end
    formatter = proc { |pair| sprintf("%03d  %s", pair[0], pair[1]) }
    go = proc { |pair| teleport_to(pair[0]) }
    push_list_page("Teleport - #{rows.size} maps", rows.first(LIST_CAP), formatter,
                   { confirm: go }, "Enter: Teleport   Esc: Back")
  end

  def self.open_switch_explorer
    names = $data_system.switches
    ids = named_data_ids(names)
    formatter = proc { |id| sprintf("%04d %s = %s", id, names[id], $game_switches[id] ? "ON" : "OFF") }
    toggle = proc do |id|
      $game_switches[id] = !$game_switches[id]
      sprintf("Switch %04d = %s", id, $game_switches[id] ? "ON" : "OFF")
    end
    push_list_page("Switches (#{ids.size})", ids, formatter,
                   { confirm: toggle }, "Enter: Toggle   Esc: Back")
  end

  def self.open_variable_explorer
    names = $data_system.variables
    ids = named_data_ids(names)
    formatter = proc { |id| sprintf("%04d %s = %d", id, names[id], $game_variables[id]) }
    inc = proc do |id|
      $game_variables[id] = $game_variables[id] + step_big
      "Variable #{id} = #{$game_variables[id]}"
    end
    dec = proc do |id|
      $game_variables[id] = $game_variables[id] - step_big
      "Variable #{id} = #{$game_variables[id]}"
    end
    push_list_page("Variables (#{ids.size})", ids, formatter,
                   { confirm: inc, right: inc, left: dec },
                   "Right/Enter: +   Left: -   Shift: x100   Esc: Back")
  end

  def self.step_big
    shift_down? ? 100 : 1
  end

  def self.named_data_ids(names)
    ids = []
    (1...names.size).each { |i| ids << i unless names[i].to_s.empty? }
    ids = (1...[names.size, LIST_CAP + 1].min).to_a if ids.empty?
    ids.first(LIST_CAP)
  end

  # ---- stat editor ---------------------------------------------------------
  def self.open_stat_picker
    members = $game_party.all_members
    if members.empty?
      flash("No party members", false)
      return
    end
    formatter = proc { |a| "#{a.name}   Lv.#{a.level}   HP #{a.hp}/#{a.mhp}" }
    pick = proc { |a| open_stat_editor(a); nil }
    push_list_page("Select actor", members, formatter,
                   { confirm: pick }, "Enter: Edit   Esc: Back")
  end

  PARAM_LABELS = ["Max HP", "Max MP", "Attack", "Defense", "M.Attack", "M.Defense", "Agility", "Luck"]

  def self.open_stat_editor(actor)
    rows = []
    rows << { label: "Level", get: proc { actor.level },
              adj: proc { |s| actor.change_level([[actor.level + s, 1].max, actor.max_level].min, false) } }
    rows << { label: "EXP", get: proc { actor.exp },
              adj: proc { |s| actor.change_exp([actor.exp + s * 1000, 0].max, false) } }
    rows << { label: "HP", get: proc { "#{actor.hp}/#{actor.mhp}" },
              adj: proc { |s| actor.hp = [[actor.hp + s * 100, 0].max, actor.mhp].min } }
    rows << { label: "MP", get: proc { "#{actor.mp}/#{actor.mmp}" },
              adj: proc { |s| actor.mp = [[actor.mp + s * 100, 0].max, actor.mmp].min } }
    8.times do |pid|
      rows << { label: "#{PARAM_LABELS[pid]} (+)", get: proc { actor.param(pid) },
                adj: proc { |s| actor.add_param(pid, s * 10) } }
    end

    formatter = proc { |r| "#{r[:label]}: #{r[:get].call}" }
    inc = proc { |r| r[:adj].call(step_amount); "#{r[:label]} -> #{r[:get].call}" }
    dec = proc { |r| r[:adj].call(-step_amount); "#{r[:label]} -> #{r[:get].call}" }
    push_list_page("Stats - #{actor.name}", rows, formatter,
                   { confirm: inc, right: inc, left: dec },
                   "Right/Enter: +   Left: -   Shift: x10   Esc: Back")
  end

  # ---- teleport ------------------------------------------------------------
  def self.teleport_to(map_id)
    x = $game_player.x
    y = $game_player.y
    begin
      data = load_data(sprintf("Data/Map%03d.rvdata2", map_id))
      x = data.width / 2
      y = data.height / 2
    rescue StandardError
      # fall back to current coordinates if the map file can't be read
    end
    $game_player.reserve_transfer(map_id, x, y, 2)
    close_menu
    nil
  end

  def self.save_position
    @saved_map_id = $game_map.map_id
    @saved_x = $game_player.x
    @saved_y = $game_player.y
    flash("Saved position (map #{@saved_map_id} @ #{@saved_x},#{@saved_y})")
  end

  def self.load_position
    if @saved_map_id == -1
      flash("No saved position", false)
      return
    end
    $game_player.reserve_transfer(@saved_map_id, @saved_x, @saved_y, 0)
    close_menu
  end

  # ---- save ----------------------------------------------------------------
  def self.save_to_slot2
    if $game_party.all_members.empty?
      flash("Cannot save: empty party", false)
      return nil
    end
    index = 1 # zero-based -> slot 2
    if DataManager.respond_to?(:save_game_with_preview)
      DataManager.save_game_with_preview(index)
    else
      DataManager.save_game_without_rescue(index)
    end
    "Saved game to slot 2"
  end

  # ---- custom asac scripts -------------------------------------------------
  def self.load_asac_files
    @loaded_asac_files = {}
    LOADABLE_ASAC_INDEXES.each do |index|
      filename = "asac.#{index}.rb"
      @loaded_asac_files[index] = File.read(filename) if File.exist?(filename)
    end
  end

  def self.eval_asac_file(index)
    unless @loaded_asac_files[index]
      return "asac.#{index}.rb not found"
    end
    eval(@loaded_asac_files[index])
    "Ran asac.#{index}.rb"
  rescue StandardError => e
    "asac.#{index}.rb error: #{e.message}"
  end
end

AsCheater.load_asac_files
