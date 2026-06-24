# =============================================================================
# RPG Maker VX Ace Cheat Toolkit - AsCheater module
# -----------------------------------------------------------------------------
# Injected at the top of Scripts/Scene_Base.rb. A single call `AsCheater.update`
# is inserted at the start of Scene_Base#update.
#
# Press CTRL + C in game to open the cheat menu. While the menu is open,
# AsCheater.update runs its own modal loop (Graphics.update / Input.update), so
# the underlying scene is frozen and the menu overlays on top. Navigate with the
# arrow keys, confirm with Enter (or the game's OK key), and go back / close with
# Esc (or CTRL + C again).
#
# Original hotkey design and game-object calls are based on the AsCheater module
# by allape (https://github.com/allape/RPG-Maker-ACE-Cheater).
# =============================================================================

module AsCheater
  # Bit set in a GetKeyboardState entry when the key is held down (0x80).
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

  # The menu is driven directly from physical key state (GetKeyboardState) so it
  # works even if the game remaps RPG Maker's logical Input keys (which many
  # heavily-modded games do, e.g. unbinding Enter from the "OK" key).
  MENU_KEYS = {
    confirm: [VK_RETURN, VK_SPACE, VK_Z],
    cancel:  [VK_ESCAPE],
    up:      [VK_UP],
    down:    [VK_DOWN],
    left:    [VK_LEFT],
    right:   [VK_RIGHT],
  }

  # noinspection RubyResolve
  GetKeyboardState = Win32API.new("user32.dll", "GetKeyboardState", "I", "I")

  # Custom user scripts loadable from the game root folder (asac.q.rb, ...).
  LOADABLE_ASAC_INDEXES = %w[q w e]

  # 256-byte buffer that receives the keyboard state each poll.
  # noinspection RubyResolve
  @key_state    = DL::CPtr.new(DL.malloc(256), 256)
  @ctrl_was_down = false

  @menu_open = false
  @stack     = []   # page stack: [{ window:, type:, title:, controls: }, ...]
  @help      = nil

  @prev_down = {}   # previous physical-down state per MENU_KEYS action
  @input     = {}   # this frame's edge-triggered menu actions

  @saved_map_id = -1
  @saved_x      = 0
  @saved_y      = 0

  @loaded_asac_files = {}

  # ---- custom script slots (parity with the reference) ---------------------
  def self.load_asac_files
    LOADABLE_ASAC_INDEXES.each do |index|
      filename = "asac.#{index}.rb"
      @loaded_asac_files[index] = File.read(filename) if File.exist?(filename)
    end
  end

  def self.eval_asac_file(index)
    if @loaded_asac_files[index]
      eval(@loaded_asac_files[index])
      Sound.play_ok
    else
      Sound.play_buzzer
    end
  end

  # ---- keyboard polling for the CTRL+C toggle ------------------------------
  def self.key_down?(vk)
    (@key_state[vk] & DOWN_MASK) == DOWN_MASK
  end

  def self.ctrl_c_down?
    GetKeyboardState.call(@key_state.to_i)
    key_down?(VK_CONTROL) && key_down?(VK_C)
  end

  # True only on the frame CTRL+C transitions from up to down.
  def self.toggle_pressed?
    down = ctrl_c_down?
    edge = down && !@ctrl_was_down
    @ctrl_was_down = down
    edge
  end

  def self.shift_down?
    key_down?(VK_LSHIFT) || key_down?(VK_RSHIFT)
  end

  # Recompute edge-triggered menu actions from the (already polled) key state.
  def self.refresh_menu_input
    MENU_KEYS.each do |name, vks|
      down = vks.any? { |vk| key_down?(vk) }
      @input[name] = down && !@prev_down[name]
      @prev_down[name] = down
    end
  end

  # Accept both our physical keys and RPG Maker's logical keys, for robustness.
  def self.menu_confirm?
    @input[:confirm] || Input.trigger?(:C)
  end

  def self.menu_cancel?
    @input[:cancel] || Input.trigger?(:B)
  end

  def self.in_game?
    !$game_party.nil?
  end

  # ---- entry point (called from Scene_Base#update) -------------------------
  def self.update
    if toggle_pressed?
      @menu_open ? close_menu : open_menu
    end
    return unless @menu_open

    # Modal loop: keep control until the menu is closed so the host scene and
    # its input are fully frozen while the overlay is active.
    while @menu_open
      Graphics.update
      Input.update
      if toggle_pressed?
        close_menu
        break
      end
      update_menu
    end
    Input.update # drop any leftover triggers before the scene resumes
  end

  # ---- menu lifecycle ------------------------------------------------------
  def self.open_menu
    unless in_game?
      @menu_open = false
      return
    end
    @menu_open = true
    @help = Window_CheatHelp.new(0, 0, Graphics.width)
    @stack = []
    push_command_page("Cheat Menu", root_commands)
  end

  def self.close_menu
    @stack.each { |page| page[:window].dispose }
    @stack.clear
    @help.dispose if @help
    @help = nil
    @menu_open = false
    @ctrl_was_down = true # require a fresh press before reopening
  end

  def self.menu_y
    @help ? @help.height : 0
  end

  def self.push_command_page(title, list, controls = "Up/Down: Move   Enter/Z: Select   Esc: Back")
    @stack.last[:window].visible = false unless @stack.empty?
    window = Window_CheatCommand.new(0, menu_y, list)
    @stack.push(window: window, type: :command, title: title, controls: controls)
  end

  def self.push_item_page
    @stack.last[:window].visible = false unless @stack.empty?
    height = Graphics.height - menu_y
    window = Window_CheatItems.new(0, menu_y, Graphics.width, height)
    @stack.push(window: window, type: :items, title: "Items",
                controls: "Left/Right: -/+   Shift: x10   Esc: Back")
  end

  def self.pop_page
    page = @stack.pop
    page[:window].dispose if page
    if @stack.empty?
      close_menu
    else
      @stack.last[:window].visible = true
      @stack.last[:window].activate
    end
  end

  # ---- per-frame menu update ----------------------------------------------
  def self.update_menu
    page = @stack.last
    return unless page
    refresh_menu_input         # snapshot physical key edges for this frame
    page[:window].update       # engine handles cursor movement (arrow keys)
    @help.set_text(page[:title], page[:controls]) if @help
    if page[:type] == :items
      handle_item_input(page[:window])
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

  def self.handle_item_input(window)
    if menu_cancel?
      Sound.play_cancel
      pop_page
      return
    end
    obj = window.item
    unless obj
      Sound.play_buzzer if menu_confirm? || @input[:left] || @input[:right]
      return
    end
    amount = shift_down? ? 10 : 1
    if @input[:right] || menu_confirm?
      $game_party.gain_item(obj, amount)
      Sound.play_ok
      window.refresh
    elsif @input[:left]
      $game_party.gain_item(obj, -amount)
      Sound.play_ok
      window.refresh
    end
  end

  # ---- command definitions -------------------------------------------------
  def self.root_commands
    [
      ["Party",                  :party],
      ["Enemies (battle only)",  :enemies, $game_party.in_battle],
      ["Gain 10,000 Gold",       :gold],
      ["Items - edit quantity",  :items],
      ["Teleport",               :teleport],
      ["Save game to slot 2",    :save],
      ["Custom scripts (asac)",  :scripts],
      ["Close",                  :close],
    ]
  end

  def self.party_commands
    [
      ["Heal & revive all party",  :party_heal],
      ["Set all party HP to 1",    :party_hp1],
      ["Back",                     :back],
    ]
  end

  def self.enemy_commands
    [
      ["Kill all enemies",         :enemy_kill],
      ["Set all enemies HP to 1",  :enemy_hp1],
      ["Heal all enemies",         :enemy_heal],
      ["Back",                     :back],
    ]
  end

  def self.teleport_commands
    [
      ["Save current position",    :tp_save],
      ["Load saved position",      :tp_load],
      ["Back",                     :back],
    ]
  end

  def self.script_commands
    [
      ["Run asac.q.rb",            :asac_q],
      ["Run asac.w.rb",            :asac_w],
      ["Run asac.e.rb",            :asac_e],
      ["Reload asac.*.rb files",   :asac_reload],
      ["Back",                     :back],
    ]
  end

  # ---- action dispatch -----------------------------------------------------
  def self.dispatch(symbol)
    case symbol
    when :party    then push_command_page("Party", party_commands)
    when :enemies  then open_enemies
    when :items    then push_item_page
    when :teleport then push_command_page("Teleport", teleport_commands)
    when :scripts  then push_command_page("Custom scripts", script_commands)
    when :gold     then $game_party.gain_gold(10_000); Sound.play_ok
    when :save     then save_to_slot2
    when :close    then close_menu
    when :back     then Sound.play_cancel; pop_page

    when :party_heal then $game_party.all_members.each(&:recover_all); Sound.play_ok
    when :party_hp1  then party_set_hp_to_one

    when :enemy_kill then troop_action { |e| e.hp = 0 }
    when :enemy_hp1  then troop_action { |e| e.hp = 1 }
    when :enemy_heal then troop_action(:all) { |e| e.recover_all }

    when :tp_save then save_position
    when :tp_load then load_position

    when :asac_q then eval_asac_file("q")
    when :asac_w then eval_asac_file("w")
    when :asac_e then eval_asac_file("e")
    when :asac_reload then load_asac_files; Sound.play_ok

    else Sound.play_buzzer
    end
  end

  # ---- individual cheats ---------------------------------------------------
  def self.party_set_hp_to_one
    $game_party.all_members.each { |actor| actor.hp = 1 if actor.alive? }
    Sound.play_ok
  end

  def self.open_enemies
    unless $game_party.in_battle
      Sound.play_buzzer
      return
    end
    push_command_page("Enemies", enemy_commands)
  end

  # Runs a block over troop members. Pass :all to include dead enemies.
  def self.troop_action(scope = :alive)
    unless $game_party.in_battle
      Sound.play_buzzer
      return
    end
    members = scope == :all ? $game_troop.members : $game_troop.alive_members
    members.each { |enemy| yield enemy }
    Sound.play_ok
  end

  def self.save_position
    @saved_map_id = $game_map.map_id
    @saved_x = $game_player.x
    @saved_y = $game_player.y
    Sound.play_ok
  end

  def self.load_position
    if @saved_map_id != -1
      $game_player.reserve_transfer(@saved_map_id, @saved_x, @saved_y, 0)
      Sound.play_ok
      close_menu # let the map process the transfer
    else
      Sound.play_buzzer
    end
  end

  def self.save_to_slot2
    if $game_party.all_members.empty?
      Sound.play_buzzer
      return
    end
    save_index = 1 # zero-based slot index -> "slot 2"
    if DataManager.respond_to?(:save_game_with_preview)
      DataManager.save_game_with_preview(save_index)
    else
      DataManager.save_game_without_rescue(save_index)
    end
    Sound.play_ok
  end
end

AsCheater.load_asac_files
