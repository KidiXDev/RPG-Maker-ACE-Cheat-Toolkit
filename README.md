# RPG Maker VX Ace Cheat Toolkit

An in-game cheat menu for RPG Maker VX Ace games. A small Windows patcher
decrypts the game, injects a Ruby cheat module into the game's scripts, and
repacks it. In game, press **CTRL + C** to open a navigable cheat menu — no
memorizing hotkeys.

This is a clean rewrite of [allape/RPG-Maker-ACE-Cheater](https://github.com/allape/RPG-Maker-ACE-Cheater):
same script-injection approach, but with a GUI instead of hotkeys and with the
archive decryption / script (un)packing reimplemented in pure Ruby (no
third-party binaries).

## How it works

1. **Decrypt** `Game.rgss3a` to loose files — pure-Ruby RGSSAD reader
   (`ruby/rgss_decrypter.rb`). The archive is renamed to `Game.rgss3a~` so the
   game runs from the extracted files.
2. **Unpack** `Data/Scripts.rvdata2` into editable `.rb` files — pure-Ruby
   Marshal+zlib (un)packer (`ruby/scripts_packer.rb`).
3. **Inject** the cheat module (`cheat/*.rb`) at the top of `Scene_Base.rb` and
   add `AsCheater.update` at the start of `Scene_Base#update`.
4. **Repack** the scripts back into `Data/Scripts.rvdata2`.

At runtime, `AsCheater.update` watches for **CTRL + C** (via Win32
`GetKeyboardState`). When pressed it opens a modal RGSS3 window overlay and takes
over the update loop, so the underlying scene is frozen while you cheat.

## Requirements

- **To run the patcher:** Windows + [Ruby](https://rubyinstaller.org/) on your
  `PATH` (`ruby -v` should work). The patcher shells out to the embedded Ruby
  tools.
- **To build the patcher:** [Go](https://go.dev/) 1.21+.

## Build

```bash
# Windows
build.bat

# Any host (cross-compile)
./build.sh
```

Produces `RPG-Maker-ACE-Cheater-Patcher.exe`.

## Usage

> ⚠️ **Work on a copy of the game first.** Patching extracts and rewrites game
> files. Keep a pristine backup until you've confirmed everything works.

Put the patcher in the game folder (next to `Game.exe`) and run it. Pick an
operation from the menu:

- **Patch** — install the cheat menu.
- **Restore** — revert to the original (renames `Game.rgss3a~` back, removes the
  unpacked scripts).
- **Re-patch** — restore then patch (e.g. after updating the cheat code).

You can also point it at another folder and/or skip the menu:

```bash
RPG-Maker-ACE-Cheater-Patcher.exe "C:\path\to\game" patch
RPG-Maker-ACE-Cheater-Patcher.exe "C:\path\to\game" restore
RPG-Maker-ACE-Cheater-Patcher.exe "C:\path\to\game" repatch
```

## In-game cheat menu

Open / close with **CTRL + C**. Navigate with the **arrow keys**, confirm with
**Enter**, go back / close with **Esc**.

| Category | Actions |
| --- | --- |
| **Party** | Heal & revive all party · Set all party HP to 1 |
| **Enemies** (battle only) | Kill all enemies · Set enemies HP to 1 · Heal all enemies |
| **Gold** | Gain 10,000 gold |
| **Items** | Browse owned items/weapons/armor; **←/→** to remove/add (hold **Shift** for ×10) |
| **Teleport** | Save current position · Load saved position |
| **Save** | Save game to slot 2 |
| **Custom scripts** | Run `asac.q.rb` / `asac.w.rb` / `asac.e.rb` · Reload them |

### Custom scripts (`asac.*.rb`)

Drop `asac.q.rb`, `asac.w.rb`, or `asac.e.rb` in the **game root folder**. The
matching menu entry `eval`s the file in the cheat context (so `$game_party`,
`$game_map`, etc. are available). Use **Reload** after editing. A runtime error
in one of these scripts can crash the game.

## Project layout

```
main.go                  Go patcher (decrypt → unpack → inject → repack)
ruby/rgss_decrypter.rb   pure-Ruby RGSSAD v1/v3 archive extractor
ruby/scripts_packer.rb   pure-Ruby Scripts.rvdata2 (un)packer (Marshal + zlib)
cheat/01_cheat_windows.rb  RGSS3 window classes for the menu
cheat/02_ascheater.rb      AsCheater module: CTRL+C toggle, menu driver, cheats
build.bat / build.sh     build the patcher
```

The `cheat/*.rb` files are concatenated (in lexical order) and embedded into the
patcher, so adding a `cheat/03_*.rb` file extends the injected payload.

## Notes & limitations

- VX Ace only (RGSSAD v3 / `.rgss3a`). The decrypter also handles v1
  (`.rgssad` / `.rgss2a`) but VX Ace is the tested target.
- Avoid running the patcher from a path with non-ASCII characters.
- The in-game module relies on the VX Ace Ruby runtime (RGSS301) APIs; it does
  not run standalone.

## Credits

- Original concept & cheat logic: [allape/RPG-Maker-ACE-Cheater](https://github.com/allape/RPG-Maker-ACE-Cheater)
- RGSSAD format reference: [uuksu/RPGMakerDecrypter](https://github.com/uuksu/RPGMakerDecrypter)
- Keyboard polling approach: Hime_AllKey
