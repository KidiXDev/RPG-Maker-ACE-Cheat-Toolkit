// RPG Maker VX Ace Cheat Toolkit - patcher
//
// A standalone, dependency-free Windows CLI that installs an in-game cheat menu
// into an RPG Maker VX Ace game. It:
//  1. Decrypts Game.rgss3a to loose files (pure-Go RGSSAD extractor).
//  2. Injects the RMVC cheat module into the Scene_Base script inside
//     Data/Scripts.rvdata2 and inserts `RMVC.update` at the start of
//     Scene_Base#update (pure-Go Marshal + zlib patcher).
//
// No external tools or runtimes are required: the only embedded assets are the
// in-game Ruby cheat scripts, which run inside the game's own RGSS runtime.
package main

import (
	"embed"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/manifoldco/promptui"
)

const (
	GameRGSS3A       = "Game.rgss3a"
	GameRGSS3ABackup = "Game.rgss3a~"
	ScriptsRVDATA2   = "Scripts.rvdata2"
	InjectionCall    = "    RMVC.update"
	CheatMarker      = "module RMVC"
)

//go:embed cheat/*.rb
var cheatFiles embed.FS

func pause() {
	log.Println("Press [Enter] to exit...")
	var input string
	_, _ = fmt.Scanln(&input)
}

func Println(args ...any) { log.Println(args...) }

func Fatalln(args ...any) {
	log.Println(args...)
	pause()
	os.Exit(1)
}

// cheatPayload concatenates cheat/*.rb in lexical order into one script block.
func cheatPayload() string {
	entries, err := cheatFiles.ReadDir("cheat")
	if err != nil {
		Fatalln("Failed to list embedded cheat files:", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".rb") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	var b strings.Builder
	for _, name := range names {
		data, err := cheatFiles.ReadFile("cheat/" + name)
		if err != nil {
			Fatalln("Failed to read embedded cheat/"+name, ":", err)
		}
		b.Write(normalizeCRLF(data))
		b.WriteString("\r\n\r\n")
	}
	return b.String()
}

// normalizeCRLF converts any line endings to CRLF, matching RPG Maker scripts.
func normalizeCRLF(data []byte) []byte {
	s := strings.ReplaceAll(string(data), "\r\n", "\n")
	s = strings.ReplaceAll(s, "\n", "\r\n")
	return []byte(s)
}

func main() {
	log.SetFlags(0)

	if runtime.GOOS != "windows" {
		Fatalln("This program only runs on Windows")
	}

	Println("RPG Maker VX Ace Cheat Toolkit - patcher")
	Println("In-game menu hotkey: CTRL + C")
	Println()

	root := "."
	if len(os.Args) > 1 {
		root = os.Args[1]
	}

	stat, err := os.Stat(root)
	if err != nil {
		Fatalln("Failed to stat", root, ":", err)
	} else if !stat.IsDir() {
		Fatalln(root, "is not a directory")
	}

	Println("Target game folder:", root)

	// Allow a non-interactive operation via the 2nd arg (patch|restore|repatch),
	// useful for scripting/CI. Otherwise show the interactive menu.
	index := -1
	if len(os.Args) > 2 {
		switch strings.ToLower(os.Args[2]) {
		case "patch":
			index = 0
		case "restore":
			index = 1
		case "repatch", "re-patch":
			index = 2
		default:
			Fatalln("Unknown operation:", os.Args[2], "(expected patch|restore|repatch)")
		}
	} else {
		prompt := promptui.Select{
			Label: "Select an operation",
			Items: []string{
				"Patch this game (default)",
				"Restore game",
				"Re-patch (restore then patch)",
			},
		}
		i, _, err := prompt.Run()
		if err != nil {
			fmt.Printf("Prompt failed %v\n", err)
			return
		}
		index = i
	}

	switch index {
	case 0:
		patch(root)
	case 1:
		restoreGame(root)
	case 2:
		if _, err := os.Stat(filepath.Join(root, GameRGSS3ABackup)); err != nil {
			Println("No backup found, nothing to restore; patching directly.")
		} else {
			restoreGame(root)
		}
		patch(root)
	}

	pause()
}

func patch(root string) {
	scriptsRvdata2 := filepath.Join(root, "Data", ScriptsRVDATA2)
	if _, err := os.Stat(scriptsRvdata2); err != nil {
		if err := extractArchive(root); err != nil {
			Fatalln("Failed to decrypt game:", err)
		}
		src := filepath.Join(root, GameRGSS3A)
		dst := filepath.Join(root, GameRGSS3ABackup)
		Println("Renaming", src, "->", dst)
		if err := os.Rename(src, dst); err != nil {
			Fatalln("Failed to rename", src, "to", dst, ":", err)
		}
	} else {
		Println("Game already extracted, skipping decryption.")
	}

	Println("Patching", ScriptsRVDATA2, "...")
	err := patchScriptsRvdata2(scriptsRvdata2, cheatPayload(), CheatMarker, InjectionCall)
	if err == errAlreadyPatched {
		Fatalln("Game already patched.")
	} else if err != nil {
		Fatalln("Failed to patch scripts:", err)
	}

	Println("Patched game at", root)
}

func restoreGame(root string) {
	src := filepath.Join(root, GameRGSS3ABackup)
	dst := filepath.Join(root, GameRGSS3A)
	if _, err := os.Stat(src); err != nil {
		Fatalln("No backup", src, "found, nothing to restore.")
	}

	// Remove leftover decode artifacts from older Ruby-based versions, if any.
	for _, dir := range []string{"Scripts", "YAML"} {
		if err := os.RemoveAll(filepath.Join(root, dir)); err != nil {
			Fatalln("Failed to remove", dir, ":", err)
		}
	}

	scriptsRvdata2 := filepath.Join(root, "Data", ScriptsRVDATA2)
	if err := os.Remove(scriptsRvdata2); err != nil && !os.IsNotExist(err) {
		Fatalln("Failed to remove", scriptsRvdata2, ":", err)
	}

	if err := os.Rename(src, dst); err != nil {
		Fatalln("Failed to rename", src, "to", dst, ":", err)
	}
	Println("Restored game at", root)
}
