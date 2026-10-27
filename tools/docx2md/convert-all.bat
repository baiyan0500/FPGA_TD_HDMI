@echo off
REM Convert every .docx in the Contest folder to Markdown.
REM Double-click to run, or from a terminal:  convert-all.bat  [--txt]

setlocal
set "HERE=%~dp0"
set "ROOT=%HERE%..\.."

node "%HERE%docx2md.js" "%ROOT%" %*

if errorlevel 1 (
  echo.
  echo Conversion finished with errors.
) else (
  echo.
  echo Done.
)
pause
