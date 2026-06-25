# Repository Guidelines

## Project Structure & Module Organization

This repository builds a Windows patcher for RPG Maker VX Ace games and embeds Ruby cheat scripts into `Scripts.rvdata2`.

- `main.go` contains the CLI/menu flow, patch/restore actions, and user interaction.
- `rgss.go` contains RGSSAD archive and RPG Maker script patching logic.
- `cheat/*.rb` contains injected Ruby modules, loaded in numeric order.
- `screenshot/` stores README images and documentation assets.
- `build.bat` and `build.sh` build `RPG-Maker-ACE-Cheater-Patcher.exe`.

## Build, Test, and Development Commands

- `go build .` checks that the Go package compiles.
- `build.bat` builds the Windows executable on Windows.
- `./build.sh` cross-compiles the Windows executable from Unix-like shells.
- `gofmt -w main.go rgss.go` formats touched Go files.
- `go test ./...` runs all Go tests.

Avoid committing regenerated binaries unless the change intentionally updates the distributed patcher.

## Coding Style & Naming Conventions

Use standard Go formatting with `gofmt`. Keep Go functions small and explicit, especially around binary parsing and patching code where byte offsets matter. Prefer descriptive names and actionable errors.

Ruby files in `cheat/` run inside the RGSS3 runtime, not standalone Ruby. Preserve the `RMVC` namespace and avoid external gems or system Ruby. Catch errors where possible and surface them through the in-game feedback path.

## Testing Guidelines

There is currently no committed test suite. For Go changes, run `rtk go test ./...` and `rtk go build .`. For patching logic, validate against a disposable VX Ace game folder: patch, launch, open the cheat menu with `CTRL + C`, then restore and confirm the original archive is recovered.

When adding tests, prefer table-driven Go tests named `*_test.go`. Use small fixtures and avoid copyrighted game data.

## Security & Configuration Tips

Do not commit game archives, extracted commercial assets, save files, or secrets. Test patch/restore operations on copies, since the tool renames archives and writes into `Data/Scripts.rvdata2`.
