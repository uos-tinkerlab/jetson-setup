# Jetson Python setup guide

This guide walks you through setting up a shared Python AI stack on the Jetson Orin Nanos that every account on the unit can use, without internet access.

It installs GPU builds of PyTorch (with torchvision and torchaudio), TensorFlow and ONNX Runtime. It also installs Keras, Hugging Face Transformers, LangChain with the Ollama integration, and the general packages listed in [jetson-python-requirements.txt](./jetson-python-requirements.txt).

## How it works

The setup is run once, with internet access, from an admin account. Student facing accounts and have no internet access, so everything they need is kept in a shared location that every account can read:

| Path | What it is |
| ---- | ---------- |
| `/opt/tinkerlab/python/wheelhouse` | Every package as a wheel file. `/etc/pip.conf` and `/etc/uv/uv.toml` point pip and uv here, so `pip install` and `uv pip install` work offline from any account or venv |
| `/opt/tinkerlab/python/cache/huggingface` | Shared, read-only Hugging Face model cache |
| `/opt/tinkerlab/python/debs` | The apt packages that were installed (JetPack components, build tools, camera packages), kept for offline units |
| `/opt/tinkerlab/python/redist` | Extra CUDA libraries (cuSPARSELt, cuDSS) that the PyTorch wheels need |
| `/opt/tinkerlab/python/verify.py` | A check that any user can run |
| System Python (`/usr/local/lib/python3.x/dist-packages`) | The whole stack which is installed and shared by all accounts |

`/etc/profile.d/tinkerlab-python.sh` sets the following for every login:

- the CUDA path
- the shared model cache
- offline mode for Hugging Face
- TensorFlow memory growth, so TensorFlow doesn't reserve all 8GB of shared memory on start-up

## Running the setup

On a unit with internet access, run:

```bash
sudo bash JETSON-PYTHON-SETUP.sh 
```

The script does the following:

1. Installs the JetPack components through apt (`nvidia-jetpack`: CUDA, cuDNN, TensorRT with its Python bindings, OpenCV and VPI), along with build tools and the GStreamer/V4L2 camera packages. A freshly flashed unit often only has the base system  without CUDA and PyTorch can't load without it. If JetPack's OpenCV isn't available, it installs Ubuntu's `python3-opencv` instead, which also supports GStreamer but ain't preferable to this build.
2. Adds the CUDA libraries to the system library path, and installs cuSPARSELt and cuDSS if they're missing. PyTorch needs these this implem of JetPack doesn't include them.
3. Downloads every package into the wheelhouse. GPU builds come from the [Jetson AI Lab index](https://pypi.jetson-ai-lab.io) and NVIDIA's TensorFlow build, with everything else coming from PyPI.
4. Installs the stack into the system Python, and installs `uv` for every account.
5. Writes `/etc/pip.conf`, `/etc/uv/uv.toml` and `/etc/profile.d/tinkerlab-python.sh`.
6. Adds the student account to the `video` and `render` groups, which it needs to use the GPU and cameras.
7. Checks that the GPU works in PyTorch, TensorFlow and ONNX Runtime.

| Option | Flag | Description | Default |
| ------ | ---- | ----------- | ------- |
| Prefix | --prefix PATH | Shared install root | /opt/tinkerlab/python |
| Requirements | --requirements FILE | General package list | jetson-python-requirements.txt |
| Index | --index URL | Jetson package index. Override this if the default is down or has moved | picked from JetPack version |
| No TensorFlow | --no-tensorflow | Leaves TensorFlow out. Use this if it causes version conflicts or you don't need it | |
| Wheelhouse only | --wheelhouse-only | Builds the wheelhouse but doesn't install into the system Python | |
| Offline | --offline | Installs from an existing prefix without downloading anything (see below) | |
| Hugging Face model | --hf-model ID | Pre-downloads a model into the shared cache. Repeat the flag for more models | |
| Add user | --add-user USER | Adds the account to the video/render groups. Repeat the flag for more users | |

To add packages, edit [jetson-python-requirements.txt](./jetson-python-requirements.txt) and run the script again. Avoid packages that pull in `onnxruntime` or `opencv-python`. They clash with the GPU build of ONNX Runtime and with JetPack's OpenCV, which is the build that has GStreamer camera support.

## Setting up the other units

Everything only needs to be downloaded onto one unit once. Copy the prefix to each unit (for example, using a USB stick or `rsync` across the offline network), then run the copy of the script that was saved in the prefix:

```bash
sudo rsync -a /media/usb/tinkerlab/python/ /opt/tinkerlab/python/
sudo bash /opt/tinkerlab/python/JETSON-PYTHON-SETUP.sh --offline --add-user student
```

This installs the cached apt packages from `debs/` first, so the offline units also get CUDA, TensorRT and OpenCV.

All the units must be flashed with the same JetPack image. The script checks the JetPack version. It can only install the apt packages that the first unit was missing, so if that unit already had some packages that the others don't, set up the first unit from a fresh flash.

## Models for offline use

Offline units can't download models, so put any models they need into the cache in advance:

```bash
sudo bash JETSON-PYTHON-SETUP.sh --hf-model sentence-transformers/all-MiniLM-L6-v2 --hf-model distilbert-base-uncased
```

Ollama models are managed separately. See the [Ollama setup guide](./JETSON-OLLAMA-SETUP-GUIDE.md).

## Using it as a student

Log out and back in after the setup has run. Then create a venv with `--system-site-packages`. It uses the shared stack straight away, without copying gigabytes of PyTorch into every project:

```bash
python3 -m venv --system-site-packages .venv
source .venv/bin/activate
pip install some-package    # installs from the wheelhouse; no internet needed
```

A clean venv also works. `pip install torch` then installs the GPU build from the wheelhouse:

```bash
python3 -m venv .venv
.venv/bin/pip install torch transformers
```

### With uv

`uv` works the same way and is much faster. It's set up to install only from the wheelhouse and to use only the system Python, because the wheels are built for that version:

```bash
uv venv --system-site-packages     # creates .venv using the shared stack
source .venv/bin/activate
uv pip install some-package        # installs from the wheelhouse
```

A clean `uv venv` followed by `uv pip install torch` also works. It hard-links packages from your uv cache, so further venvs take up very little extra disk space.

`uv venv` and `uv pip` are the reliable way to use uv here. `uv add` and `uv lock` try to find packages for every platform, which can fail when only Jetson builds are available. If you use them, add this to the project's `pyproject.toml`:

```toml
[tool.uv]
environments = ["sys_platform == 'linux' and platform_machine == 'aarch64'"]
```

Don't use Python versions from conda or downloaded by uv. The wheels won't install into them.

To check that the GPU works for your account:

```bash
python3 /opt/tinkerlab/python/verify.py
```

## Getting the most out of the Orin Nano

- Use the highest power mode: `sudo nvpmodel -m 2` sets MAXN SUPER on JetPack 6.2. Check the available modes with `sudo nvpmodel -q`.
- The CPU and GPU share 8GB of memory. Running Ollama and PyTorch or TensorFlow at the same time can run out of memory, so stop or unload the LLM before training anything.

## Cameras

The Raspberry Pi AI Camera (Sony IMX500) doesn't work on the Jetson. It depends on a Raspberry Pi kernel driver and on firmware that loads onto the sensor's on-chip NPU when the camera starts. Neither exists for Jetson Linux, and there's no vendor or community port.

The following cameras work:

- **Raspberry Pi Camera v2 (IMX219)** and **Raspberry Pi HQ Camera (IMX477)**. NVIDIA supports both. Enable them with `sudo /opt/nvidia/jetson-io/jetson-io.py`, then read frames with `nvarguscamerasrc` in GStreamer or OpenCV.
- **USB webcams (UVC)**. They work with no extra setup through `/dev/video*`.

The Jetson's GPU runs vision models much faster than the IMX500's NPU, so you lose nothing by running inference on the Jetson.
