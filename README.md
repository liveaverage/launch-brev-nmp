# Deployment Web Application

A simple, self-contained web application for deploying Docker Compose or Helm charts with NGC API key authentication. The interface mimics the Brev/NVIDIA login console design.

## Features

- Single-page web interface styled after https://login.brev.nvidia.com/signin
- Support for Docker Compose and Helm chart deployments
- Secure API key input
- Easily configurable commands via JSON configuration
- Lightweight Docker container
- Real-time deployment feedback

## Quick Start

### Prerequisites

- Docker installed and running
- Docker socket access (for Docker Compose deployments)
- Helm charts or docker-compose.yaml in the working directory (as needed)
- For Kubernetes: kubectl and/or helm installed, kubeconfig configured

### Build the Docker Image

```bash
docker build -t deployment-app .
```

## Deployment Options for Local Kubernetes Orchestration

**CRITICAL**: When orchestrating Kubernetes/Helm deployments from a container to a local cluster (kind, k3s, minikube, Docker Desktop), network access is a key consideration. Choose the appropriate method:

### Option 1: Native/Host Mode (RECOMMENDED for Local K8s)

Run the app directly on your host without containerization. This avoids all networking issues.

```bash
./run-native.sh
```

**Pros:**
- No network isolation issues
- Direct access to Docker socket and kubeconfig
- Simplest setup for local development
- Works with all local Kubernetes distributions

**Cons:**
- Requires Python installed on host
- Less isolated

### Option 2: Host Network Mode

Run the container with `--network host` to share the host's network namespace.

```bash
./run-with-host-network.sh
```

**Pros:**
- Container can access `localhost` Kubernetes API
- Works with kind, k3s, minikube, Docker Desktop
- Still containerized

**Cons:**
- Linux only (Mac/Windows Docker Desktop doesn't fully support host network mode)
- Port 8080 must be available on host

### Option 3: Modified Kubeconfig (Cross-Platform)

Automatically modify kubeconfig to replace `localhost` with Docker-accessible addresses.

```bash
./run-with-kubeconfig-fix.sh
```

**Pros:**
- Works on Linux, Mac, and Windows
- Container remains isolated
- Port mapping works normally

**Cons:**
- Requires kubeconfig modification
- May need adjustment for different cluster types

### Option 4: Remote Kubernetes Cluster

For remote clusters (EKS, GKE, AKS, etc.), standard container deployment works:

```bash
docker run -d \
  -p 8080:8080 \
  -v ~/.kube/config:/root/.kube/config:ro \
  -v $(pwd)/config.json:/app/config.json:ro \
  --name deployment-app \
  deployment-app
```

### Docker Compose Only

If you're only using Docker Compose (no Kubernetes), standard deployment works:

```bash
docker run -d \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/docker-compose.yaml:/app/docker-compose.yaml:ro \
  --name deployment-app \
  deployment-app
```

### Access the Application

Open your browser and navigate to:
```
http://localhost:8080
```

## Configuration

### Customizing Commands

Edit the `config.json` file to customize the commands executed for each deployment type:

```json
{
  "docker-compose": {
    "command": "docker-compose up -d",
    "working_dir": "/app",
    "env_var": "NGC_API_KEY"
  },
  "helm": {
    "command": "helm install myrelease ./chart --set imagePullSecret=$NGC_API_KEY",
    "working_dir": "/app",
    "env_var": "NGC_API_KEY"
  }
}
```

#### Configuration Fields

- `command`: The shell command to execute
- `working_dir`: The directory where the command will be run
- `env_var`: The environment variable name where the API key will be stored

### Adding New Deployment Types

1. Edit `config.json` and add a new deployment type:

```json
{
  "my-custom-deploy": {
    "command": "kubectl apply -f deployment.yaml",
    "working_dir": "/app",
    "env_var": "MY_API_KEY"
  }
}
```

2. Update `index.html` to add the new option to the dropdown:

```html
<select id="deployType" name="deployType">
    <option value="docker-compose">Docker Compose</option>
    <option value="helm">Helm Chart</option>
    <option value="my-custom-deploy">My Custom Deploy</option>
</select>
```

3. Rebuild the Docker image

## File Structure

```
.
├── Dockerfile              # Container definition
├── app.py                  # Flask backend server
├── index.html              # Frontend interface
├── config.json             # Deployment configuration
├── requirements.txt        # Python dependencies
├── assets/
│   └── nvidia-logo.svg     # Logo (replace with actual NVIDIA logo)
└── README.md               # This file
```

## Customization

### Changing the Logo

Replace `assets/nvidia-logo.svg` with your own logo image (PNG, SVG, etc.) and update the reference in `index.html` if needed.

### Styling

All styles are contained in the `<style>` section of `index.html`. Key colors:
- Background: `#181818`
- Primary Green: `#76b900`
- Input Background: `#2a2a2a`

### Timeout

The default command timeout is 5 minutes. To change it, edit `app.py`:

```python
result = subprocess.run(
    command,
    shell=True,
    cwd=working_dir,
    env=env,
    capture_output=True,
    text=True,
    timeout=600  # Change to 10 minutes
)
```

## Security Considerations

- The API key is sent over HTTP by default. For production use, implement HTTPS
- API keys are passed as environment variables to subprocesses
- The application runs shell commands - ensure config.json is properly secured
- Docker socket access gives significant privileges - use with caution

## Troubleshooting

### Kubernetes commands fail with connection errors

This is the most common issue when running containerized orchestration against local clusters.

**Error:** `Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused`

**Cause:** The container can't reach the Kubernetes API at `localhost` because it's isolated.

**Solutions:**
1. Use **native mode** (recommended): `./run-native.sh`
2. Use **host network mode**: `./run-with-host-network.sh`
3. Use **modified kubeconfig**: `./run-with-kubeconfig-fix.sh`

### Docker Compose commands fail

Ensure the Docker socket is properly mounted:
```bash
-v /var/run/docker.sock:/var/run/docker.sock
```

Also verify the socket permissions:
```bash
ls -l /var/run/docker.sock
# Should show: srw-rw---- 1 root docker
```

### Helm/kubectl not found in container

The Dockerfile includes these tools. Rebuild the image:
```bash
docker build -t deployment-app .
```

### Commands timeout

Increase the timeout in `app.py` or check command execution logs:
```bash
docker logs deployment-app
```

### Port already in use

Change the port mapping:
```bash
docker run -p 9090:8080 ...
```

Then access at `http://localhost:9090`

### Permission denied on kubeconfig

Make sure the kubeconfig is readable:
```bash
chmod 644 ~/.kube/config
```

### Kind cluster specific issues

For kind clusters, you may need to export the kubeconfig explicitly:
```bash
kind export kubeconfig --name your-cluster-name
```

Then use host network mode or native mode for deployment.

## Development

To run the application without Docker:

```bash
# Install dependencies
pip install -r requirements.txt

# Run the server
python app.py
```

The application will be available at `http://localhost:8080`

## License

MIT
