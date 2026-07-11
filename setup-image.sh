#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Vast.ai -> ComfyUI image setup for FINAL 4 PICS - LEXI
# No secrets are stored in this file. HF_TOKEN must be supplied
# as a Vast.ai account-level environment variable.
# ============================================================

COMFY="/workspace/ComfyUI"
NODES="$COMFY/custom_nodes"
MODELS="$COMFY/models"
WORKFLOWS="$COMFY/user/default/workflows"
LOG="/workspace/setup-image.log"
READY="/workspace/SETUP_IMAGE_READY"
HF_HOME_DIR="/workspace/.hf-setup-cache"
AUTHOR_STAGE="/workspace/.author-data-stage"
PERSONAL_STAGE="/workspace/.personal-data-stage"

AUTHOR_REPO="jancikola/COMFYUI-DATA"
AUTHOR_REPO_TYPE="model"
PERSONAL_REPO="OxidELareN/comfyui-lexi"
PERSONAL_REPO_TYPE="dataset"
PYTHON="/venv/main/bin/python"

exec > >(tee -a "$LOG") 2>&1

on_error() {
    local exit_code=$?
    echo
    echo "============================================================"
    echo "SETUP FAILED (exit code: $exit_code)"
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

clone_node() {
    local repo="$1"
    local folder="$2"
    local ref="${3:-}"
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

    if [[ -s "$target/requirements.txt" ]]; then
        "$PYTHON" -m pip install --disable-pip-version-check -r "$target/requirements.txt"
    fi

    if [[ -f "$target/install.py" ]]; then
        COMFYUI_PATH="$COMFY" \
        COMFYUI_MODEL_PATH="$MODELS" \
        "$PYTHON" "$target/install.py"
    fi
}

download_hf_file() {
    local repo_id="$1"
    local repo_type="$2"
    local filename="$3"
    local destination="$4"
    local min_bytes="$5"
    local temp_dir

    temp_dir=$(mktemp -d /workspace/.hf-one-file-XXXXXX)
    mkdir -p "$(dirname "$destination")"

    REPO_ID="$repo_id" \
    REPO_TYPE="$repo_type" \
    FILENAME="$filename" \
    TEMP_DIR="$temp_dir" \
    DESTINATION="$destination" \
    "$PYTHON" - <<'PY'
import os
import shutil
from pathlib import Path
from huggingface_hub import hf_hub_download

repo_id = os.environ["REPO_ID"]
repo_type = os.environ["REPO_TYPE"]
filename = os.environ["FILENAME"]
temp_dir = Path(os.environ["TEMP_DIR"])
destination = Path(os.environ["DESTINATION"])

path = Path(hf_hub_download(
    repo_id=repo_id,
    repo_type=repo_type,
    filename=filename,
    token=os.environ["HF_TOKEN"],
    local_dir=temp_dir,
))

destination.parent.mkdir(parents=True, exist_ok=True)
shutil.move(str(path), str(destination))
print(f"Installed: {destination}")
PY

    require_file_min_size "$destination" "$min_bytes"
    rm -rf "$temp_dir"
    rm -rf "$HF_HOME_DIR/hub" "$HF_HOME_DIR/xet" 2>/dev/null || true
}

step "0. Initial checks"
rm -f "$READY"
: > "$LOG"

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

show_disk

step "1. Stop ComfyUI while files and dependencies are changed"
supervisorctl stop comfyui 2>/dev/null || true
pkill -f '/venv/main/bin/python main.py' 2>/dev/null || true
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

step "3. Install download utilities"
"$PYTHON" -m pip install --upgrade huggingface_hub hf_xet

step "4. Install required custom nodes"
# Two known-good commits captured from the working instance:
clone_node "https://github.com/M1kep/ComfyLiterals.git" \
           "ComfyLiterals" \
           "bdddb08ca82d90d75d97b1d437a652e0284a32ac"

clone_node "https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git" \
           "ComfyUI_JPS-Nodes" \
           "0e2a9aca02b17dde91577bfe4b65861df622dcaf"

# These are installed from their maintained upstream repositories.
clone_node "https://github.com/cubiq/ComfyUI_essentials.git" \
           "ComfyUI_essentials"

clone_node "https://github.com/rgthree/rgthree-comfy.git" \
           "rgthree-comfy"

clone_node "https://github.com/chrisgoringe/cg-use-everywhere.git" \
           "cg-use-everywhere"

clone_node "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git" \
           "ComfyUI-Impact-Pack"

clone_node "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git" \
           "ComfyUI-Impact-Subpack"

step "5. Download only the required files from the author's repository"
AUTHOR_STAGE="$AUTHOR_STAGE" "$PYTHON" - <<'PY'
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

if ! install_from_stage_or_existing \
    "sam_vit_b_01ec64.pth" \
    "$MODELS/sams/sam_vit_b_01ec64.pth" \
    300000000
then
    echo "SAM checkpoint not found in author repository; downloading official checkpoint."
    wget -O "$MODELS/sams/sam_vit_b_01ec64.pth" \
        "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth"

    require_file_min_size \
        "$MODELS/sams/sam_vit_b_01ec64.pth" \
        300000000
fi

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
WORKFLOW_PATH="$WORKFLOWS/FINAL 4 PICS - LEXI.json" "$PYTHON" - <<'PY'
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

step "9. Clean temporary caches"
rm -rf \
    "$AUTHOR_STAGE" \
    "$PERSONAL_STAGE" \
    "$HF_HOME_DIR" \
    /root/.cache/pip

find "$COMFY" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

step "10. Start ComfyUI"
supervisorctl restart comfyui || supervisorctl start comfyui || true

step "11. Final status"
{
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