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
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/manifoldco/promptui"
	"golang.org/x/sys/windows"
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

const (
	colorReset  = "\x1b[0m"
	colorBold   = "\x1b[1m"
	colorCyan   = "\x1b[36m"
	colorGreen  = "\x1b[32m"
	colorGray   = "\x1b[90m"
	colorYellow = "\x1b[33m"
	colorRed    = "\x1b[31m"
)

var suppressLogging bool

func init() {
	// Enable Virtual Terminal Processing on Windows to support ANSI escape codes.
	stdout := windows.Handle(os.Stdout.Fd())
	var mode uint32
	if err := windows.GetConsoleMode(stdout, &mode); err == nil {
		windows.SetConsoleMode(stdout, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
	}
	stderr := windows.Handle(os.Stderr.Fd())
	if err := windows.GetConsoleMode(stderr, &mode); err == nil {
		windows.SetConsoleMode(stderr, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
	}
}

func pause() {
	log.Println(colorGray + "Press [Enter] to exit..." + colorReset)
	var input string
	_, _ = fmt.Scanln(&input)
}

func Println(args ...any) {
	if suppressLogging {
		return
	}
	if len(args) == 0 {
		log.Println()
		return
	}

	// Convert args to string to check keywords and apply dynamic colors/prefixes
	firstStr, ok := args[0].(string)
	if ok {
		switch {
		case strings.HasPrefix(firstStr, "Decrypting"),
			strings.HasPrefix(firstStr, "Patching"),
			strings.HasPrefix(firstStr, "Renaming"),
			strings.HasPrefix(firstStr, "Target game folder"):
			msg := fmt.Sprintln(args...)
			log.Print(colorCyan + "[*] " + colorReset + msg)
			return

		case strings.HasPrefix(firstStr, "Extracted"),
			strings.HasPrefix(firstStr, "Patched game"),
			strings.HasPrefix(firstStr, "Restored game"):
			msg := fmt.Sprintln(args...)
			log.Print(colorGreen + "[+] " + colorReset + msg)
			return

		case strings.HasPrefix(firstStr, "No backup"):
			msg := fmt.Sprintln(args...)
			log.Print(colorYellow + "[!] " + colorReset + msg)
			return
		}
	}

	log.Println(args...)
}

func Fatalln(args ...any) {
	msg := fmt.Sprint(args...)
	log.Println(colorRed + "[ERROR] " + colorReset + msg)
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

// bellSkipper is a custom writer that ignores the terminal bell (ASCII 7)
// to prevent the annoying warning sound on Windows during navigation.
type bellSkipper struct {
	io.Writer
}

func (b *bellSkipper) Write(data []byte) (int, error) {
	var filtered []byte
	for _, c := range data {
		if c != 7 { // 7 is the bell character (ASCII 7)
			filtered = append(filtered, c)
		}
	}
	if len(filtered) == 0 {
		return len(data), nil
	}
	_, err := b.Writer.Write(filtered)
	if err != nil {
		return 0, err
	}
	return len(data), nil
}

func (b *bellSkipper) Close() error {
	return nil
}

func animateProgress(label string, minimumDuration time.Duration, task func() error) error {
	suppressLogging = true
	defer func() { suppressLogging = false }()

	errChan := make(chan error, 1)
	start := time.Now()
	go func() {
		errChan <- task()
	}()

	spinnerFrames := []string{"|", "/", "-", "\\"}
	frameIdx := 0

	ticker := time.NewTicker(40 * time.Millisecond) // Faster ticks (25 FPS) for smoother animation
	defer ticker.Stop()

	var taskErr error
	taskFinished := false

	for {
		select {
		case err := <-errChan:
			taskErr = err
			taskFinished = true

		case <-ticker.C:
			elapsed := time.Since(start)
			frameIdx = (frameIdx + 1) % len(spinnerFrames)
			spinner := spinnerFrames[frameIdx]

			// Calculate progress percentage linearly based on elapsed time
			percent := (float64(elapsed) / float64(minimumDuration)) * 100.0

			if taskFinished {
				if percent >= 100.0 {
					// Task is finished and minimum duration has elapsed
					drawProgressBar(label, 100.0, "+", colorGreen)
					fmt.Println()
					return taskErr
				}
				drawProgressBar(label, percent, spinner, colorCyan)
			} else {
				// Task is still running; cap progress at 95% until it completes
				if percent >= 95.0 {
					percent = 95.0
				}
				drawProgressBar(label, percent, spinner, colorCyan)
			}
		}
	}
}

func drawProgressBar(label string, percent float64, spinner string, spinnerColor string) {
	width := 30
	completed := int(percent / 100.0 * float64(width))
	if completed > width {
		completed = width
	}
	
	var bar strings.Builder
	for i := 0; i < width; i++ {
		if i < completed {
			bar.WriteString("█")
		} else {
			bar.WriteString("░")
		}
	}
	
	fmt.Printf("\r%s[*] %-30s %s[%s]%s [%s] %3.0f%%", 
		colorReset, label+"...", spinnerColor, spinner, colorReset, bar.String(), percent)
}


func main() {
	log.SetFlags(0)

	if runtime.GOOS != "windows" {
		Fatalln("This program only runs on Windows")
	}

	Println(colorBold + colorCyan + `
 ╔═══════════════════════════════════════════════════════════╗
 ║        RPG Maker VX Ace Cheat Toolkit - Patcher           ║
 ╚═══════════════════════════════════════════════════════════╝` + colorReset)
	Println(colorGray + " In-game menu hotkey: " + colorBold + colorGreen + "CTRL + C" + colorReset)
	Println()

	root := "."
	if len(os.Args) > 1 {
		root = os.Args[1]
	}

	absRoot, err := filepath.Abs(root)
	if err == nil {
		root = absRoot
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
		items := []string{
			"Patch this game (default)",
			"Restore game",
			"Re-patch (restore then patch)",
		}

		templates := &promptui.SelectTemplates{
			Label:    "{{ . | bold }}",
			Active:   "> {{ . | cyan | bold }}",
			Inactive: "  {{ . }}",
			Selected: "+ {{ . | green }}",
		}

		prompt := promptui.Select{
			Label:     "Select an operation",
			Items:     items,
			Templates: templates,
			Stdout:    &bellSkipper{Writer: os.Stdout},
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
		err := animateProgress("Decrypting Game Archive", 800*time.Millisecond, func() error {
			return extractArchive(root)
		})
		if err != nil {
			Fatalln("Failed to decrypt game:", err)
		}

		src := filepath.Join(root, GameRGSS3A)
		dst := filepath.Join(root, GameRGSS3ABackup)
		Println("Renaming", filepath.Base(src), "->", filepath.Base(dst))
		if err := os.Rename(src, dst); err != nil {
			Fatalln("Failed to rename", src, "to", dst, ":", err)
		}
	} else {
		Println("Game already extracted, skipping decryption.")
	}

	err := animateProgress("Patching game scripts", 600*time.Millisecond, func() error {
		return patchScriptsRvdata2(scriptsRvdata2, cheatPayload(), CheatMarker, InjectionCall)
	})
	if err == errAlreadyPatched {
		Fatalln("Game already patched.")
	} else if err != nil {
		Fatalln("Failed to patch scripts:", err)
	}

	Println("Patched game at", root)
}

func restoreGame(root string) {
	err := animateProgress("Restoring original game files", 800*time.Millisecond, func() error {
		src := filepath.Join(root, GameRGSS3ABackup)
		dst := filepath.Join(root, GameRGSS3A)
		if _, err := os.Stat(src); err != nil {
			return fmt.Errorf("no backup %s found, nothing to restore", src)
		}

		// Remove leftover decode artifacts from older Ruby-based versions, if any.
		for _, dir := range []string{"Scripts", "YAML"} {
			if err := os.RemoveAll(filepath.Join(root, dir)); err != nil {
				return fmt.Errorf("failed to remove %s: %w", dir, err)
			}
		}

		scriptsRvdata2 := filepath.Join(root, "Data", ScriptsRVDATA2)
		if err := os.Remove(scriptsRvdata2); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("failed to remove %s: %w", scriptsRvdata2, err)
		}

		if err := os.Rename(src, dst); err != nil {
			return fmt.Errorf("failed to rename %s to %s: %w", src, dst, err)
		}
		return nil
	})
	if err != nil {
		Fatalln(err)
	}

	Println("Restored game at", root)
}
