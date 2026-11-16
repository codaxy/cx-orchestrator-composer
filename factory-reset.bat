@echo off
echo ################################################################
echo #                                                              #
echo # DANGER: This script will stop and remove all CxO containers, #
echo #         networks, and volumes of this stack, then            #
echo #         reset this folder: .env and certs\ are deleted too.  #
echo #                                                              #
echo #         ALL CxO DATA AND HISTORY WILL BE LOST                #
echo #                                                              #
echo ################################################################
echo.

:confirm
set /p choice="Do you want to proceed (yes/no): "
if /i "%choice%"=="yes" goto proceed
if /i "%choice%"=="no" goto cancel
echo Invalid response. Please enter 'yes' or 'no'.
goto confirm

:proceed
echo Stopping and removing containers, networks, and volumes of this stack...
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml down --volumes
if errorlevel 1 (
    echo Docker cleanup failed; the working folder was not reset.
    goto end
)
echo Docker cleanup complete.
echo Resetting the working folder...
git reset --hard HEAD && git clean -dfx
echo Factory reset complete.
goto end

:cancel
echo Nothing to do.
goto end

:end
