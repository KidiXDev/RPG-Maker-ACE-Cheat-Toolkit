@echo off
REM Build the Windows patcher executable.
go build -o RPG-Maker-ACE-Cheater-Patcher.exe .
if %ERRORLEVEL% NEQ 0 (
  echo Build failed.
  exit /b %ERRORLEVEL%
)
echo Built RPG-Maker-ACE-Cheater-Patcher.exe
