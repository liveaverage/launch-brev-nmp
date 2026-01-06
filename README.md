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
<td align="center"><a href="https://brev.nvidia.com/launchable/deploy?launchableID=env-2vkIVQUiE6AsCgXRUXTsOCIlUvv"><img src="https://brev-assets.s3.us-west-1.amazonaws.com/nv-lb-dark.svg" alt="Deploy on Brev" height="40"/></a></td>
</tr>
</tbody>
</table>

<p align="center">
  <sub>☝️ Click to launch on <a href="https://brev.nvidia.com">Brev</a> — GPU cloud for AI developers</sub>
</p>

### One-Line Bootstrap (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
```

**What it does:**
- ✅ Clones the repository
- ✅ Pulls container image (`ghcr.io/liveaverage/launch-brev-nmp:latest`)
- ✅ Starts the launcher on port 9090
- ✅ Exposes web UI at `http://localhost:9090`

<details>
<summary><strong>📂 Custom Install Directory</strong></summary>

```bash
INSTALL_DIR=/opt/nemo-launcher curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
```

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
