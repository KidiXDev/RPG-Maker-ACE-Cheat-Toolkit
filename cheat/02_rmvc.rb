# =============================================================================
# RPG Maker VX Ace Cheat Toolkit - RMVC module
# -----------------------------------------------------------------------------
# RMVC = RPG Maker VX Cheat. Injected at the top of Scripts/Scene_Base.rb; a
# single call `RMVC.update` is inserted at the start of Scene_Base#update.
#
# Press CTRL + C in game to open the cheat menu. While it is open, RMVC runs its
# own modal loop (Graphics.update / Input.update), so the underlying scene is
# frozen and the menu overlays on top. Navigate with the arrow keys, confirm
# with Enter / Z / Space, and go back / close with Esc.
#
# The menu is driven directly from physical key state (GetKeyboardState), so it
# works even when a game remaps RPG Maker's logical Input keys.
#
# Toggle cheats (god mode / no-clip / speed) are implemented as class hooks in
# 03_cheat_hooks.rb and apply continuously, even when the menu is closed.
# =============================================================================

module RMVC
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
  VK_BACK    = 0x08

  MENU_KEYS = {
    confirm: [VK_RETURN, VK_SPACE, VK_Z],
    enter:   [VK_RETURN], # confirm key for search lists (Z/Space are used to type)
    cancel:  [VK_ESCAPE],
    up:      [VK_UP],
    down:    [VK_DOWN],
    left:    [VK_LEFT],
    right:   [VK_RIGHT],
  }

  # Printable keys for the live search field (case-insensitive, so all lowercase).
  TYPE_KEYS = {}
  (0x41..0x5A).each { |vk| TYPE_KEYS[vk] = (vk - 0x41 + 97).chr } # A-Z -> a-z
  (0x30..0x39).each { |vk| TYPE_KEYS[vk] = (vk - 0x30 + 48).chr } # 0-9
  (0x60..0x69).each { |vk| TYPE_KEYS[vk] = (vk - 0x60 + 48).chr } # numpad 0-9
  TYPE_KEYS[0x20] = " "
  TYPE_KEYS.freeze

  # Custom user-script slots: drop rmvc.q.rb / rmvc.w.rb / rmvc.e.rb in the game
  # root folder and run them from the "Custom Scripts" menu.
  USER_SCRIPT_SLOTS = %w[q w e]
  LIST_CAP = 256       # cap rows to keep window bitmaps within texture limits
  FLASH_FRAMES = 150   # how long feedback toasts stay visible
  INPUT_REPEAT_WAIT = 20
  INPUT_REPEAT_INTERVAL = 4
  SPEED_MULTIPLIER_MAX = 4
  MULTIPLIER_MAX = 100

  # noinspection RubyResolve
  GetKeyboardState = Win32API.new("user32.dll", "GetKeyboardState", "I", "I")

  # noinspection RubyResolve
  @key_state     = DL::CPtr.new(DL.malloc(256), 256)
  @ctrl_was_down = false
  @prev_down     = {}
  @prev_type     = {}
  @hold_frames   = {}
  @input         = {}

  @menu_open  = false
  @stack      = []
  @help       = nil
  @flash_text = ""
  @flash_timer = 0

  @saved_map_id = -1
  @saved_x      = 0
  @saved_y      = 0
  @user_scripts = {}

  # Persistent toggle state (read by the class hooks in 03_cheat_hooks.rb).
  @god_mode = false
  @no_clip  = false
  @speed_mult = 1
  @battle_speed_mult = 1
  @damage_mult = 1
  @exp_mult = 1
  @base_frame_rate = nil

  class << self
    attr_reader :god_mode, :no_clip, :damage_mult, :exp_mult
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
      @input[name] = repeated_menu_key?(name, down)
      @prev_down[name] = down
    end
  end

  def self.repeated_menu_key?(name, down)
    return false unless down
    @hold_frames[name] = (@hold_frames[name] || 0) + 1
    return true unless @prev_down[name]
    return false unless name == :left || name == :right
    frames = @hold_frames[name]
    frames > INPUT_REPEAT_WAIT && ((frames - INPUT_REPEAT_WAIT) % INPUT_REPEAT_INTERVAL == 0)
  ensure
    @hold_frames[name] = 0 unless down
  end

  # Returns a typed character, :backspace, or nil (edge-detected, one per frame).
  def self.scan_typing
    typed = nil
    back_down = key_down?(VK_BACK)
    typed = :backspace if back_down && !@prev_type[VK_BACK]
    @prev_type[VK_BACK] = back_down
    TYPE_KEYS.each do |vk, ch|
      down = key_down?(vk)
      typed = ch if down && !@prev_type[vk] && typed.nil?
      @prev_type[vk] = down
    end
    typed
  end

  # Seed previous-down state so keys held when a search opens don't auto-type.
  def self.prime_typing
    @prev_type[VK_BACK] = key_down?(VK_BACK)
    TYPE_KEYS.each_key { |vk| @prev_type[vk] = key_down?(vk) }
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

  def self.in_battle?
    !$game_party.nil? && $game_party.in_battle
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

  # Continuously-applied effects. Class hooks read these toggle values, and god
  # mode also gets a small upkeep pass here in case a custom script bypasses them.
  def self.apply_persistent_effects
    @base_frame_rate ||= Graphics.frame_rate
    mult = @speed_mult
    if in_battle? && @battle_speed_mult > mult
      mult = @battle_speed_mult
    end
    desired = @base_frame_rate * mult
    Graphics.frame_rate = desired if Graphics.frame_rate != desired
    keep_party_alive if @god_mode
  rescue StandardError
    # never let a persistent effect crash the game loop
  end

  def self.keep_party_alive
    return unless in_game?
    $game_party.all_members.each do |actor|
      actor.hp = 1 if actor.hp <= 0
      actor.remove_state(actor.death_state_id) if actor.respond_to?(:death_state_id) && actor.state?(actor.death_state_id)
    end
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
    push_command_page("RMVC Cheat Menu", method(:root_commands))
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

  # A list with a live, type-to-filter search field. `name_of` maps a row to the
  # text searched against; `all_rows` may exceed LIST_CAP since filtering narrows
  # it (the displayed slice is always capped to keep the window bitmap sane).
  def self.push_search_list_page(base_title, all_rows, formatter, handlers, controls, name_of, icon_proc = nil)
    @stack.last[:window].visible = false unless @stack.empty?
    window = Window_CheatList.new(0, menu_y, Graphics.width, list_height)
    page = { window: window, type: :search_list, base_title: base_title, controls: controls,
             handlers: handlers, all_rows: all_rows, name_of: name_of,
             formatter: formatter, icon: icon_proc, filter: "" }
    @stack.push(page)
    apply_filter(page)
    prime_typing
  end

  def self.apply_filter(page)
    query = page[:filter].downcase
    rows = page[:all_rows]
    unless query.empty?
      rows = rows.select { |r| page[:name_of].call(r).to_s.downcase.include?(query) }
    end
    page[:window].set_data(rows.first(LIST_CAP), page[:formatter], page[:icon])
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
    update_search_field(page) if page[:type] == :search_list
    page[:window].update

    if @flash_timer > 0
      @flash_timer -= 1
    else
      @flash_text = ""
    end
    @help.set_all(page_title(page), page[:controls], @flash_text) if @help

    case page[:type]
    when :search_list then handle_search_list_input(page[:window], page)
    when :list        then handle_list_input(page[:window], page)
    else                   handle_command_input(page[:window])
    end
  end

  def self.page_title(page)
    return page[:title] unless page[:type] == :search_list
    shown = page[:window].item_max
    total = page[:all_rows].size
    "#{page[:base_title]}  Search: #{page[:filter]}_  (#{shown}/#{total})"
  end

  def self.update_search_field(page)
    ch = scan_typing
    if ch == :backspace
      return if page[:filter].empty?
      page[:filter] = page[:filter][0...-1]
      apply_filter(page)
    elsif ch
      page[:filter] = page[:filter] + ch
      apply_filter(page)
    end
  end

  def self.handle_command_input(window)
    if menu_cancel?
      Sound.play_cancel
      pop_page
    elsif (@input[:left] || @input[:right]) && window.current_item_enabled?
      delta = @input[:right] ? 1 : -1
      return if adjust_command_value(window.current_symbol, delta)
    elsif menu_confirm?
      if window.current_item_enabled?
        dispatch(window.current_symbol)
      else
        Sound.play_buzzer # disabled command (e.g. Battle out of combat)
      end
    end
  end

  def self.adjust_command_value(symbol, delta)
    step = signed_step_amount(delta)
    case symbol
    when :tog_speed
      @speed_mult = adjust_speed_multiplier(@speed_mult, step)
      refresh_current_command_page
      flash("Game Speed #{@speed_mult}x")
      true
    when :tog_bspeed
      @battle_speed_mult = adjust_speed_multiplier(@battle_speed_mult, step)
      refresh_current_command_page
      flash("Battle Speed #{@battle_speed_mult}x")
      true
    when :tog_damage
      @damage_mult = adjust_multiplier(@damage_mult, step)
      refresh_current_command_page
      flash("Damage Multiplier #{@damage_mult}x")
      true
    when :tog_exp
      @exp_mult = adjust_multiplier(@exp_mult, step)
      refresh_current_command_page
      flash("EXP Multiplier #{@exp_mult}x")
      true
    else
      false
    end
  end

  def self.signed_step_amount(direction)
    direction * step_amount
  end

  def self.adjust_speed_multiplier(value, delta)
    [[value + delta, 1].max, SPEED_MULTIPLIER_MAX].min
  end

  def self.adjust_multiplier(value, delta)
    [[value + delta, 1].max, MULTIPLIER_MAX].min
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

  def self.handle_search_list_input(window, page)
    if @input[:cancel]
      # Esc clears the filter first, then leaves the page.
      if page[:filter].empty?
        Sound.play_cancel
        pop_page
      else
        page[:filter] = ""
        apply_filter(page)
        Sound.play_cancel
      end
      return
    end

    handlers = page[:handlers]
    key = nil
    key = :confirm if @input[:enter] && handlers[:confirm] # Enter only (Z/Space type)
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
      ["Battle",                   :menu_battle, in_battle?], # disabled out of battle
      ["World / Teleport",         :menu_world],
      ["Toggles (God/Clip/Speed)", :menu_toggles],
      ["Switches & Variables",     :menu_data],
      ["Custom Scripts (rmvc)",    :menu_scripts],
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
      ["Damage Multiplier: #{@damage_mult}x",      :tog_damage],
      ["EXP Multiplier: #{@exp_mult}x",            :tog_exp],
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
      ["Run rmvc.q.rb",      :user_q],
      ["Run rmvc.w.rb",      :user_w],
      ["Run rmvc.e.rb",      :user_e],
      ["Reload rmvc.*.rb",   :user_reload],
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
    when :menu_toggles  then push_command_page("Toggles", method(:toggle_menu_commands), "Up/Down: Move   Right/Enter: +   Left: -   Shift: x10   Esc: Back")
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
      Sound.play_ok
      close_menu # let the battle resume and trigger the victory sequence
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
    when :tog_speed, :tog_bspeed, :tog_damage, :tog_exp
      adjust_command_value(symbol, 1)

    when :user_q then flash(run_user_script("q"), @user_scripts["q"] ? true : false)
    when :user_w then flash(run_user_script("w"), @user_scripts["w"] ? true : false)
    when :user_e then flash(run_user_script("e"), @user_scripts["e"] ? true : false)
    when :user_reload
      load_user_scripts
      flash("Reloaded #{@user_scripts.size} user script(s)")

    else Sound.play_buzzer
    end
  end

  def self.require_battle
    return true if in_battle?
    flash("Not in battle", false)
    false
  end

  # ---- list openers --------------------------------------------------------
  def self.step_amount
    shift_down? ? 10 : 1
  end

  # Shared +/- handlers for item-like lists (items, weapons, armors).
  def self.item_quantity_handlers
    add = proc do |o|
      $game_party.gain_item(o, step_amount)
      "#{o.name}: #{$game_party.item_number(o)}"
    end
    remove = proc do |o|
      $game_party.gain_item(o, -step_amount)
      "#{o.name}: #{$game_party.item_number(o)}"
    end
    { confirm: add, right: add, left: remove }
  end

  ITEM_CONTROLS = "Type: search   Enter/Right: +   Left: -   Shift: x10   Esc: clear/back"

  def self.open_owned_items
    rows = ($game_party.items + $game_party.weapons + $game_party.armors).compact
    if rows.empty?
      flash("Inventory is empty", false)
      return
    end
    formatter = proc { |o| "#{o.name}   x#{$game_party.item_number(o)}" }
    push_search_list_page("Owned Items", rows, formatter, item_quantity_handlers,
                          ITEM_CONTROLS, proc { |o| o.name }, proc { |o| o.icon_index })
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
    formatter = proc { |o| "#{o.name}   (have #{$game_party.item_number(o)})" }
    push_search_list_page("Spawn #{kind.to_s.capitalize}", rows, formatter, item_quantity_handlers,
                          ITEM_CONTROLS, proc { |o| o.name }, proc { |o| o.icon_index })
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
    name_of = proc { |pair| "#{pair[0]} #{pair[1]}" } # searchable by id or name
    push_search_list_page("Teleport", rows, formatter, { confirm: go },
                          "Type: search   Enter: Teleport   Esc: clear/back", name_of)
  end

  def self.open_switch_explorer
    names = $data_system.switches
    ids = named_ids(names)
    formatter = proc { |id| sprintf("%04d %s = %s", id, names[id], $game_switches[id] ? "ON" : "OFF") }
    toggle = proc do |id|
      $game_switches[id] = !$game_switches[id]
      sprintf("Switch %04d = %s", id, $game_switches[id] ? "ON" : "OFF")
    end
    name_of = proc { |id| "#{id} #{names[id]}" }
    push_search_list_page("Switches", ids, formatter, { confirm: toggle },
                          "Type: search   Enter: Toggle   Esc: clear/back", name_of)
  end

  def self.open_variable_explorer
    names = $data_system.variables
    ids = named_ids(names)
    formatter = proc { |id| sprintf("%04d %s = %d", id, names[id], $game_variables[id]) }
    inc = proc do |id|
      $game_variables[id] = $game_variables[id] + step_big
      "Variable #{id} = #{$game_variables[id]}"
    end
    dec = proc do |id|
      $game_variables[id] = $game_variables[id] - step_big
      "Variable #{id} = #{$game_variables[id]}"
    end
    name_of = proc { |id| "#{id} #{names[id]}" }
    push_search_list_page("Variables", ids, formatter, { confirm: inc, right: inc, left: dec },
                          "Type: search   Right/Enter: +   Left: -   Shift: x100   Esc: clear/back", name_of)
  end

  def self.step_big
    shift_down? ? 100 : 1
  end

  # All ids whose name is set; or every id when none are named. Uncapped (the
  # search list caps what it displays).
  def self.named_ids(names)
    ids = []
    (1...names.size).each { |i| ids << i unless names[i].to_s.empty? }
    ids = (1...names.size).to_a if ids.empty?
    ids
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

  # ---- custom user scripts -------------------------------------------------
  def self.load_user_scripts
    @user_scripts = {}
    USER_SCRIPT_SLOTS.each do |slot|
      filename = "rmvc.#{slot}.rb"
      @user_scripts[slot] = File.read(filename) if File.exist?(filename)
    end
  end

  def self.run_user_script(slot)
    unless @user_scripts[slot]
      return "rmvc.#{slot}.rb not found"
    end
    eval(@user_scripts[slot])
    "Ran rmvc.#{slot}.rb"
  rescue StandardError => e
    "rmvc.#{slot}.rb error: #{e.message}"
  end
end

RMVC.load_user_scripts
