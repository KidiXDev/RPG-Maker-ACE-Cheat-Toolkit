# =============================================================================
# RPG Maker VX Ace Cheat Toolkit - persistent class hooks
# -----------------------------------------------------------------------------
# These reopen core game classes to implement the toggle cheats that must apply
# continuously (even while the cheat menu is closed). Each hook is a thin alias
# that defers to the original behaviour unless the matching RMVC flag is on.
#
# This file is injected as part of Scene_Base.rb, which loads after all the core
# classes (Game_Battler, Game_Player, ...), so reopening them here is safe. Every
# alias is guarded so a non-standard game (custom battle system, etc.) cannot
# crash on load.
# =============================================================================

# ---- God Mode: party members take no damage and cannot die ------------------
class Game_Battler
  if method_defined?(:execute_damage)
    alias rmvc_god_execute_damage execute_damage
    def execute_damage(user)
      if RMVC.god_mode && actor?
        @result.hp_damage = 0
        @result.mp_damage = 0
      end
      rmvc_god_execute_damage(user)
    end
  end

  if method_defined?(:regenerate_hp)
    alias rmvc_god_regenerate_hp regenerate_hp
    def regenerate_hp
      return if RMVC.god_mode && actor? # ignore slip (poison) damage
      rmvc_god_regenerate_hp
    end
  end
end

class Game_BattlerBase
  if method_defined?(:die)
    alias rmvc_god_die die
    def die
      return if RMVC.god_mode && respond_to?(:actor?) && actor?
      rmvc_god_die
    end
  end
end

# ---- No Clip: the player walks through walls and events ---------------------
class Game_Player
  alias rmvc_clip_passable? passable?
  def passable?(x, y, d)
    return true if RMVC.no_clip
    rmvc_clip_passable?(x, y, d)
  end
end
