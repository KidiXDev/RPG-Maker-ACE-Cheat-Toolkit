#!/usr/bin/env bash
# Build the Windows patcher executable (cross-compiles from any host).
set -e
GOOS=windows GOARCH=amd64 go build -o RPG-Maker-ACE-Cheater-Patcher.exe .
echo "Built RPG-Maker-ACE-Cheater-Patcher.exe"
