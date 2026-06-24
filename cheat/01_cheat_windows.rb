# =============================================================================
# RPG Maker VX Ace Cheat Toolkit - GUI windows
# -----------------------------------------------------------------------------
# RGSS3 Window classes used by the in-game cheat menu. They only handle drawing
# and cursor movement; all input decisions are made by the AsCheater module so
# the menu can run as a self-contained modal overlay above any scene.
# =============================================================================

# Top banner: page title, control hints, and a transient feedback line.
class Window_CheatHelp < Window_Base
  def initialize(x, y, width)
    super(x, y, width, fitting_height(3))
    self.z = 10_002
    @title = ""
    @controls = ""
    @feedback = ""
    refresh
  end

  def set_all(title, controls, feedback)
    return if title == @title && controls == @controls && feedback == @feedback
    @title = title
    @controls = controls
    @feedback = feedback
    refresh
  end

  def refresh
    contents.clear
    change_color(normal_color)
    draw_text(0, 0, contents.width, line_height, @title)
    change_color(system_color)
    draw_text(0, line_height, contents.width, line_height, @controls)
    change_color(@feedback.empty? ? normal_color : crisis_color)
    draw_text(0, line_height * 2, contents.width, line_height, @feedback)
    change_color(normal_color)
  end
end

# Generic command list built from [name, symbol, enabled] triples.
class Window_CheatCommand < Window_Command
  MAX_VISIBLE = 12

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

# Generic scrollable list. Rows are arbitrary objects rendered through a
# formatter proc (and an optional icon proc). The AsCheater module decides what
# confirm / left / right do per list.
class Window_CheatList < Window_Selectable
  def initialize(x, y, width, height)
    super(x, y, width, height)
    self.z = 10_000
    @rows = []
    @formatter = nil
    @icon_proc = nil
    activate
  end

  def set_data(rows, formatter, icon_proc = nil)
    @rows = rows || []
    @formatter = formatter
    @icon_proc = icon_proc
    refresh
    select(item_max > 0 ? 0 : -1)
  end

  def col_max
    1
  end

  def item_max
    @rows ? @rows.size : 0
  end

  def current_row
    @rows && index >= 0 ? @rows[index] : nil
  end

  def refresh
    create_contents
    draw_all_items
  end

  def draw_item(i)
    row = @rows[i]
    return unless row
    rect = item_rect_for_text(i)
    if @icon_proc
      icon = @icon_proc.call(row)
      if icon && icon > 0
        draw_icon(icon, rect.x, rect.y)
        rect.x += 24
        rect.width -= 24
      end
    end
    text = @formatter ? @formatter.call(row) : row.to_s
    draw_text(rect, text)
  end

  # Redraw just the selected row after an in-place edit (keeps scroll position).
  def redraw_current
    redraw_item(index) if index >= 0
  end
end
