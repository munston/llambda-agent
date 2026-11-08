@echo off
chcp 65001 >nul
cd /d "%~dp0"
if "%~1"=="" goto usage
cabal run --project-file=cabal.project -- llambda-agent --config llambda-agent.config %*
exit /b %ERRORLEVEL%

:usage
echo usage: agent.bat [--no-history] ^<task^>
echo.
echo agent.bat "describe this project"
echo agent.bat --no-history "one task, with the 5-turn history off"
exit /b 1
