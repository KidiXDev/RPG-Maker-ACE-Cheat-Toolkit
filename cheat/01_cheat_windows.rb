# =============================================================================
# RPG Maker VX Ace Cheat Toolkit - GUI windows
# -----------------------------------------------------------------------------
# RGSS3 Window classes used by the in-game cheat menu. They only handle drawing
# and cursor movement; all input decisions are made by the AsCheater module so
# the menu can run as a self-contained modal overlay above any scene.
# =============================================================================

# Top banner: shows the current page title and the available controls.
class Window_CheatHelp < Window_Base
  def initialize(x, y, width)
    super(x, y, width, fitting_height(2))
    self.z = 10_001
    @title = ""
    @controls = ""
    refresh
  end

  def set_text(title, controls)
    return if title == @title && controls == @controls
    @title = title
    @controls = controls
    refresh
  end

  def refresh
    contents.clear
    change_color(normal_color)
    draw_text(0, 0, contents.width, line_height, @title)
    change_color(system_color)
    draw_text(0, line_height, contents.width, line_height, @controls)
    change_color(normal_color)
  end
end

# Generic command list built from [name, symbol, enabled] triples.
class Window_CheatCommand < Window_Command
  MAX_VISIBLE = 11

  def initialize(x, y, list, width = 544)
    # NOTE: Window_Command uses @list internally for its commands, so the source
    # list must live under a different name (@cheat_list) to avoid being wiped by
    # clear_command_list during super.
    @cheat_list = list
    @cheat_width = width
    super(x, y)
    self.z = 10_000
  end

  def window_width
    @cheat_width
  end

  def visible_line_number
    count = @cheat_list ? @cheat_list.size : 1
    [[count, 1].max, MAX_VISIBLE].min
  end

  def make_command_list
    (@cheat_list || []).each do |entry|
      name, symbol, enabled = entry
      enabled = true if enabled.nil?
      add_command(name, symbol || :none, enabled)
    end
  end
end

# Scrollable list of every item/weapon/armor the party owns, with quantities.
class Window_CheatItems < Window_Selectable
  def initialize(x, y, width, height)
    super(x, y, width, height)
    self.z = 10_000
    @data = []
    refresh
    select(0)
    activate
  end

  def col_max
    1
  end

  def item_max
    @data ? @data.size : 0
  end

  def item
    @data && index >= 0 ? @data[index] : nil
  end

  def refresh
    make_item_list
    create_contents
    draw_all_items
  end

  def make_item_list
    @data = []
    @data.concat($game_party.items)
    @data.concat($game_party.weapons)
    @data.concat($game_party.armors)
    @data.compact!
  end

  def draw_item(index)
    obj = @data[index]
    return unless obj
    rect = item_rect_for_text(index)
    draw_item_name(obj, rect.x, rect.y, true, rect.width - 64)
    number = $game_party.item_number(obj)
    draw_text(rect, sprintf("x%2d", number), 2)
  end
end
