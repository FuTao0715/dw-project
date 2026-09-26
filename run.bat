@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================================
echo  Data Warehouse ETL Pipeline
echo ============================================================
echo.

python -c "import duckdb" >nul 2>nul
if %errorlevel%==0 goto RUN

echo [INFO] duckdb not found in current Python interpreter.
echo [INFO] current interpreter:
python -c "import sys;print('       '+sys.executable)"
echo [INFO] installing duckdb ...
python -m pip install duckdb

python -c "import duckdb" >nul 2>nul
if not %errorlevel%==0 (
    echo.
    echo [ERROR] auto-install failed.
    echo [ERROR] try one of these manually:
    echo         "C:\path	o\your\python.exe" run_etl.py
    echo         conda activate your_env ^&^& python run_etl.py
    echo         python -m pip install duckdb
    pause
    exit /b 1
)

:RUN
echo [INFO] dependencies OK, running pipeline ...
echo.
python run_etl.py

echo.
pause
