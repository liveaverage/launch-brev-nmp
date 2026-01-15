<h1 align="center">🚀 NeMo Microservices Launcher</h1>

<p align="center">
  <strong>One-click web interface for deploying NVIDIA NeMo Microservices Platform</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Helm-Chart-0F1689?style=for-the-badge&logo=helm&logoColor=white" alt="Helm"/>
  <img src="https://img.shields.io/badge/Kubernetes-Orchestration-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white" alt="Kubernetes"/>
  <img src="https://img.shields.io/badge/NVIDIA-NeMo-76B900?style=for-the-badge&logo=nvidia&logoColor=white" alt="NVIDIA NeMo"/>
  <img src="https://img.shields.io/badge/Flask-Backend-000000?style=for-the-badge&logo=flask&logoColor=white" alt="Flask"/>
</p>

---

## 🚀 Quick Start

### Deploy Instantly with NVIDIA Brev

<p align="center">
  <em>Skip the setup—launch NeMo Microservices on a fully configured GPU cluster in seconds</em>
</p>

<table align="center">
<thead>
<tr>
<th align="center">GPU</th>
<th align="center">VRAM</th>
<th align="center">Best For</th>
<th align="center">Deploy</th>
</tr>
</thead>
<tbody>
<tr>
<td align="center"><strong>🟢 NVIDIA H100</strong></td>
<td align="center">80 GB</td>
<td align="center">Production NeMo Platform</td>
<td align="center"><a href="https://brev.nvidia.com/launchable/deploy/now?launchableID=env-37wipAuAptYmhMzmPiS2DJj7aL3"><img src="https://brev-assets.s3.us-west-1.amazonaws.com/nv-lb-dark.svg" alt="Deploy on Brev" height="40"/></a></td>
</tr>
</tbody>
</table>

<p align="center">
  <sub>☝️ Click to launch on <a href="https://brev.nvidia.com">Brev</a> — GPU cloud for AI developers</sub>
</p>

### One-Line Bootstrap (Recommended)

**Non-interactive (for automation/scripts):**
```bash
curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | sudo -E bash
```

**Interactive (prompts for password if needed):**
```bash
curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
```

> **Note:** Storage extension requires sudo. Use `sudo -E bash` for non-interactive deployments.

**What it does:**
- ✅ Clones the repository
- ✅ Auto-extends root storage using ephemeral volumes (if available)
- ✅ Logs all output to `/var/log/interlude-bootstrap.log`
- ✅ Pulls container image (`ghcr.io/liveaverage/launch-brev-nmp:latest`)
- ✅ Starts the launcher on port 9090
- ✅ Exposes web UI at `http://localhost:9090`

<details>
<summary><strong>📂 Custom Install Directory</strong></summary>

```bash
INSTALL_DIR=/opt/nemo-launcher curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
```

</details>

<details>
<summary><strong>📝 Custom Log Location</strong></summary>

```bash
# Custom log file location
LOG_FILE=/tmp/interlude-bootstrap.log curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash

# View logs in real-time
tail -f /var/log/interlude-bootstrap.log
```

**Default locations:**
- Primary: `/var/log/interlude-bootstrap.log` (requires sudo)
- Fallback: `~/.interlude-bootstrap.log` (if /var/log not writable)

</details>

---

## 📋 Prerequisites

| Requirement | Details |
|:------------|:--------|
| **Kubernetes** | MicroK8s, K3s, or managed K8s cluster |
| **GPU** | NVIDIA GPU with drivers 525.60.13+ |
| **Helm** | Helm 3.x installed |
| **NGC API Key** | From [ngc.nvidia.com](https://ngc.nvidia.com/) |

> **Note:** The launcher auto-detects cluster configuration and handles Volcano scheduler installation.

### Supported Platforms

| Platform | Status |
|:---------|:-------|
| **MicroK8s** with NVIDIA GPU | ✅ Fully supported |
| **K3s** with NVIDIA GPU | ✅ Fully supported |
| **EKS/GKE/AKS** with GPU nodes | ✅ Fully supported |
| **Kind/Minikube** (local dev) | ⚠️ Limited GPU support |

---

## 💾 Storage Management

The bootstrap script automatically extends root storage when ephemeral volumes are detected (e.g., `/dev/vdb`). 

### Auto-Extension Behavior

When the script detects a mounted ephemeral volume with >50GB free space:

1. **Stops running services** (if needed):
   - Docker daemon (if `/var/lib/docker` needs migration)
   - MicroK8s (if containerd storage needs migration)

2. **Relocates heavy-use directories** via bind mounts:
   - `/var/lib/docker` → `/ephemeral/data/var/lib/docker`
   - `/var/snap/microk8s/common/var/lib/containerd` → ephemeral storage

3. **Preserves existing data**: Uses `rsync` to migrate any existing files before mounting

4. **Restarts services**: Brings Docker/MicroK8s back up with new storage location

5. **Persists across reboots**: Adds entries to `/etc/fstab` for both the ephemeral volume and bind mounts

6. **Idempotent**: Safe to run multiple times (skips already-mounted paths and existing fstab entries)

> **Important:** If MicroK8s is running, expect a brief (~30-60s) service interruption during storage migration.

### Persistence & Safety

✅ **Persistent**: Bind mounts survive reboots (via `/etc/fstab`)  
✅ **Safe**: Non-destructive; no partition modifications  
✅ **Automatic**: Works on first boot and every subsequent reboot  
⚠️ **Cloud-specific**: Ephemeral volumes may be instance-local (check your cloud provider's docs)

### Manual Control

To disable auto-extension, modify `bootstrap.sh` and comment out the `extend_root_storage` call.

### Verification

```bash
# Check mounted ephemeral storage
df -h | grep ephemeral

# Verify bind mounts are active
findmnt --type bind | grep -E "(docker|containerd)"

# Check /etc/fstab entries
grep -E "(ephemeral|docker|containerd)" /etc/fstab

# Test persistence (simulate reboot)
sudo mount -a  # remount everything from fstab
```

### Important Notes

**Ephemeral Volume Behavior by Cloud Provider:**

| Provider | Ephemeral Volume | Survives Reboot? | Survives Instance Stop? |
|:---------|:-----------------|:-----------------|:------------------------|
| **AWS EC2** | Instance store | ✅ Yes | ❌ No (data lost) |
| **GCP** | Local SSD | ✅ Yes | ❌ No (data lost) |
| **Azure** | Temp disk | ✅ Yes | ❌ No (data lost) |
| **Brev/Bare Metal** | Secondary disk | ✅ Yes | ✅ Yes (check config) |

> **Recommendation**: Use ephemeral storage for cache/temp data (Docker layers, containerd cache). For persistent application data, use cloud persistent disks/volumes.

> **Note:** Ephemeral volumes may not persist across VM reboots on some cloud providers. Critical persistent data should remain on root volume or use persistent volumes.

---

## 🎯 Usage

<table>
<tr>
<th>Step</th>
<th>Action</th>
</tr>
<tr>
<td>1️⃣</td>
<td>Open <code>http://localhost:9090</code> in your browser</td>
</tr>
<tr>
<td>2️⃣</td>
<td>Enter your <strong>NGC API Key</strong></td>
</tr>
<tr>
<td>3️⃣</td>
<td>Click <strong>🤙 Let it rip</strong> to deploy</td>
</tr>
<tr>
<td>4️⃣</td>
<td>Monitor real-time logs as Helm installs NeMo components</td>
</tr>
<tr>
<td>5️⃣</td>
<td>Access services via generated links</td>
</tr>
</table>

### 🌐 Service Links

After deployment completes, clickable service links appear:

| Service | Path | Description |
|:--------|:-----|:------------|
| **🎨 NeMo Studio** | `/studio` | Visual workflow builder and model management |
| **📓 Jupyter Notebooks** | `/jupyter/lab` | NVIDIA GenerativeAI examples |
| **⚙️ Deployment Status** | `/interlude` | Launcher UI and deployment logs |

### 🗑️ Uninstalling

Click **Uninstall** to:
- Run `helm uninstall` on NeMo Microservices
- Delete the NeMo namespace
- Remove Jupyter deployment
- Clean up deployment state

---

## ⚙️ Configuration

### 🔗 Path-Based Routing

All services are accessible via single-origin path-based routing:

```
https://your-domain.com/           → Deployment UI (Interlude)
https://your-domain.com/studio     → NeMo Studio
https://your-domain.com/jupyter/lab → Jupyter Notebooks
https://your-domain.com/v1/...     → NeMo API endpoints
```

**Benefits:**
- No CORS issues
- Single SSL certificate
- Clean URL structure

<details>
<summary><strong>🎨 Customization</strong></summary>

Edit `config.json` to modify deployment behavior:

```json
{
  "helm-nemo": {
    "heading": "Deploy NeMo Microservices",
    "namespace": "nemo",
    "services": [
      {"name": "NeMo Studio", "url": "/studio", "description": "..."}
    ]
  }
}
```

</details>

---

## 🏗️ Architecture

### Frontend (SPA)
- Pure JavaScript (no framework dependencies)
- Server-Sent Events (SSE) for real-time log streaming
- Deployment state management with history mode

### Backend (Flask + Nginx)
- Lightweight Python Flask application
- Nginx reverse proxy for path-based routing
- Real-time command streaming
- Persistent deployment state tracking

### Deployed Components

| Component | Namespace | Purpose |
|:----------|:----------|:--------|
| **NeMo Microservices** | `nemo` | Core platform (Studio, NIM Proxy, Entity Store, etc.) |
| **Jupyter** | `jupyter` | NVIDIA GenerativeAI examples |
| **Volcano** | `volcano-system` | Batch scheduling for training jobs |

---

## 🔥 Troubleshooting

<details>
<summary><strong>📋 View Bootstrap Logs</strong></summary>

**All bootstrap operations are logged for debugging:**

```bash
# View full bootstrap log
cat /var/log/interlude-bootstrap.log

# Or fallback location
cat ~/.interlude-bootstrap.log

# Follow logs in real-time (during bootstrap)
tail -f /var/log/interlude-bootstrap.log

# View only the latest bootstrap session
grep -A 9999 "Bootstrap session:" /var/log/interlude-bootstrap.log | tail -n +1
```

**Log includes:**
- Storage extension operations
- Container pulls and starts
- Mount operations and fstab entries
- Error messages with timestamps

</details>

<details>
<summary><strong>❌ Helm Install Fails</strong></summary>

**Symptom:** `helm install` returns error

**Solution:**
```bash
# Check cluster connectivity
kubectl cluster-info

# Verify NGC API key
helm registry login nvcr.io --username '$oauthtoken' --password YOUR_KEY
```

</details>

<details>
<summary><strong>❌ Pods Stuck in Pending</strong></summary>

**Symptom:** Pods don't start, stuck in `Pending`

**Solution:**
```bash
# Check for GPU availability
kubectl describe nodes | grep -A5 nvidia.com/gpu

# Verify Volcano scheduler
kubectl get pods -n volcano-system
```

</details>

<details>
<summary><strong>❌ MicroK8s Broken After Storage Migration</strong></summary>

**Symptom:** `kubectl cluster-info` returns "the server could not find the requested resource" after storage migration

**Cause:** MicroK8s restarted but the interlude container has stale kubeconfig

**Quick Fix:**
```bash
# Restart the container to pick up new kubeconfig
docker restart interlude

# Verify it works
docker logs -f interlude
```

**Full Recovery (if needed):**
```bash
# Run the automated recovery script
bash ~/launch-brev-nmp/scripts/recover-microk8s-storage.sh

# Or manual steps:
sudo microk8s stop
sleep 5
sudo microk8s start
sudo microk8s status --wait-ready
docker restart interlude
```

</details>

<details>
<summary><strong>💾 Disk Space Issues</strong></summary>

**Symptom:** Deployments fail with "no space left on device"

**Solution:**
```bash
# Check disk usage
df -h

# If ephemeral volume exists but not mounted:
sudo mkdir -p /ephemeral
sudo mount /dev/vdb /ephemeral  # adjust device as needed

# Manually trigger storage extension
cd ~/launch-brev-nmp
bash bootstrap.sh

# Verify bind mounts
findmnt --type bind | grep -E "(docker|containerd)"

# Clean up Docker cache
docker system prune -af --volumes
```

</details>

<details>
<summary><strong>❌ Jupyter Not Accessible</strong></summary>

**Symptom:** `/jupyter/lab` returns 404 or hangs

**Solution:**
```bash
# Check Jupyter pod
kubectl get pods -n jupyter
kubectl logs -n jupyter -l app=jupyter

# Re-run proxy configuration
docker exec interlude bash /app/nemo-proxy/configure-proxy.sh
```

</details>

<details>
<summary><strong>🐛 Development Mode</strong></summary>

Run locally without Docker:

```bash
pip install -r requirements.txt
python app.py
```

Access at `http://localhost:9090`

</details>

---

## 🌍 Environment Variables

| Variable | Default | Description |
|:---------|:--------|:------------|
| `DEPLOY_TYPE` | `helm-nemo` | Active deployment type |
| `DEPLOY_HEADING` | `Deploy NeMo Microservices` | Custom heading |
| `LAUNCHER_PATH` | `/interlude` | Base path for deployment UI |

---

## 📚 API Endpoints

<details>
<summary><strong>View Available Endpoints</strong></summary>

```bash
# Check configuration
curl http://localhost:9090/config

# Check deployment state
curl http://localhost:9090/state

# View help content
curl http://localhost:9090/help
```

</details>

---

<p align="center">
  <sub>Built on the <strong>Interlude</strong> framework • MIT License</sub>
</p>
