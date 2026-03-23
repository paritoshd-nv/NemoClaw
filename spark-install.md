# NemoClaw on DGX Spark

> **WIP** — This page is actively being updated as we work through Spark installs. Expect changes.

## Quick Start

```bash
# Clone and install
git clone https://github.com/NVIDIA/NemoClaw.git
cd NemoClaw
sudo npm install -g .

# Spark-specific setup (configures Docker for cgroup v2, then runs normal setup)
nemoclaw setup-spark
```

That's it. `setup-spark` handles everything below automatically.

## What's Different on Spark

DGX Spark ships **Ubuntu 24.04 + Docker 28.x** but no k8s/k3s. OpenShell embeds k3s inside a Docker container, which hits two problems on Spark:

### 1. Docker permissions

```
Error in the hyper legacy client: client error (Connect)
  Permission denied (os error 13)
```

**Cause**: Your user isn't in the `docker` group.
**Fix**: `setup-spark` runs `usermod -aG docker $USER`. You may need to log out and back in (or `newgrp docker`) for it to take effect.

### 2. cgroup v2 incompatibility

```
K8s namespace not ready
openat2 /sys/fs/cgroup/kubepods/pids.max: no
Failed to start ContainerManager: failed to initialize top level QOS containers
```

**Cause**: Spark runs cgroup v2 (Ubuntu 24.04 default). OpenShell's gateway container starts k3s, which tries to create cgroup v1-style paths that don't exist. The fix is `--cgroupns=host` on the container, but OpenShell doesn't expose that flag.

**Fix**: `setup-spark` sets `"default-cgroupns-mode": "host"` in `/etc/docker/daemon.json` and restarts Docker. This makes all containers use the host cgroup namespace, which is what k3s needs.

## Prerequisites

These should already be on your Spark:

- **Docker** (pre-installed, v28.x)
- **Node.js 22** — if not installed:
  ```bash
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ```
- **OpenShell CLI**:
  ```bash
  ARCH=$(uname -m)  # aarch64 on Spark
  curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/latest/download/openshell-linux-${ARCH}" -o /usr/local/bin/openshell
  chmod +x /usr/local/bin/openshell
  ```
- **NVIDIA API Key** from [build.nvidia.com](https://build.nvidia.com) — prompted on first run

## Manual Setup (if setup-spark doesn't work)

### Fix Docker cgroup namespace

```bash
# Check if you're on cgroup v2
stat -fc %T /sys/fs/cgroup/
# Expected: cgroup2fs

# Add cgroupns=host to Docker daemon config
sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(path, 'w'), indent=2)
"

# Restart Docker
sudo systemctl restart docker
```

### Fix Docker permissions

```bash
sudo usermod -aG docker $USER
newgrp docker  # or log out and back in
```

### Then run the onboard wizard

```bash
nemoclaw onboard
```

## Setup Local Inference (Ollama)

Use this to run inference locally on the DGX Spark's GPU instead of routing to cloud.

### Step 1: Verify NVIDIA Container Runtime

```bash
docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```

If this fails, configure the NVIDIA runtime and restart Docker:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### Step 2: Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Verify it is running:

```bash
curl http://localhost:11434
```

### Step 3: Pull and Pre-load a Model

Download Nemotron 3 Super 120B (~87 GB; may take several minutes):

```bash
ollama pull nemotron-3-super:120b
```

Run it briefly to pre-load weights into unified memory, then exit:

```bash
ollama run nemotron-3-super:120b
# type /bye to exit
```

### Step 4: Configure Ollama to Listen on All Interfaces

By default Ollama binds to `127.0.0.1`, which is not reachable from inside the sandbox container. Configure it to listen on all interfaces:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' | sudo tee /etc/systemd/system/ollama.service.d/override.conf

sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify Ollama is listening on all interfaces:

```bash
ss -tlnp | grep 11434
```

### Step 5: Install OpenShell and NemoClaw

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

When prompted for **Inference options**, select **Local Ollama**, then select the model you pulled.

### Step 6: Connect and Test

```bash
# Connect to the sandbox
nemoclaw my-assistant connect
```

Inside the sandbox, first verify `inference.local` is reachable directly (must use HTTPS — the proxy intercepts `CONNECT inference.local:443`):

```bash
curl -sf https://inference.local/v1/models
# Expected: JSON response listing the configured model
# Exits non-zero on HTTP errors (403, 503, etc.) — failure here indicates a proxy routing regression
```

Then talk to the agent:

```bash
openclaw agent --agent main --local -m "Which model and GPU are in use?" --session-id test
```

## Known Issues

| Issue | Status | Workaround |
|-------|--------|------------|
| cgroup v2 kills k3s in Docker | Fixed in `setup-spark` | `daemon.json` cgroupns=host |
| Docker permission denied | Fixed in `setup-spark` | `usermod -aG docker` |
| CoreDNS CrashLoop after setup | Fixed in `fix-coredns.sh` | Uses container gateway IP, not 127.0.0.11 |
| Image pull failure (k3s can't find built image) | OpenShell bug | `openshell gateway destroy && openshell gateway start`, re-run setup |
| GPU passthrough | Untested on Spark | Should work with `--gpu` flag if NVIDIA Container Toolkit is configured |

## Verifying Your Install

```bash
# Check sandbox is running
openshell sandbox list
# Should show: nemoclaw  Ready

# Test the agent
openshell sandbox connect nemoclaw
# Inside sandbox:
nemoclaw-start openclaw agent --agent main --local -m 'hello' --session-id test

# Monitor network egress (separate terminal)
openshell term
```

## Architecture Notes

```
DGX Spark (Ubuntu 24.04, cgroup v2)
  └── Docker (28.x, cgroupns=host)
       └── OpenShell gateway container
            └── k3s (embedded)
                 └── nemoclaw sandbox pod
                      └── OpenClaw agent + NemoClaw plugin
```
