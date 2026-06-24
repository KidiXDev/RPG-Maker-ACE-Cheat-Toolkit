// RPG Maker VX Ace Cheat Toolkit - patcher
//
// A standalone Windows CLI that installs an in-game cheat menu into an RPG Maker
// VX Ace game. It:
//  1. Decrypts Game.rgss3a to loose files (pure-Ruby rgss_decrypter.rb).
//  2. Unpacks Data/Scripts.rvdata2 to editable .rb files (scripts_packer.rb).
//  3. Injects the AsCheater cheat module into Scripts/Scene_Base.rb and inserts
//     `AsCheater.update` at the start of Scene_Base#update.
//  4. Repacks Scripts.rvdata2.
//
// The embedded Ruby tools are written to a temp dir and run via `ruby` on PATH.
package main

import (
	"embed"
	"fmt"
	"log"
	"os"
	"os/exec"
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
	SceneBaseSuffix  = "_Scene_Base.rb"
	InjectionCall    = "    AsCheater.update"
	CheatMarker      = "module AsCheater"
)

// Embedded pure-Ruby tools and the cheat payload fragments.
//
//go:embed ruby/*.rb
var rubyTools embed.FS

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

// writeTool extracts an embedded ruby tool to a temp dir and returns its path.
func writeTool(dir, name string) string {
	data, err := rubyTools.ReadFile("ruby/" + name)
	if err != nil {
		Fatalln("Failed to read embedded", name, ":", err)
	}
	dst := filepath.Join(dir, name)
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		Fatalln("Failed to write", dst, ":", err)
	}
	return dst
}

// runRuby executes a ruby script with the game root as cwd.
func runRuby(script string, args ...string) {
	cmdArgs := append([]string{script}, args...)
	cmd := exec.Command("ruby", cmdArgs...)
	output, err := cmd.CombinedOutput()
	if len(output) > 0 {
		Println("ruby", script, ":\n", string(output))
	}
	if err != nil {
		Fatalln("Failed to run ruby", script, ":", err)
	}
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

	if _, err := exec.LookPath("ruby"); err != nil {
		Fatalln("`ruby` was not found on PATH. Install Ruby and try again.")
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
	tmp, err := os.MkdirTemp("", "rpgmac")
	if err != nil {
		Fatalln("Failed to create temp dir:", err)
	}
	defer os.RemoveAll(tmp)

	decrypter := writeTool(tmp, "rgss_decrypter.rb")
	packer := writeTool(tmp, "scripts_packer.rb")

	scriptsRvdata2 := filepath.Join(root, "Data", ScriptsRVDATA2)
	if _, err := os.Stat(scriptsRvdata2); err != nil {
		unzipGame(decrypter, root)
	} else {
		Println("Game already extracted, skipping decryption.")
	}

	injectCheat(packer, root)
	Println("Patched game at", root)
}

func unzipGame(decrypter, root string) {
	Println("Decrypting", GameRGSS3A, "...")
	runRuby(decrypter, root)

	src := filepath.Join(root, GameRGSS3A)
	dst := filepath.Join(root, GameRGSS3ABackup)
	Println("Renaming", src, "->", dst)
	if err := os.Rename(src, dst); err != nil {
		Fatalln("Failed to rename", src, "to", dst, ":", err)
	}
}

func injectCheat(packer, root string) {
	Println("Unpacking", ScriptsRVDATA2, "...")
	runRuby(packer, "decode", root)

	sceneBase := findSceneBase(root)
	if sceneBase == "" {
		Fatalln("Failed to find Scene_Base script under", filepath.Join(root, "Scripts"))
	}

	raw, err := os.ReadFile(sceneBase)
	if err != nil {
		Fatalln("Failed to read", sceneBase, ":", err)
	}
	text := string(raw)
	if strings.Contains(text, CheatMarker) {
		Fatalln("Game already patched.")
	}

	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	injectPoint := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == "def update" {
			injectPoint = i
			break
		}
	}
	if injectPoint < 0 {
		Fatalln("Failed to find 'def update' in", sceneBase)
	}

	var out strings.Builder
	out.WriteString(cheatPayload())
	out.WriteString(strings.Join(lines[:injectPoint+1], "\r\n"))
	out.WriteString("\r\n")
	out.WriteString(InjectionCall)
	out.WriteString("\r\n")
	out.WriteString(strings.Join(lines[injectPoint+1:], "\r\n"))

	if err := os.WriteFile(sceneBase, []byte(out.String()), 0o644); err != nil {
		Fatalln("Failed to write", sceneBase, ":", err)
	}

	Println("Repacking", ScriptsRVDATA2, "...")
	runRuby(packer, "encode", root)
}

// findSceneBase locates the unpacked Scene_Base script (named NNNN_Scene_Base.rb).
func findSceneBase(root string) string {
	scriptsDir := filepath.Join(root, "Scripts")
	matches, err := filepath.Glob(filepath.Join(scriptsDir, "*"+SceneBaseSuffix))
	if err != nil || len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	return matches[0]
}

func restoreGame(root string) {
	src := filepath.Join(root, GameRGSS3ABackup)
	dst := filepath.Join(root, GameRGSS3A)
	if _, err := os.Stat(src); err != nil {
		Fatalln("No backup", src, "found, nothing to restore.")
	}

	for _, dir := range []string{"Scripts"} {
		p := filepath.Join(root, dir)
		if err := os.RemoveAll(p); err != nil {
			Fatalln("Failed to remove", p, ":", err)
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
