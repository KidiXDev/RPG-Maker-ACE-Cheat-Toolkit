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
  if method_defined?(:make_damage_value)
    alias rmvc_damage_make_damage_value make_damage_value
    def make_damage_value(user, item)
      rmvc_damage_make_damage_value(user, item)
      if RMVC.damage_mult > 1 && user.respond_to?(:actor?) && user.actor? &&
         respond_to?(:enemy?) && enemy? && @result.hp_damage > 0
        @result.hp_damage *= RMVC.damage_mult
      end
    end
  end

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
  if method_defined?(:hp=)
    alias rmvc_god_hp= hp=
    def hp=(value)
      if RMVC.god_mode && respond_to?(:actor?) && actor? && value <= 0
        value = 1
      end
      self.rmvc_god_hp = value
    end
  end

  if method_defined?(:die)
    alias rmvc_god_die die
    def die
      return if RMVC.god_mode && respond_to?(:actor?) && actor?
      rmvc_god_die
    end
  end
end

class Game_Party
  if method_defined?(:all_dead?)
    alias rmvc_god_all_dead? all_dead?
    def all_dead?
      return false if RMVC.god_mode
      rmvc_god_all_dead?
    end
  end
end

class Game_Actor
  if method_defined?(:gain_exp)
    alias rmvc_exp_gain_exp gain_exp
    def gain_exp(exp)
      exp *= RMVC.exp_mult if RMVC.exp_mult > 1 && exp > 0
      rmvc_exp_gain_exp(exp)
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

# ---- No Encounters: suppress random battles ---------------------------------
# encounter? gates whether a step can trigger a random battle, so returning
# false disables them while leaving the encounter step counter untouched.
class Game_Player
  if method_defined?(:encounter?)
    alias rmvc_noenc_encounter? encounter?
    def encounter?
      return false if RMVC.no_encounters
      rmvc_noenc_encounter?
    end
  end
end

# Battle-capable map events commonly use "Approach" movement or explicit "Move
# toward Player" route commands before their Battle Processing command. While
# No Encounters is on, keep those roaming enemies from treating the player as a
# target; non-battle NPCs keep their normal movement behaviour.
class Game_Event
  def rmvc_noenc_battle_event?
    return false unless respond_to?(:list) && list
    list.any? { |command| command && command.respond_to?(:code) && command.code == 301 }
  end

  if method_defined?(:near_the_player?)
    alias rmvc_noenc_near_the_player? near_the_player?
    def near_the_player?
      return false if RMVC.no_encounters && rmvc_noenc_battle_event?
      rmvc_noenc_near_the_player?
    end
  end

  if method_defined?(:move_toward_player)
    alias rmvc_noenc_move_toward_player move_toward_player
    def move_toward_player
      return if RMVC.no_encounters && rmvc_noenc_battle_event?
      rmvc_noenc_move_toward_player
    end
  end
end

# Roaming / touch enemies start their fight through the event "Battle Processing"
# command (command_301). Skipping it when No Encounters is on means a roaming
# enemy that walks into the player (Event/Player Touch) no longer starts a
# battle; the rest of its event page still runs. The interpreter treats the
# skipped battle as "no branch taken", so any If Win/Escape/Lose branches are
# passed over and execution continues after them.
class Game_Interpreter
  if method_defined?(:command_301)
    alias rmvc_noenc_command_301 command_301
    def command_301
      return if RMVC.no_encounters
      rmvc_noenc_command_301
    end
  end
end
