#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Vast.ai -> ComfyUI image setup for FINAL 4 PICS - LEXI
# Version: 2.0.0
#
# HF_TOKEN must be supplied as a Vast.ai account-level variable.
# This script is safe to retry: heavy provisioning is skipped once
# all files and custom nodes have already been prepared.
# ============================================================

SCRIPT_VERSION="2.0.0"
COMFY="/workspace/ComfyUI"
NODES="$COMFY/custom_nodes"
MODELS="$COMFY/models"
WORKFLOWS="$COMFY/user/default/workflows"
LOG="/workspace/setup-image.log"
READY="/workspace/SETUP_IMAGE_READY"
FILES_READY="/workspace/SETUP_IMAGE_FILES_READY"
LOCK="/workspace/.setup-image.lock"
HF_HOME_DIR="/workspace/.hf-setup-cache"
AUTHOR_STAGE="/workspace/.author-data-stage"
PERSONAL_STAGE="/workspace/.personal-data-stage"
CONSTRAINTS="/workspace/.comfy-pip-constraints.txt"
COMFY_PORT="${OPEN_BUTTON_PORT:-18188}"

AUTHOR_REPO="jancikola/COMFYUI-DATA"
PERSONAL_REPO="OxidELareN/comfyui-lexi"
PERSONAL_REPO_TYPE="dataset"

# Use exactly the Python environment in which ComfyUI runs.
if [[ -x /venv/main/bin/python ]]; then
    PYTHON_BIN="/venv/main/bin/python"
else
    PYTHON_BIN="$(command -v python)"
fi

mkdir -p /workspace

# Prevent concurrent duplicate provisioning runs.
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "Another setup-image.sh process is already running; exiting safely."
    exit 0
fi

# Append logs; never truncate a log that may be watched with tail -f.
exec > >(tee -a "$LOG") 2>&1

echo
echo "============================================================"
echo "SETUP RUN STARTED"
echo "Version: $SCRIPT_VERSION"
echo "Time: $(date --iso-8601=seconds)"
echo "Python: $PYTHON_BIN"
echo "ComfyUI port: $COMFY_PORT"
echo "============================================================"

on_error() {
    local exit_code=$?
    trap - ERR
    echo
    echo "============================================================"
    echo "SETUP FAILED (exit code: $exit_code)"
    echo "Files-ready marker: $FILES_READY"
    echo "Final-ready marker: $READY"
    echo "Log: $LOG"
    echo "============================================================"
    df -h /workspace / 2>/dev/null || true
    rm -f "$READY"
    exit "$exit_code"
}
trap on_error ERR

step() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

show_disk() {
    df -h /workspace / 2>/dev/null || true
    du -sh "$COMFY" 2>/dev/null || true
}

require_file_min_size() {
    local path="$1"
    local min_bytes="$2"
    if [[ ! -f "$path" ]]; then
        echo "ERROR: required file is missing: $path"
        return 1
    fi
    local size
    size=$(stat -c '%s' "$path")
    if (( size < min_bytes )); then
        echo "ERROR: file is too small: $path ($size bytes; expected >= $min_bytes)"
        return 1
    fi
    echo "OK: $path ($size bytes)"
}

install_from_stage_or_existing() {
    local basename="$1"
    local destination="$2"
    local min_bytes="$3"

    mkdir -p "$(dirname "$destination")"

    if [[ -f "$destination" ]] && [[ $(stat -c '%s' "$destination") -ge $min_bytes ]]; then
        echo "Already present: $destination"
        return 0
    fi

    local source
    source=$(find "$AUTHOR_STAGE" -type f -name "$basename" -print -quit 2>/dev/null || true)
    if [[ -z "$source" ]]; then
        echo "ERROR: $basename was not found in $AUTHOR_REPO and is not already installed."
        return 1
    fi

    install -m 0644 "$source" "$destination"
    require_file_min_size "$destination" "$min_bytes"
}

build_pip_constraints() {
    "$PYTHON_BIN" - <<'PY' > "$CONSTRAINTS"
from importlib.metadata import PackageNotFoundError, version

# Never let a custom-node requirement replace the CUDA/PyTorch stack
# supplied by the tested Vast.ai ComfyUI image.
for package in ("torch", "torchvision", "torchaudio", "triton"):
    try:
        print(f"{package}=={version(package)}")
    except PackageNotFoundError:
        pass
PY
    echo "Protected package constraints:"
    cat "$CONSTRAINTS"
}

install_requirements() {
    local target="$1"
    local mode="${2:-normal}"
    local requirements="$target/requirements.txt"
    local effective_requirements="$requirements"

    [[ -s "$requirements" ]] || return 0

    if [[ "$mode" == "without-sam2" ]]; then
        effective_requirements=$(mktemp /tmp/requirements-no-sam2-XXXXXX.txt)
        grep -Eiv 'facebookresearch/sam2|git\+.*sam2' "$requirements" > "$effective_requirements" || true
        echo "Skipping optional SAM2 dependency; this workflow uses sam_vit_b_01ec64.pth, not SAM2."
    fi

    "$PYTHON_BIN" -m pip install \
        --no-cache-dir \
        --disable-pip-version-check \
        --upgrade-strategy only-if-needed \
        -c "$CONSTRAINTS" \
        -r "$effective_requirements"

    if [[ "$effective_requirements" != "$requirements" ]]; then
        rm -f "$effective_requirements"
    fi
}

clone_node() {
    local repo="$1"
    local folder="$2"
    local ref="${3:-}"
    local requirements_mode="${4:-normal}"
    local run_install_py="${5:-no}"
    local target="$NODES/$folder"

    echo
    echo "Installing custom node: $folder"
    rm -rf "$target"
    git clone --filter=blob:none "$repo" "$target"

    if [[ -n "$ref" ]]; then
        git -C "$target" checkout --detach "$ref"
    fi

    echo "Source: $(git -C "$target" remote get-url origin)"
    echo "Commit: $(git -C "$target" rev-parse HEAD)"

    install_requirements "$target" "$requirements_mode"

    if [[ "$run_install_py" == "yes" && -f "$target/install.py" ]]; then
        # Impact Pack documents this marker to suppress automatic model downloads.
        touch "$NODES/skip_download_model"
        COMFYUI_PATH="$COMFY" \
        COMFYUI_MODEL_PATH="$MODELS" \
        "$PYTHON_BIN" "$target/install.py"
        rm -f "$NODES/skip_download_model"
    fi
}

download_hf_file() {
    local repo_id="$1"
    local repo_type="$2"
    local filename="$3"
    local destination="$4"
    local min_bytes="$5"
    local temp_dir

    if [[ -f "$destination" ]] && [[ $(stat -c '%s' "$destination") -ge $min_bytes ]]; then
        echo "Already present: $destination"
        return 0
    fi

    temp_dir=$(mktemp -d /workspace/.hf-one-file-XXXXXX)
    mkdir -p "$(dirname "$destination")"

    REPO_ID="$repo_id" \
    REPO_TYPE="$repo_type" \
    FILENAME="$filename" \
    TEMP_DIR="$temp_dir" \
    DESTINATION="$destination" \
    "$PYTHON_BIN" - <<'PY'
import os
import shutil
from pathlib import Path
from huggingface_hub import hf_hub_download

path = Path(hf_hub_download(
    repo_id=os.environ["REPO_ID"],
    repo_type=os.environ["REPO_TYPE"],
    filename=os.environ["FILENAME"],
    token=os.environ["HF_TOKEN"],
    local_dir=Path(os.environ["TEMP_DIR"]),
))

destination = Path(os.environ["DESTINATION"])
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.move(str(path), str(destination))
print(f"Installed: {destination}")
PY

    require_file_min_size "$destination" "$min_bytes"
    rm -rf "$temp_dir"
    rm -rf "$HF_HOME_DIR/hub" "$HF_HOME_DIR/xet" 2>/dev/null || true
}

start_and_wait_for_comfyui() {
    step "Start ComfyUI and wait for its API"

    if curl -fsS --max-time 5 "http://127.0.0.1:${COMFY_PORT}/object_info" >/dev/null 2>&1; then
        echo "ComfyUI API is already reachable on port ${COMFY_PORT}."
        return 0
    fi

    supervisorctl restart comfyui 2>/dev/null || supervisorctl start comfyui

    local healthy=0
    # Allow up to 12 minutes for the first startup after custom-node installation.
    for _ in $(seq 1 360); do
        if curl -fsS --max-time 5 "http://127.0.0.1:${COMFY_PORT}/object_info" >/dev/null 2>&1; then
            healthy=1
            break
        fi
        sleep 2
    done

    if (( healthy != 1 )); then
        echo "ERROR: ComfyUI did not become reachable on port ${COMFY_PORT}."
        supervisorctl status 2>/dev/null || true
        echo "--- comfyui stderr ---"
        supervisorctl tail comfyui stderr 2>/dev/null || true
        echo "--- comfyui stdout ---"
        supervisorctl tail comfyui stdout 2>/dev/null || true
        return 20
    fi

    echo "ComfyUI API is reachable on port ${COMFY_PORT}."
}

validate_loaded_nodes() {
    step "Validate required workflow nodes through ComfyUI API"

    COMFY_PORT="$COMFY_PORT" "$PYTHON_BIN" - <<'PY'
import json
import os
import urllib.request

url = f"http://127.0.0.1:{os.environ['COMFY_PORT']}/object_info"
with urllib.request.urlopen(url, timeout=30) as response:
    objects = json.load(response)

required = {
    "Float",
    "SimpleMath+",
    "UltralyticsDetectorProvider",
    "SAMLoader",
    "FaceDetailer",
    "FaceDetailerPipe",
    "ImpactSwitch",
    "ToDetailerPipeSDXL",
    "Power Lora Loader (rgthree)",
    "Text Prompt (JPS)",
}
missing = sorted(required.difference(objects))
if missing:
    raise SystemExit("ERROR: required nodes failed to load: " + ", ".join(missing))

print(f"Required workflow nodes loaded successfully ({len(required)} checked).")
PY
}

validate_mandatory_files() {
    require_file_min_size "$MODELS/checkpoints/intorealismUltra_v90.safetensors" 6000000000
    require_file_min_size "$MODELS/checkpoints/pornmasterZImage_turboV35Bf16.safetensors" 12000000000
    require_file_min_size "$MODELS/diffusion_models/z_image_turbo_bf16.safetensors" 12000000000
    require_file_min_size "$MODELS/text_encoders/qwen_3_4b.safetensors" 8000000000
    require_file_min_size "$MODELS/vae/ae.safetensors" 300000000
    require_file_min_size "$MODELS/loras/RealisticSnapshot-Zimage-Turbov5.safetensors" 150000000
    require_file_min_size "$MODELS/loras/leximodellora.safetensors" 170000000
    require_file_min_size "$MODELS/sams/sam_vit_b_01ec64.pth" 300000000
    require_file_min_size "$MODELS/ultralytics/bbox/face_yolov8m.pt" 40000000
    require_file_min_size "$MODELS/ultralytics/bbox/vagina-v4.2.pt" 40000000
    require_file_min_size "$WORKFLOWS/FINAL 4 PICS - LEXI.json" 10000
}

step "0. Initial checks"

if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "ERROR: HF_TOKEN is not available in the container."
    echo "Store it in Vast.ai Account -> Environment Variables as HF_TOKEN."
    exit 10
fi

for _ in $(seq 1 120); do
    [[ -d "$COMFY" ]] && break
    sleep 2
done

if [[ ! -d "$COMFY" ]]; then
    echo "ERROR: ComfyUI directory was not created: $COMFY"
    exit 11
fi

"$PYTHON_BIN" --version
"$PYTHON_BIN" -m pip --version

# A fully completed setup is a fast no-op apart from ensuring the service is alive.
if [[ -f "$READY" ]]; then
    echo "Setup is already complete: $READY"
    start_and_wait_for_comfyui
    validate_loaded_nodes
    exit 0
fi

# A retry after a health-check timeout must not reinstall 40+ GiB of data.
if [[ -f "$FILES_READY" ]]; then
    echo "All files were already provisioned in an earlier run; skipping heavy setup."
    validate_mandatory_files
    start_and_wait_for_comfyui
    validate_loaded_nodes
    {
        echo "version=$SCRIPT_VERSION"
        echo "completed_at=$(date --iso-8601=seconds)"
        echo "workflow=$WORKFLOWS/FINAL 4 PICS - LEXI.json"
        echo "lora=$MODELS/loras/leximodellora.safetensors"
    } > "$READY"
    show_disk
    echo "IMAGE SETUP COMPLETED SUCCESSFULLY (retry path)"
    exit 0
fi

available_kb=$(df --output=avail -k /workspace | tail -1 | tr -d ' ')
if (( available_kb < 45 * 1024 * 1024 )); then
    echo "ERROR: less than 45 GiB is available in /workspace before a fresh setup."
    show_disk
    exit 12
fi

show_disk

step "1. Stop ComfyUI while files and dependencies are changed"
supervisorctl stop comfyui 2>/dev/null || true
pkill -f '/venv/main/bin/python.*main.py' 2>/dev/null || true
sleep 2

step "2. Create required directories"
mkdir -p \
    "$NODES" \
    "$MODELS/checkpoints" \
    "$MODELS/diffusion_models" \
    "$MODELS/text_encoders" \
    "$MODELS/vae" \
    "$MODELS/loras" \
    "$MODELS/sams" \
    "$MODELS/ultralytics/bbox" \
    "$WORKFLOWS" \
    "$HF_HOME_DIR"

rm -rf "$AUTHOR_STAGE" "$PERSONAL_STAGE"
mkdir -p "$AUTHOR_STAGE" "$PERSONAL_STAGE"

export HF_HOME="$HF_HOME_DIR"
export HF_HUB_CACHE="$HF_HOME_DIR/hub"
export HF_XET_CACHE="$HF_HOME_DIR/xet"
export HF_XET_HIGH_PERFORMANCE=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_NO_CACHE_DIR=1

step "3. Prepare the ComfyUI Python environment"
"$PYTHON_BIN" -m pip install \
    --no-cache-dir \
    --disable-pip-version-check \
    --upgrade-strategy only-if-needed \
    huggingface_hub hf_xet

build_pip_constraints

step "4. Install required custom nodes in the ComfyUI Python environment"
clone_node "https://github.com/M1kep/ComfyLiterals.git" \
           "ComfyLiterals" \
           "bdddb08ca82d90d75d97b1d437a652e0284a32ac"

clone_node "https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git" \
           "ComfyUI_JPS-Nodes" \
           "0e2a9aca02b17dde91577bfe4b65861df622dcaf"

clone_node "https://github.com/cubiq/ComfyUI_essentials.git" \
           "ComfyUI_essentials" \
           "9d9f4bedfc9f0321c19faf71855e228c93bd0dc9"

clone_node "https://github.com/rgthree/rgthree-comfy.git" \
           "rgthree-comfy" \
           "27b4f4cdcf3b127c29d5d8135ac1536ecbd4c383"

clone_node "https://github.com/chrisgoringe/cg-use-everywhere.git" \
           "cg-use-everywhere" \
           "632ed7bb51bb18ceb03ccaefe1f34be8bd416500"

clone_node "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git" \
           "ComfyUI-Impact-Pack" \
           "429d0159ad429e64d2b3916e6e7be9c22d025c3c" \
           "without-sam2" \
           "yes"

clone_node "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git" \
           "ComfyUI-Impact-Subpack" \
           "74db20c95eca152a6d686c914edc0ef4e4762cb8" \
           "normal" \
           "yes"

show_disk

step "5. Download only the required files from the author's repository"
AUTHOR_STAGE="$AUTHOR_STAGE" "$PYTHON_BIN" - <<'PY'
import os
from huggingface_hub import snapshot_download

names = [
    "intorealismUltra_v90.safetensors",
    "pornmasterZImage_turboV35Bf16.safetensors",
    "RealisticSnapshot-Zimage-Turbov5.safetensors",
    "sam_vit_b_01ec64.pth",
    "face_yolov8m.pt",
    "vagina-v4.2.pt",
]
patterns = []
for name in names:
    patterns.extend([name, f"**/{name}"])

snapshot_download(
    repo_id="jancikola/COMFYUI-DATA",
    repo_type="model",
    local_dir=os.environ["AUTHOR_STAGE"],
    token=os.environ["HF_TOKEN"],
    allow_patterns=patterns,
)
PY

install_from_stage_or_existing \
    "intorealismUltra_v90.safetensors" \
    "$MODELS/checkpoints/intorealismUltra_v90.safetensors" \
    6000000000

install_from_stage_or_existing \
    "pornmasterZImage_turboV35Bf16.safetensors" \
    "$MODELS/checkpoints/pornmasterZImage_turboV35Bf16.safetensors" \
    12000000000

install_from_stage_or_existing \
    "RealisticSnapshot-Zimage-Turbov5.safetensors" \
    "$MODELS/loras/RealisticSnapshot-Zimage-Turbov5.safetensors" \
    150000000

install_from_stage_or_existing \
    "sam_vit_b_01ec64.pth" \
    "$MODELS/sams/sam_vit_b_01ec64.pth" \
    300000000

install_from_stage_or_existing \
    "face_yolov8m.pt" \
    "$MODELS/ultralytics/bbox/face_yolov8m.pt" \
    40000000

install_from_stage_or_existing \
    "vagina-v4.2.pt" \
    "$MODELS/ultralytics/bbox/vagina-v4.2.pt" \
    40000000

rm -rf "$AUTHOR_STAGE"
rm -rf "$HF_HOME_DIR/hub" "$HF_HOME_DIR/xet" 2>/dev/null || true
show_disk

step "6. Download the three Z-Image components one at a time"
download_hf_file \
    "Comfy-Org/z_image_turbo" \
    "model" \
    "split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
    "$MODELS/diffusion_models/z_image_turbo_bf16.safetensors" \
    12000000000
show_disk

download_hf_file \
    "Comfy-Org/z_image_turbo" \
    "model" \
    "split_files/vae/ae.safetensors" \
    "$MODELS/vae/ae.safetensors" \
    300000000
show_disk

download_hf_file \
    "Comfy-Org/z_image_turbo" \
    "model" \
    "split_files/text_encoders/qwen_3_4b.safetensors" \
    "$MODELS/text_encoders/qwen_3_4b.safetensors" \
    8000000000
show_disk

step "7. Download Lexi LoRA and Lexi workflow"
download_hf_file \
    "$PERSONAL_REPO" \
    "$PERSONAL_REPO_TYPE" \
    "loras/leximodellora.safetensors" \
    "$MODELS/loras/leximodellora.safetensors" \
    170000000

download_hf_file \
    "$PERSONAL_REPO" \
    "$PERSONAL_REPO_TYPE" \
    "workflows/FINAL 4 PICS - LEXI.json" \
    "$WORKFLOWS/FINAL 4 PICS - LEXI.json" \
    10000

step "8. Validate workflow and all mandatory files"
WORKFLOW_PATH="$WORKFLOWS/FINAL 4 PICS - LEXI.json" "$PYTHON_BIN" - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["WORKFLOW_PATH"])
with path.open("r", encoding="utf-8") as f:
    data = json.load(f)

serialized = json.dumps(data, ensure_ascii=False)
assert "leximodellora.safetensors" in serialized, "Lexi LoRA is not referenced by the workflow"
assert "Jasminelor80.safetensors" not in serialized, "Old Jasmine LoRA is still referenced"
assert isinstance(data.get("nodes"), list) and data["nodes"], "Workflow has no nodes"
print(f"Workflow OK: {path} ({len(data['nodes'])} nodes)")
PY

validate_mandatory_files

# This marker permits a safe lightweight retry if only the first UI startup times out.
{
    echo "version=$SCRIPT_VERSION"
    echo "prepared_at=$(date --iso-8601=seconds)"
} > "$FILES_READY"

step "9. Clean temporary caches"
rm -rf \
    "$AUTHOR_STAGE" \
    "$PERSONAL_STAGE" \
    "$HF_HOME_DIR" \
    /root/.cache/pip

find "$COMFY" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

start_and_wait_for_comfyui
validate_loaded_nodes

step "11. Final status"
{
    echo "version=$SCRIPT_VERSION"
    echo "completed_at=$(date --iso-8601=seconds)"
    echo "workflow=$WORKFLOWS/FINAL 4 PICS - LEXI.json"
    echo "lora=$MODELS/loras/leximodellora.safetensors"
} > "$READY"

show_disk

echo
echo "============================================================"
echo "IMAGE SETUP COMPLETED SUCCESSFULLY"
echo "Ready marker: $READY"
echo "Log: $LOG"
echo "============================================================"
