@echo off
setlocal EnableExtensions

rem ============================================================================
rem ComfyUI RTX 5080 SAFE PREFLIGHT (TEST MODE)
rem ============================================================================
rem Goal:
rem   - Validate NVIDIA driver visibility (nvidia-smi)
rem   - Validate that PyTorch in the REQUIRED venv detects CUDA
rem   - Verify the selected NVIDIA GPU index maps to an RTX 5080
rem   - Verify that CUDA_VISIBLE_DEVICES will restrict visibility to that GPU
rem   - EXIT WITHOUT LAUNCHING ComfyUI (safe verification)
rem
rem Constraints honored:
rem   - Uses ONLY explicit absolute paths
rem   - Uses ONLY B:\ComfyUI\venv\Scripts\python.exe (no system Python)
rem   - Does NOT modify system-wide environment variables (uses setlocal)
rem   - Does NOT install packages, does NOT change ComfyUI source
rem ============================================================================

rem ====== REQUIRED PATHS (ABSOLUTE; DO NOT CHANGE TO RELATIVE) =================
set "COMFYUI_ROOT=B:\ComfyUI"
set "PYTHON_EXE=B:\ComfyUI\venv\Scripts\python.exe"
set "COMFYUI_MAIN=B:\ComfyUI\main.py"

rem ====== GPU IDENTIFICATION POLICY ===========================================
rem We MUST NOT assume GPU ordering. We will:
rem   1) Use nvidia-smi to enumerate GPUs and find the index for an RTX 5080
rem   2) Use that index as CUDA_VISIBLE_DEVICES
rem   3) Confirm in PyTorch that the visible device is RTX 5080
rem
rem Matching token used to locate the GPU in nvidia-smi output.
rem Keep this broad enough to match typical names:
rem   "NVIDIA GeForce RTX 5080" / "GeForce RTX 5080" / similar.
set "GPU_NAME_TOKEN=5080"

rem OPTIONAL OVERRIDE:
rem If you already KNOW the correct nvidia-smi index, you may set it here.
rem Set to AUTO to auto-detect.
set "GPU_INDEX_OVERRIDE=AUTO"

rem ====== HARD FAIL FAST IF REQUIRED FILES ARE MISSING =========================
if not exist "%PYTHON_EXE%" (
  echo [FATAL] Required Python not found: "%PYTHON_EXE%"
  echo         This launcher will not use system Python.
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
echo         Safe manual check: run `where nvidia-smi` and ensure it resolves.
exit /b 3

:_found_nvsmi
echo [OK] nvidia-smi found at: "%NVSMI%"

rem ====== DRIVER VISIBILITY CHECK =============================================
echo.
echo ==== NVIDIA DRIVER CHECK (nvidia-smi) ====================================
"%NVSMI%" 1>nul 2>nul
if errorlevel 1 (
  echo [FATAL] nvidia-smi execution failed. Driver stack may not be healthy.
  exit /b 3
)

echo -- GPU list (nvidia-smi -L)
"%NVSMI%" -L

echo.
echo -- Detailed GPU identity (index,name,uuid)
"%NVSMI%" --query-gpu=index,name,uuid --format=csv,noheader

rem ====== SELECT RTX 5080 INDEX (NO GUESSING) =================================
set "RTX5080_INDEX="

if /i not "%GPU_INDEX_OVERRIDE%"=="AUTO" (
  set "RTX5080_INDEX=%GPU_INDEX_OVERRIDE%"
  echo.
  echo [WARN] Using GPU_INDEX_OVERRIDE=%RTX5080_INDEX% ^(you asserted this is RTX 5080^)
  goto :_have_rtx5080_index
)

echo.
echo ==== AUTO-DETECT RTX 5080 INDEX =========================================
call :_autodetect_rtx5080_index
if not errorlevel 1 goto :_have_rtx5080_index

echo.
echo [WARN] Auto-detect failed; attempting VERIFIED fallback to GPU 0...
"%NVSMI%" -L | findstr /i "GPU 0" | findstr /i "%GPU_NAME_TOKEN%" >nul
if errorlevel 1 (
  echo [FATAL] Fallback refused: GPU 0 did not match token "%GPU_NAME_TOKEN%".
  echo         Set GPU_INDEX_OVERRIDE to the correct nvidia-smi index and re-run.
  exit /b 4
)

set "RTX5080_INDEX=0"
echo [OK] Verified fallback: GPU 0 matches token "%GPU_NAME_TOKEN%".

:_have_rtx5080_index

if not defined RTX5080_INDEX (
  echo [FATAL] Could not determine RTX 5080 index.
  echo         Fix the token/override and re-run.
  exit /b 4
)

echo.
echo [OK] Selected RTX 5080 NVIDIA index: %RTX5080_INDEX%

rem ====== PYTORCH PREFLIGHT (ALL GPUs VISIBLE) ================================
rem Unset CUDA_VISIBLE_DEVICES so we can see what PyTorch sees normally.
set "CUDA_VISIBLE_DEVICES="

echo.
echo ==== PYTORCH CHECK (UNRESTRICTED VISIBILITY) ==============================
"%PYTHON_EXE%" -c "import os,sys; code='''\nimport os,sys\nprint(\"Python exe:\", sys.executable)\ntry:\n    import torch\nexcept Exception as e:\n    print(\"FATAL: failed to import torch:\", repr(e))\n    raise\nprint(\"Torch:\", getattr(torch,'__version__','?'))\nprint(\"torch.version.cuda:\", getattr(getattr(torch,'version',None),'cuda',None))\nprint(\"CUDA_VISIBLE_DEVICES:\", os.environ.get('CUDA_VISIBLE_DEVICES'))\nprint(\"torch.cuda.is_available():\", torch.cuda.is_available())\nif not torch.cuda.is_available():\n    raise SystemExit(\"FATAL: torch reports CUDA unavailable. Check drivers + torch build.\")\ncount=torch.cuda.device_count()\nprint(\"torch.cuda.device_count():\", count)\nfor i in range(count):\n    print(f\"  cuda:{i} name: {torch.cuda.get_device_name(i)}\")\n''' ; exec(code)" || exit /b 5

rem ====== PYTORCH PREFLIGHT (RESTRICTED TO RTX 5080) ===========================
echo.
echo ==== PYTORCH CHECK (CUDA_VISIBLE_DEVICES=%RTX5080_INDEX%) =================
set "CUDA_VISIBLE_DEVICES=%RTX5080_INDEX%"

"%PYTHON_EXE%" -c "import os,sys; code='''\nimport os,sys\nprint(\"Python exe:\", sys.executable)\nimport torch\nprint(\"Torch:\", torch.__version__)\nprint(\"CUDA_VISIBLE_DEVICES:\", os.environ.get('CUDA_VISIBLE_DEVICES'))\nprint(\"torch.cuda.is_available():\", torch.cuda.is_available())\nif not torch.cuda.is_available():\n    raise SystemExit(\"FATAL: CUDA not available under restriction (unexpected).\")\ncount=torch.cuda.device_count()\nprint(\"torch.cuda.device_count():\", count)\nif count != 1:\n    raise SystemExit(f\"FATAL: expected exactly 1 visible GPU, got {count}.\")\nname=torch.cuda.get_device_name(0)\nprint(\"Visible cuda:0 name:\", name)\nif '5080' not in name.lower():\n    raise SystemExit(\"FATAL: visible device does not look like RTX 5080. Fix index override/token.\")\nprint(\"OK: Restriction maps to RTX 5080.\")\n''' ; exec(code)" || exit /b 6

echo.
echo ============================================================================
echo [PASS] Preflight succeeded. This TEST launcher will NOT start ComfyUI.
echo        Next: run the PRODUCTION launcher once you are satisfied.
echo ============================================================================
echo.
exit /b 0

rem --------------------------------------------------------------------------
rem Subroutine: auto-detect RTX 5080 index using nvidia-smi output.
rem Sets RTX5080_INDEX on success.
rem Returns errorlevel 0 on success, non-zero on failure.
rem --------------------------------------------------------------------------
:_autodetect_rtx5080_index
set "RTX5080_INDEX="
set "MATCHED_INDEX="
set "MULTI_MATCH="

rem Parse: "GPU 0: NVIDIA GeForce RTX 5080 (UUID: ...)"
rem Parse CSV query output: "0, NVIDIA GeForce RTX 5080"
rem NOTE: Use %NVSMI% unquoted inside FOR /F to avoid nested-quote parsing issues.
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

if defined MULTI_MATCH (
  echo [FATAL] Multiple GPUs matched token "%GPU_NAME_TOKEN%".
  echo         Set GPU_INDEX_OVERRIDE to the correct nvidia-smi index.
  exit /b 1
)

if not defined MATCHED_INDEX (
  exit /b 1
)

set "RTX5080_INDEX=%MATCHED_INDEX%"
exit /b 0
