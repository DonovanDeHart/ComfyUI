@echo off
setlocal EnableExtensions

rem ============================================================================
rem ComfyUI RTX 5080 PRODUCTION LAUNCHER (MISSION-CRITICAL)
rem ============================================================================
rem What this does:
rem   - Uses ONLY B:\ComfyUI\venv\Scripts\python.exe (never system Python)
rem   - Validates driver + PyTorch CUDA availability
rem   - Auto-detects the RTX 5080's NVIDIA GPU index via nvidia-smi (no guessing)
rem   - Exports CUDA_VISIBLE_DEVICES=<that index> for this process tree only
rem   - Launches ComfyUI normally (main.py)
rem
rem Safety:
rem   - Uses setlocal, so environment changes do NOT escape this window
rem   - Does NOT modify ComfyUI source or install anything
rem ============================================================================

rem ====== REQUIRED PATHS (ABSOLUTE) ===========================================
set "COMFYUI_ROOT=B:\ComfyUI"
set "PYTHON_EXE=B:\ComfyUI\venv\Scripts\python.exe"
set "COMFYUI_MAIN=B:\ComfyUI\main.py"

rem ====== GPU MATCHING =========================================================
rem Token used to find the RTX 5080 in nvidia-smi output.
set "GPU_NAME_TOKEN=5080"

rem OPTIONAL OVERRIDE:
rem If auto-detection fails or you have multiple "5080" matches,
rem set the exact nvidia-smi GPU index here (e.g., 0, 1, 2...).
rem Set to AUTO to auto-detect.
set "GPU_INDEX_OVERRIDE=AUTO"

rem ====== STRICT PYTHON ISOLATION (LOCAL ONLY) =================================
rem Prevent user-site packages from leaking in.
set "PYTHONNOUSERSITE=1"

rem ====== PATH VALIDATION ======================================================
if not exist "%PYTHON_EXE%" (
  echo [FATAL] Required Python not found: "%PYTHON_EXE%"
  exit /b 2
)
if not exist "%COMFYUI_MAIN%" (
  echo [FATAL] ComfyUI entry point not found: "%COMFYUI_MAIN%"
  exit /b 2
)
if not exist "%COMFYUI_ROOT%" (
  echo [FATAL] ComfyUI root not found: "%COMFYUI_ROOT%"
  exit /b 2
)

cd /d "%COMFYUI_ROOT%" || (
  echo [FATAL] Failed to cd into: "%COMFYUI_ROOT%"
  exit /b 2
)

rem ====== LOCATE NVIDIA-SMI ===================================================
set "NVSMI="
for /f "usebackq delims=" %%I in (`where nvidia-smi 2^>nul`) do (
  set "NVSMI=%%I"
  goto :_found_nvsmi
)

echo [FATAL] nvidia-smi not found in PATH.
echo         Install/repair NVIDIA drivers OR open a shell where nvidia-smi is available.
exit /b 3

:_found_nvsmi

rem ====== BASIC DRIVER CHECK ==================================================
"%NVSMI%" 1>nul 2>nul
if errorlevel 1 (
  echo [FATAL] nvidia-smi execution failed. Driver stack may not be healthy.
  exit /b 3
)

rem ====== DETERMINE RTX 5080 INDEX ============================================
set "RTX5080_INDEX="

if /i not "%GPU_INDEX_OVERRIDE%"=="AUTO" (
  set "RTX5080_INDEX=%GPU_INDEX_OVERRIDE%"
  echo [WARN] Using GPU_INDEX_OVERRIDE=%RTX5080_INDEX%
  goto :_have_rtx5080_index
)

call :_autodetect_rtx5080_index
if not errorlevel 1 goto :_have_rtx5080_index

echo [WARN] Auto-detect failed; attempting VERIFIED fallback to GPU 0...
"%NVSMI%" -L | findstr /i "GPU 0" | findstr /i "%GPU_NAME_TOKEN%" >nul
if errorlevel 1 (
  echo [FATAL] Fallback refused: GPU 0 did not match token "%GPU_NAME_TOKEN%".
  echo         Run the TEST launcher for details, then set GPU_INDEX_OVERRIDE explicitly.
  exit /b 4
)
set "RTX5080_INDEX=0"
echo [OK] Verified fallback: GPU 0 matches token "%GPU_NAME_TOKEN%".

:_have_rtx5080_index

if not defined RTX5080_INDEX (
  echo [FATAL] Could not determine RTX 5080 index.
  echo         Run the TEST launcher for a full diagnostic and then set GPU_INDEX_OVERRIDE.
  exit /b 4
)

echo [OK] Selected RTX 5080 NVIDIA index: %RTX5080_INDEX%

rem ====== VERIFY PyTorch CUDA WORKS (UNDER RESTRICTION) ========================
rem Important: set CUDA_VISIBLE_DEVICES BEFORE importing torch.
set "CUDA_VISIBLE_DEVICES=%RTX5080_INDEX%"

"%PYTHON_EXE%" -c "import os,sys; code='''\nimport os,sys\nimport torch\nprint(\"Python exe:\", sys.executable)\nprint(\"Torch:\", torch.__version__)\nprint(\"CUDA_VISIBLE_DEVICES:\", os.environ.get('CUDA_VISIBLE_DEVICES'))\nprint(\"torch.cuda.is_available():\", torch.cuda.is_available())\nif not torch.cuda.is_available():\n    raise SystemExit(\"FATAL: torch reports CUDA unavailable. Fix drivers/torch build.\")\ncount=torch.cuda.device_count()\nprint(\"torch.cuda.device_count():\", count)\nif count != 1:\n    raise SystemExit(f\"FATAL: expected exactly 1 visible GPU, got {count}.\")\nname=torch.cuda.get_device_name(0)\nprint(\"Visible cuda:0 name:\", name)\nif '5080' not in name.lower():\n    raise SystemExit(\"FATAL: visible device does not look like RTX 5080. Fix index override/token.\")\nprint(\"OK: Restriction maps to RTX 5080. Launching ComfyUI...\")\n''' ; exec(code)" || exit /b 6

rem ====== LAUNCH COMFYUI =======================================================
echo.
echo ==== STARTING COMFYUI (RTX 5080 ONLY) =====================================
echo Command:
echo   "%PYTHON_EXE%" "%COMFYUI_MAIN%"
echo.

"%PYTHON_EXE%" "%COMFYUI_MAIN%"
set "EXITCODE=%ERRORLEVEL%"

echo.
echo ==== COMFYUI EXITED =======================================================
echo Exit code: %EXITCODE%
echo.
exit /b %EXITCODE%

rem --------------------------------------------------------------------------
rem Subroutine: auto-detect RTX 5080 index using nvidia-smi output.
rem Sets RTX5080_INDEX on success.
rem Returns errorlevel 0 on success, non-zero on failure.
rem --------------------------------------------------------------------------
:_autodetect_rtx5080_index
set "RTX5080_INDEX="
set "MATCHED_INDEX="
set "MULTI_MATCH="

for /f "tokens=1,2 delims=," %%A in ('%NVSMI% --query-gpu=index,name --format=csv,noheader') do (
  echo %%B | findstr /i "%GPU_NAME_TOKEN%" >nul
  if not errorlevel 1 (
    if defined MATCHED_INDEX (
      set "MULTI_MATCH=1"
    ) else (
      set "MATCHED_INDEX=%%A"
    )
  )
)

if defined MULTI_MATCH exit /b 1
if not defined MATCHED_INDEX exit /b 1

set "RTX5080_INDEX=%MATCHED_INDEX%"
exit /b 0