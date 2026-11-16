@echo off

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Error: You must run this script as an administrator.
    pause
    goto end
)


SET NEWLINE=^& echo.

FIND /C /I "local.keycloak.codaxy-cxo" %WINDIR%\system32\drivers\etc\hosts
IF %ERRORLEVEL% NEQ 0 ECHO %NEWLINE%^127.0.0.1 local.keycloak.codaxy-cxo>>%WINDIR%\System32\drivers\etc\hosts

FIND /C /I "local.codaxy-cxo" %WINDIR%\system32\drivers\etc\hosts
IF %ERRORLEVEL% NEQ 0 ECHO %NEWLINE%^127.0.0.1 local.codaxy-cxo>>%WINDIR%\System32\drivers\etc\hosts
