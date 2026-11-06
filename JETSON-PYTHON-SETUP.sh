#!/usr/bin/env bash
# JETSON-PYTHON-SETUP.sh
# Builds a shared, offline-capable Python AI stack for Jetson Orin: GPU builds
# of PyTorch, TensorFlow and ONNX Runtime, plus Keras, Transformers, LangChain
# (with Ollama) and the packages in jetson-python-requirements.txt.
#
# Everything lands under a prefix that every account can read:
#   <prefix>/wheelhouse   wheels for offline venv installs (/etc/pip.conf and
#                         /etc/uv/uv.toml point here)
#   <prefix>/cache        shared Hugging Face model cache
#   <prefix>/debs         apt packages (nvidia-jetpack etc.) for --offline units
#   <prefix>/redist       extra CUDA libraries the PyTorch wheels need
#   <prefix>/verify.py    stack check, runnable by any user
# Unless --wheelhouse-only is given, the stack is also installed into the
# system Python, so venvs made with --system-site-packages get it for free.
#
# Usage:
#   sudo ./JETSON-PYTHON-SETUP.sh [options]
#
# Options:
#   --prefix PATH        Shared install root      (default: /opt/tinkerlab/python)
#   --requirements FILE  General package list     (default: jetson-python-requirements.txt
#                        next to this script, or <prefix>/requirements-base.txt offline)
#   --index URL          Jetson PyPI index        (default: picked from JetPack version)
#   --no-tensorflow      Leave TensorFlow out
#   --wheelhouse-only    Build the wheelhouse but don't install into system Python
#   --offline            No downloads: install from an existing <prefix>, e.g. one
#                        copied from another unit with the same JetPack
#   --hf-model ID        Pre-cache a Hugging Face model (repeatable, online only)
#   --add-user USER      Add USER to the video/render groups for GPU and camera
#                        access (repeatable)
#   -h | --help          Show this help

set -euo pipefail

PREFIX="/opt/tinkerlab/python"
REQS=""
INDEX=""
WITH_TF=1
SYSTEM_INSTALL=1
OFFLINE=0
HF_MODELS=()
ADD_USERS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# nvidia-jetpack brings CUDA, cuDNN, TensorRT (with Python bindings), OpenCV
# and VPI; the rest is build tools and the GStreamer/V4L2 camera stack.
APT_PACKAGES=(
  nvidia-jetpack
  python3-pip python3-venv python3-dev build-essential pkg-config curl
  libopenblas-dev libjpeg-dev zlib1g-dev libhdf5-dev
  v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
  python3-gi gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0
)

# The jetson-ai-lab PyTorch wheels link against these, but JetPack doesn't
# ship them. Entries are "soname|path under CUDA_REDIST"; set per JetPack below.
CUDA_REDIST="https://developer.download.nvidia.com/compute"
CUDA_EXTRAS=()
CUDA_EXTRAS_DIR="/usr/local/lib/tinkerlab-cuda-extras"
LD_CONF="/etc/ld.so.conf.d/tinkerlab-cuda.conf"

PIP_CONF="/etc/pip.conf"
UV_CONF="/etc/uv/uv.toml"
PROFILE_SH="/etc/profile.d/tinkerlab-python.sh"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Online: install from the apt repos, keeping the .debs in <prefix>/debs.
# Offline: install from those .debs.
apt_install() {
  if [[ $OFFLINE -eq 0 ]]; then
    mkdir -p "$DEBS/partial"
    getent passwd _apt >/dev/null && chown _apt:root "$DEBS/partial"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      -o Dir::Cache::archives="$DEBS" -o APT::Keep-Downloaded-Packages=true "$@"
  elif compgen -G "$DEBS/*.deb" >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$DEBS"/*.deb
  fi
}

backup_unless_ours() {
  if [[ -f "$1" ]] && ! grep -q 'JETSON-PYTHON-SETUP' "$1"; then
    cp "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backed up existing $1"
  fi
}

usage() { awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)          PREFIX="${2%/}"; shift 2 ;;
    --requirements)    REQS="$(realpath "$2")"; shift 2 ;;
    --index)           INDEX="$2"; shift 2 ;;
    --no-tensorflow)   WITH_TF=0; shift ;;
    --wheelhouse-only) SYSTEM_INSTALL=0; shift ;;
    --offline)         OFFLINE=1; shift ;;
    --hf-model)        HF_MODELS+=("$2"); shift 2 ;;
    --add-user)        ADD_USERS+=("$2"); shift 2 ;;
    -h|--help)         usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ $OFFLINE -eq 0 || ${#HF_MODELS[@]} -eq 0 ]] || die "--hf-model needs internet; drop --offline."
for u in "${ADD_USERS[@]}"; do id "$u" >/dev/null 2>&1 || die "No such user: $u"; done

WH="$PREFIX/wheelhouse"
HF_CACHE="$PREFIX/cache/huggingface/hub"
REDIST="$PREFIX/redist"
DEBS="$PREFIX/debs"
GPU_REQS="$PREFIX/requirements-gpu.txt"
BASE_REQS="$PREFIX/requirements-base.txt"
CONSTRAINTS="$PREFIX/constraints.txt"
BUILD_INFO="$PREFIX/build-info"

# Keep the script's own pip calls away from the offline /etc/pip.conf it writes.
export PIP_CONFIG_FILE=/dev/null PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# --- Detect platform -------------------------------------------------------
[[ -f /etc/nv_tegra_release ]] || die "/etc/nv_tegra_release not found - is this a Jetson?"
L4T_MAJOR="$(head -n1 /etc/nv_tegra_release | sed -n 's/^# R\([0-9]\+\).*/\1/p')"
L4T_MINOR="$(head -n1 /etc/nv_tegra_release | sed -n 's/.*REVISION: \([0-9]\+\).*/\1/p')"
[[ -n "$L4T_MAJOR" ]] || die "Could not parse L4T version from /etc/nv_tegra_release"
PY_TAG="$(python3 -c 'import sys; print(f"cp{sys.version_info[0]}{sys.version_info[1]}")')"
log "Detected L4T R${L4T_MAJOR}.${L4T_MINOR:-?}, system Python ${PY_TAG}"

TF_SPEC=""
TF_URL=""
case "$L4T_MAJOR" in
  36)
    [[ "${L4T_MINOR:-0}" -ge 4 ]] || die "JetPack 6.0 (R36.${L4T_MINOR}) ships CUDA 12.2; the GPU wheels need JetPack 6.1+ (R36.4+). Re-flash with JetPack 6.2."
    [[ "$PY_TAG" == "cp310" ]] || die "JetPack 6 GPU wheels are built for the system Python 3.10, found $PY_TAG."
    DEFAULT_INDEX="https://pypi.jetson-ai-lab.io/jp6/cu126/+simple/"
    TF_SPEC="tensorflow==2.16.1+nv24.08"
    TF_URL="$CUDA_REDIST/redist/jp/v61/tensorflow/tensorflow-2.16.1%2Bnv24.08-cp310-cp310-linux_aarch64.whl"
    CUDA_EXTRAS=(
      "libcusparseLt.so.0|cusparselt/redist/libcusparse_lt/linux-aarch64/libcusparse_lt-linux-aarch64-0.7.1.0-archive.tar.xz"
      "libcudss.so.0|cudss/redist/libcudss/linux-aarch64/libcudss-linux-aarch64-0.7.1.4_cuda12-archive.tar.xz"
    )
    ;;
  3[89]|4[0-9])
    warn "JetPack 7 on Orin is best-effort: these wheels are built for the SBSA CUDA 13 stack and untested here."
    DEFAULT_INDEX="https://pypi.jetson-ai-lab.io/sbsa/cu130/+simple/"
    TF_SPEC="tensorflow"
    [[ $WITH_TF -eq 0 ]] || warn "NVIDIA publishes no GPU TensorFlow for JetPack 7; installing the CPU build."
    CUDA_EXTRAS=(
      "libcusparseLt.so.0|cusparselt/redist/libcusparse_lt/linux-sbsa/libcusparse_lt-linux-sbsa-0.8.1.1_cuda13-archive.tar.xz"
      "libcudss.so.0|cudss/redist/libcudss/linux-sbsa/libcudss-linux-sbsa-0.7.1.4_cuda13-archive.tar.xz"
    )
    ;;
  *) die "Unsupported L4T R${L4T_MAJOR}: needs JetPack 6.1+ (R36.4+)." ;;
esac
INDEX="${INDEX:-$DEFAULT_INDEX}"

BREAK_SYSTEM=()
if python3 -c 'import os, sys, sysconfig; sys.exit(not os.path.exists(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")))'; then
  BREAK_SYSTEM=(--break-system-packages)
fi

mkdir -p "$PREFIX"
if [[ $OFFLINE -eq 1 ]]; then
  [[ -d "$WH" && -f "$BASE_REQS" && -f "$CONSTRAINTS" ]] || die "--offline needs an existing wheelhouse in $PREFIX (copy it from a built unit)."
  if [[ -f "$BUILD_INFO" ]] && ! grep -qx "L4T_MAJOR=$L4T_MAJOR PY_TAG=$PY_TAG" "$BUILD_INFO"; then
    die "$PREFIX was built on a different JetPack/Python ($(cat "$BUILD_INFO")); rebuild it online."
  fi
else
  AVAIL_GB="$(df --output=avail -BG "$PREFIX" | tail -n1 | tr -dc '0-9')"
  [[ "$AVAIL_GB" -ge 25 ]] || warn "Only ${AVAIL_GB}G free under $PREFIX; JetPack components, wheelhouse and install need ~25G."
fi

# --- System packages -------------------------------------------------------
if [[ $OFFLINE -eq 0 ]]; then
  log "Installing JetPack components (CUDA, cuDNN, TensorRT, OpenCV), build tools and camera packages via apt"
  apt-get update -q
else
  log "Installing cached .debs from $DEBS"
fi
apt_install "${APT_PACKAGES[@]}"

# Older JetPack images can lack nvidia-opencv; Ubuntu's build also has GStreamer.
if ! python3 -c 'import cv2' 2>/dev/null; then
  log "JetPack's OpenCV isn't importable; installing Ubuntu's python3-opencv"
  apt_install python3-opencv
fi

python3 -c 'import ensurepip, venv' 2>/dev/null || die "python3-venv is missing; run online once, or copy $DEBS from a built unit."
python3 -c 'import cv2' 2>/dev/null || warn "OpenCV still isn't importable from the system Python."
python3 -c 'import tensorrt' 2>/dev/null || warn "TensorRT Python bindings still aren't importable (package python3-libnvinfer)."

# --- CUDA library path and extra libraries ---------------------------------
mkdir -p "$REDIST" "$CUDA_EXTRAS_DIR"
: > "$LD_CONF"
if [[ -d /usr/local/cuda/lib64 ]]; then echo "/usr/local/cuda/lib64" >> "$LD_CONF"; fi
rm -f /etc/ld.so.conf.d/tinkerlab-cuda-extras.conf
ldconfig
for entry in "${CUDA_EXTRAS[@]}"; do
  soname="${entry%%|*}"
  rel="${entry#*|}"
  tarball="$REDIST/$(basename "$rel")"
  dest="$CUDA_EXTRAS_DIR/$(basename "$rel" .tar.xz)"
  # Download even when present here, so --offline units that lack it get a copy.
  if [[ ! -f "$tarball" && $OFFLINE -eq 0 ]]; then
    log "Downloading $(basename "$rel")"
    curl -fL --retry 3 -o "$tarball.part" "$CUDA_REDIST/$rel"
    mv "$tarball.part" "$tarball"
  fi
  if [[ -d "$dest" ]]; then
    echo "$dest/lib" >> "$LD_CONF"
  elif ! grep -q "$soname" <<<"$(ldconfig -p)"; then
    [[ -f "$tarball" ]] || die "Missing $tarball - copy $REDIST from a built unit."
    mkdir -p "$dest"
    tar -xJf "$tarball" -C "$dest" --strip-components=1
    echo "$dest/lib" >> "$LD_CONF"
    log "Installed $soname under $dest"
  fi
done
ldconfig
grep -q 'libcublasLt\.so' <<<"$(ldconfig -p)" \
  || warn "libcublasLt isn't on the library path - PyTorch won't load. Check nvidia-jetpack installed and /usr/local/cuda/lib64 exists."

# --- Requirement files -----------------------------------------------------
{
  echo "# Generated by JETSON-PYTHON-SETUP.sh for L4T R${L4T_MAJOR} - GPU builds"
  echo "torch"
  echo "torchvision"
  echo "torchaudio"
  echo "onnxruntime-gpu"
  if [[ $WITH_TF -eq 1 ]]; then echo "$TF_SPEC"; fi
} > "$GPU_REQS"

if [[ $OFFLINE -eq 0 ]]; then
  REQS="${REQS:-$SCRIPT_DIR/jetson-python-requirements.txt}"
  [[ -f "$REQS" ]] || die "Requirements file not found: $REQS"
  [[ "$REQS" -ef "$BASE_REQS" ]] || cp "$REQS" "$BASE_REQS"
  # TensorFlow 2.16 and JetPack's apt OpenCV are both built against NumPy 1.x.
  echo "numpy<2" > "$CONSTRAINTS"
  [[ "$SCRIPT_PATH" -ef "$PREFIX/JETSON-PYTHON-SETUP.sh" ]] || cp "$SCRIPT_PATH" "$PREFIX/"
  echo "L4T_MAJOR=$L4T_MAJOR PY_TAG=$PY_TAG" > "$BUILD_INFO"
elif [[ -n "$REQS" ]]; then
  [[ "$REQS" -ef "$BASE_REQS" ]] || cp "$REQS" "$BASE_REQS"
fi

# --- Tool venv: a current pip, used to build and to install ----------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
python3 -m venv "$TMP_DIR/tool"
TOOL_PIP="$TMP_DIR/tool/bin/pip"
if [[ $OFFLINE -eq 0 ]]; then
  "$TOOL_PIP" install -q --upgrade --index-url https://pypi.org/simple pip
else
  "$TOOL_PIP" install -q --upgrade --no-index --find-links "$WH" pip
fi

# --- Build the wheelhouse --------------------------------------------------
if [[ $OFFLINE -eq 0 ]]; then
  NEW_WH="$WH.new"
  rm -rf "$NEW_WH"
  mkdir -p "$NEW_WH"
  if [[ $WITH_TF -eq 1 && -n "$TF_URL" ]]; then
    log "Downloading NVIDIA TensorFlow wheel"
    curl -fL --retry 3 -o "$NEW_WH/tensorflow-2.16.1+nv24.08-cp310-cp310-linux_aarch64.whl" "$TF_URL"
  fi

  log "Building wheelhouse from $INDEX (this takes a while)"
  "$TOOL_PIP" wheel --wheel-dir "$NEW_WH" --find-links "$NEW_WH" --index-url "$INDEX" \
    -r "$GPU_REQS" -r "$BASE_REQS" -c "$CONSTRAINTS" pip setuptools wheel uv \
    || die "Wheelhouse build failed. If the Jetson index is down, retry later or pass --index; if it's a version conflict, try --no-tensorflow."

  if [[ $L4T_MAJOR -eq 36 ]] && compgen -G "$NEW_WH/torch-*manylinux*" >/dev/null; then
    die "torch came from PyPI (CPU/SBSA build), not the Jetson index - check --index."
  fi

  rm -rf "$WH.old"
  [[ -d "$WH" ]] && mv "$WH" "$WH.old"
  mv "$NEW_WH" "$WH"
  rm -rf "$WH.old"
  log "Wheelhouse: $WH ($(ls "$WH" | wc -l) wheels, $(du -sh "$WH" | cut -f1))"
fi

# --- Install into the system Python ----------------------------------------
if [[ $SYSTEM_INSTALL -eq 1 ]]; then
  log "Installing the stack into the system Python"
  # --ignore-installed: apt-owned packages (e.g. blinker) can't be uninstalled by pip.
  "$TOOL_PIP" --python /usr/bin/python3 install --no-index --find-links "$WH" \
    --ignore-installed "${BREAK_SYSTEM[@]}" -r "$GPU_REQS" -r "$BASE_REQS" -c "$CONSTRAINTS"
fi

# uv for every account, even with --wheelhouse-only.
"$TOOL_PIP" --python /usr/bin/python3 install -q --no-index --find-links "$WH" \
  --ignore-installed "${BREAK_SYSTEM[@]}" uv
log "Installed $(uv --version)"

# --- Shared config for every account ---------------------------------------
backup_unless_ours "$PIP_CONF"
cat > "$PIP_CONF" <<EOF
# Generated by JETSON-PYTHON-SETUP.sh: installs come from the local wheelhouse only.
[global]
no-index = true
find-links = $WH
EOF

# uv reads this for every user and every shell, unlike profile.d.
mkdir -p "$(dirname "$UV_CONF")"
backup_unless_ours "$UV_CONF"
cat > "$UV_CONF" <<EOF
# Generated by JETSON-PYTHON-SETUP.sh: installs come from the local wheelhouse only,
# and venvs use the system Python the wheels are built for.
no-index = true
find-links = ["$WH"]
python-downloads = "never"
python-preference = "only-system"
EOF

cat > "$PROFILE_SH" <<EOF
# Generated by JETSON-PYTHON-SETUP.sh
case ":\$PATH:" in *:/usr/local/cuda/bin:*) ;; *) export PATH="/usr/local/cuda/bin:\$PATH" ;; esac
# Shared, read-only model cache; no network on the lab units.
export HF_HUB_CACHE="$HF_CACHE"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
# CPU and GPU share 8GB: stop TensorFlow reserving all of it up front.
export TF_FORCE_GPU_ALLOW_GROWTH=true
EOF
chmod 0644 "$PIP_CONF" "$UV_CONF" "$PROFILE_SH"
log "Wrote $PIP_CONF, $UV_CONF and $PROFILE_SH"

# --- Hugging Face models ---------------------------------------------------
if [[ ${#HF_MODELS[@]} -gt 0 ]]; then
  "$TOOL_PIP" install -q --no-index --find-links "$WH" huggingface_hub
  mkdir -p "$HF_CACHE"
  for m in "${HF_MODELS[@]}"; do
    log "Caching Hugging Face model $m"
    HF_HUB_CACHE="$HF_CACHE" "$TMP_DIR/tool/bin/python" -c \
      'import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1])' "$m"
  done
fi
mkdir -p "$HF_CACHE"

# --- Users -----------------------------------------------------------------
for u in "${ADD_USERS[@]}"; do
  for g in video render; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$u"
  done
  log "Added $u to video/render (takes effect at next login)"
done

# --- Verify ----------------------------------------------------------------
cat > "$PREFIX/verify.py" <<'EOF'
"""Checks the shared Jetson Python stack. Run as any user:
    python3 /opt/tinkerlab/python/verify.py
"""
import sys

failed = []


def check(name, fn, required=True):
    try:
        print(f"  OK    {name:<22} {fn()}")
    except Exception as e:
        msg = (str(e).splitlines() or [""])[0]
        if "not found in the system path" in msg or "cannot open shared object" in msg:
            msg = msg.split(" in the system path")[0] + " - a CUDA library is missing; re-run the setup script"
        print(f"  {'FAIL' if required else 'WARN'}  {name:<22} {type(e).__name__}: {msg}")
        if required:
            failed.append(name)


def torch_check():
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError(f"torch {torch.__version__} can't see the GPU (is this user in the 'video' group?)")
    (torch.ones(1024, device="cuda") * 2).sum().item()
    return f"{torch.__version__} on {torch.cuda.get_device_name(0)}"


def torchvision_check():
    import torch, torchvision
    from torchvision.ops import nms
    boxes = torch.tensor([[0, 0, 10, 10], [1, 1, 11, 11]], dtype=torch.float, device="cuda")
    nms(boxes, torch.tensor([0.9, 0.8], device="cuda"), 0.5)
    return torchvision.__version__


def tensorflow_check():
    import tensorflow as tf
    gpus = tf.config.list_physical_devices("GPU")
    return f"{tf.__version__}, GPUs visible: {len(gpus)}"


def onnxruntime_check():
    import onnxruntime as ort
    providers = ort.get_available_providers()
    if "CUDAExecutionProvider" not in providers:
        raise RuntimeError(f"no CUDA provider: {providers}")
    return f"{ort.__version__} {providers}"


def opencv_check():
    import re, cv2
    gst = re.search(r"GStreamer:\s+YES", cv2.getBuildInformation())
    return f"{cv2.__version__}, GStreamer {'yes' if gst else 'NO'}"


def version_of(module):
    def fn():
        mod = __import__(module)
        return getattr(mod, "__version__", "imported")
    return fn


def ollama_check():
    import ollama
    return f"server up, {len(ollama.list().models)} models"


check("torch (CUDA)", torch_check)
check("torchvision (CUDA)", torchvision_check)
check("torchaudio", version_of("torchaudio"))
check("tensorflow", tensorflow_check, required=False)
check("keras", version_of("keras"))
check("onnx", version_of("onnx"))
check("onnxruntime-gpu", onnxruntime_check)
check("tensorrt", version_of("tensorrt"), required=False)
check("opencv", opencv_check, required=False)
check("transformers", version_of("transformers"))
check("sentence_transformers", version_of("sentence_transformers"))
check("langchain", version_of("langchain"))
check("langchain_ollama", version_of("langchain_ollama"))
check("ollama server", ollama_check, required=False)

if failed:
    print(f"\nFailed: {', '.join(failed)}")
    sys.exit(1)
print("\nAll required checks passed.")
EOF

chmod -R a+rX "$PREFIX"

log "Checking a fresh venv can install offline from the wheelhouse"
python3 -m venv "$TMP_DIR/check"
env -u PIP_CONFIG_FILE "$TMP_DIR/check/bin/pip" install -q numpy \
  && log "Offline venv install works" \
  || warn "Offline venv install failed - check $PIP_CONF"
uv venv -q "$TMP_DIR/uvcheck" \
  && uv pip install -q --python "$TMP_DIR/uvcheck/bin/python" numpy \
  && log "Offline uv venv install works" \
  || warn "Offline uv venv install failed - check $UV_CONF"

if [[ $SYSTEM_INSTALL -eq 1 ]]; then
  log "Verifying the system stack"
  # shellcheck disable=SC1090
  ( source "$PROFILE_SH" && python3 "$PREFIX/verify.py" ) || warn "Some checks failed - see above."
fi

echo
log "Done. Students: log in again, then"
echo "    python3 -m venv --system-site-packages .venv   # reuse the shared stack (recommended)"
echo "    python3 -m venv .venv && .venv/bin/pip install torch   # or a clean venv, from the wheelhouse"
echo "    uv venv --system-site-packages && uv pip install ...    # same, with uv"
echo "    python3 $PREFIX/verify.py                      # check GPU access as that user"
