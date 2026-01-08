#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# === Debug Settings ===
# Show exit codes and command context for all failures
trap 'echo "Error on line $LINENO: Command failed with exit code $?" >&2' ERR
# Print each command before execution
PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -x

# === Config ===
NAMESPACE="default"
REQUIRED_DISK_GB=200
REQUIRED_GPUS=2
NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
HF_TOKEN="${HF_TOKEN:-}"
ADDITIONAL_VALUES_FILES=()
HELM_CHART_URL=""
HELM_CHART_VERSION=""
FORCE_MODE=false
INSTALL_DEPS=false
CHECK_DEPS_ONLY=false
VERBOSE_MODE=false
ENABLE_SAFE_SYNTHESIZER=false
ENABLE_AUDITOR=false

# === Utility ===
log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
suggest_fix() { echo -e "\033[1;36m[SUGGESTION]\033[0m $*"; }
die() {
  show_help
  err "$*"
  echo
  exit 1
}

# Filter out known harmless Kubernetes warnings
filter_k8s_warnings() {
  grep -v 'unrecognized format.*int32' |
  grep -v 'unrecognized format.*int64' |
  grep -v 'spec.SessionAffinity is ignored for headless services' |
  grep -v 'duplicate port name.*http'
}

# Detect OS for platform-specific commands
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  elif [[ -f /etc/redhat-release ]]; then
    echo "rhel"
  else
    echo "unknown"
  fi
}

is_root() {
  [[ $EUID -eq 0 ]] || [[ $(id -u) -eq 0 ]]
}

# Preflight check if user has sudo access
check_sudo_access() {
  if is_root; then
    log "Running as root, no sudo required."
    return 0
  fi

  log "Checking sudo access"

  # Test if sudo is available
  if ! command -v sudo >/dev/null; then
    die "sudo is not available but required for modifying system host file to enable DNS resolution."
  fi

  # Test if user can actually use sudo
  log "Testing sudo access..."
  # First try passwordless sudo (for environments like Brev)
  if sudo -n true 2>/dev/null; then
    log "Passwordless sudo access confirmed."
  elif sudo -v 2>/dev/null; then
    log "Sudo access confirmed (password required)."
  else
    die "sudo access test failed. User does not have sudo privileges, sudo is misconfigured, or no password is set for passwordless sudo."
  fi
  log "sudo access verified successfully."
}

# Run a command with sudo if not root
maybe_sudo() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

# Prompt user for confirmation (y/n)
confirm_action() {
  local message="$1"
  local default="${2:-n}" # Default to 'n' for safety

  # If force mode is enabled, automatically return success
  if [[ "$FORCE_MODE" == "true" ]]; then
    log "Force mode enabled - automatically confirming: $message"
    return 0
  fi

  if [[ "$default" == "y" ]]; then
    local prompt="$message [Y/n]: "
  else
    local prompt="$message [y/N]: "
  fi

  while true; do
    read -p "$prompt" -r response
    case "${response:-$default}" in
    [yY] | [yY][eE][sS])
      return 0
      ;;
    [nN] | [nN][oO])
      return 1
      ;;
    *)
      echo "Please answer 'y' or 'n'."
      ;;
    esac
  done
}

show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Setup and deploy NeMo microservices on Minikube.

Options:
  --helm-chart-url URL         Direct URL to helm chart tgz file (mutually exclusive with --helm-chart-version)
  --helm-chart-version V       Version number available in the chart repo index (mutually exclusive with --helm-chart-url)
                               If neither flag is specified, defaults to latest available version
  --values-file FILE           Path to a values file (can be specified multiple times)
  --enable-safe-synthesizer    Enable Safe Synthesizer (Early Access service)
  --enable-auditor             Enable Auditor (Early Access service)
  --check-deps                 Check dependencies and show installation status, then exit
  --install-deps               Automatically install missing dependencies (requires confirmation)
  --verbose                    Enable verbose output for debugging
  --force                      Skip all confirmation prompts for destructive actions (use with caution)
  --help                       Show this help message

Environment Variables:
  NVIDIA_API_KEY         NVIDIA API key for registry and API access
                         Get from: https://build.nvidia.com/
                         Can be set in environment or will be prompted if not set
  HF_TOKEN               HuggingFace token to download models for customization
                         Get from: https://huggingface.co/settings/tokens
                         Can be set in environment or will be prompted if not set

Requirements:
  - NVIDIA Container Toolkit v1.16.2 or higher
  - NVIDIA GPU Driver 560.35.03 or higher
  - At least $REQUIRED_GPUS A100 80GB, H100 80GB, RTX 6000, or RTX 5880 GPUs
  - At least $REQUIRED_DISK_GB GB free disk space
  - minikube v1.33.0 or higher
  - Docker v27.0.0 or higher
  - kubectl
  - helm
  - huggingface_hub (Python library)
  - jq

Examples:
  # Check dependencies first
  $0 --check-deps
  
  # Quick start with auto-install of dependencies
  $0 --install-deps
  
  # Enable Early Access services. Need to keep up to date with the latest available services.
  $0 --enable-safe-synthesizer --enable-auditor
  
  # Using specific chart version
  $0 --helm-chart-version 25.9.0
  
  # Using custom values file
  $0 --values-file /path/to/values.yaml
  
  # Verbose mode for debugging
  $0 --verbose
  
  # Using direct chart URL (legacy method)
  $0 --helm-chart-url https://helm.ngc.nvidia.com/nvidia/nemo-microservices/charts/nemo-microservices-helm-chart-25.8.0.tgz

Note: When using --helm-chart-url, the script will prompt for confirmation before removing existing chart files.
      When reusing an existing Minikube cluster, the script automatically cleans up NIM services, 
      caches, and model deployment configmaps to ensure a clean deployment.
      Use --force to skip all confirmation prompts.
      
      A single NVIDIA API key from build.nvidia.com works for both
      NGC registry access and build.nvidia.com since the microservices are not gated.
EOF
}

# === Argument Parsing ===
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    --helm-chart-url)
      HELM_CHART_URL="$2"
      shift 2
      ;;
    --helm-chart-version)
      HELM_CHART_VERSION="$2"
      shift 2
      ;;
    --values-file)
      ADDITIONAL_VALUES_FILES+=("$2")
      shift 2
      ;;
    --enable-safe-synthesizer)
      ENABLE_SAFE_SYNTHESIZER=true
      shift
      ;;
    --enable-auditor)
      ENABLE_AUDITOR=true
      shift
      ;;
    --check-deps)
      CHECK_DEPS_ONLY=true
      shift
      ;;
    --install-deps)
      INSTALL_DEPS=true
      shift
      ;;
    --verbose)
      VERBOSE_MODE=true
      set -x
      shift
      ;;
    --force)
      FORCE_MODE=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      show_help
      exit 1
      ;;
    esac
  done
}

# Validate arguments
validate_args() {
  # Validate that only one chart source method is specified
  if [[ -n "$HELM_CHART_URL" && -n "$HELM_CHART_VERSION" ]]; then
    die "Cannot specify both --helm-chart-url and --helm-chart-version. Use only one."
  fi

  # If no flags specified, default to latest version from repo
  if [[ -z "$HELM_CHART_URL" && -z "$HELM_CHART_VERSION" ]]; then
    log "No chart source specified, defaulting to latest available chart version from repo..."
    HELM_CHART_VERSION="latest"
  fi

  # Handle Early Access services flags - create values file if needed
  if [[ "$ENABLE_SAFE_SYNTHESIZER" == "true" || "$ENABLE_AUDITOR" == "true" ]]; then
    local ea_values_file="/tmp/nemo-ea-services-$$.yaml"
    log "Early Access services requested, creating values file..."
    
    cat > "$ea_values_file" <<EOF
tags:
EOF
    
    if [[ "$ENABLE_SAFE_SYNTHESIZER" == "true" ]]; then
      echo "  safe-synthesizer: true" >> "$ea_values_file"
      log "  • Safe Synthesizer: enabled"
    fi
    
    if [[ "$ENABLE_AUDITOR" == "true" ]]; then
      echo "  auditor: true" >> "$ea_values_file"
      log "  • Auditor: enabled"
    fi
    
    ADDITIONAL_VALUES_FILES+=("$ea_values_file")
  fi

  # Values files are optional - chart has sensible defaults for minikube
  if [[ ${#ADDITIONAL_VALUES_FILES[@]} -gt 0 ]]; then
    log "Using ${#ADDITIONAL_VALUES_FILES[@]} values file(s) for deployment configuration."
  else
    log "No custom values files specified. Using chart defaults for minikube deployment."
  fi

  # Log force mode status
  if [[ "$FORCE_MODE" == "true" ]]; then
    log "Force mode enabled - all confirmation prompts will be skipped"
  fi
  
  # Log verbose mode status
  if [[ "$VERBOSE_MODE" == "true" ]]; then
    log "Verbose mode enabled - detailed command output will be shown"
  fi
}

# === Diagnostic Functions ===
collect_pod_diagnostics() {
  local pod=$1
  local namespace=$2
  local err_dir=$3
  local pod_dir="$err_dir/$pod"

  mkdir -p "$pod_dir"

  # Collect pod logs
  log "Collecting logs for pod $pod..."
  kubectl logs --all-containers "$pod" -n "$namespace" >"$pod_dir/logs.txt" 2>&1 || true
  kubectl logs --all-containers "$pod" -n "$namespace" --previous >"$pod_dir/logs.previous.txt" 2>&1 || true

  # Collect pod description
  log "Collecting pod description for $pod..."
  kubectl describe pod "$pod" -n "$namespace" >"$pod_dir/describe.txt" 2>&1 || true

  # Collect pod events
  log "Collecting events for pod $pod..."
  kubectl get events --field-selector involvedObject.name="$pod" -n "$namespace" >"$pod_dir/events.txt" 2>&1 || true

  # Check for image pull issues
  if kubectl describe pod "$pod" -n "$namespace" | grep -q "ImagePullBackOff\|ErrImagePull"; then
    log "Detected image pull issues for pod $pod"
    kubectl describe pod "$pod" -n "$namespace" | grep -A 10 "ImagePullBackOff\|ErrImagePull" >"$pod_dir/image_pull_issues.txt" 2>&1 || true
  fi

  # Collect container status
  log "Collecting container status for pod $pod..."
  kubectl get pod "$pod" -n "$namespace" -o json | jq '.status.containerStatuses' >"$pod_dir/container_status.json" 2>&1 || true
}

check_image_pull_secrets() {
  local namespace=$1
  log "Verifying image pull secrets..."

  # Check if the secret exists
  if ! kubectl get secret nvcrimagepullsecret -n "$namespace" &>/dev/null; then
    err "Image pull secret 'nvcrimagepullsecret' not found in namespace $namespace"
    return 1
  fi

  # Check if the secret is properly configured
  if ! kubectl get secret nvcrimagepullsecret -n "$namespace" -o json | jq -e '.data[".dockerconfigjson"]' &>/dev/null; then
    err "Image pull secret 'nvcrimagepullsecret' is not properly configured"
    return 1
  fi

  log "Image pull secrets verified successfully"
  return 0
}

# === Dependency Management ===
check_dependency() {
  local cmd=$1
  local name=$2
  
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "✓ $name"
    return 0
  else
    echo "✗ $name (missing)"
    return 1
  fi
}

show_install_instructions() {
  local os_type=$(detect_os)
  local dep=$1
  
  case "$dep" in
    jq)
      case "$os_type" in
        macos) echo "    brew install jq" ;;
        debian) echo "    sudo apt update && sudo apt install -y jq" ;;
        rhel) echo "    sudo yum install -y jq" ;;
      esac
      ;;
    kubectl)
      case "$os_type" in
        macos) echo "    brew install kubectl" ;;
        debian) echo "    sudo snap install kubectl --classic" ;;
        rhel) echo "    sudo yum install -y kubectl" ;;
      esac
      ;;
    helm)
      case "$os_type" in
        macos) echo "    brew install helm" ;;
        debian) echo "    sudo snap install helm --classic" ;;
        rhel) echo "    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ;;
      esac
      ;;
    minikube)
      case "$os_type" in
        macos) echo "    brew install minikube" ;;
        debian|rhel) echo "    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64" ;;
      esac
      ;;
    docker)
      case "$os_type" in
        macos) echo "    Download Docker Desktop from: https://www.docker.com/products/docker-desktop" ;;
        debian) echo "    curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker \$USER" ;;
        rhel) echo "    curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker \$USER" ;;
      esac
      ;;
    huggingface_hub)
      echo "    pip install --upgrade huggingface_hub"
      ;;
  esac
}

install_dependency() {
  local dep=$1
  local os_type=$(detect_os)
  
  log "Installing $dep..."
  
  case "$dep" in
    jq)
      case "$os_type" in
        macos) brew install jq ;;
        debian) sudo apt update && sudo apt install -y jq ;;
        rhel) sudo yum install -y jq ;;
        *) err "Cannot auto-install on this platform"; return 1 ;;
      esac
      ;;
    kubectl)
      case "$os_type" in
        macos) brew install kubectl ;;
        debian) sudo snap install kubectl --classic ;;
        rhel) sudo yum install -y kubectl ;;
        *) err "Cannot auto-install on this platform"; return 1 ;;
      esac
      ;;
    helm)
      case "$os_type" in
        macos) brew install helm ;;
        debian) sudo snap install helm --classic ;;
        rhel) curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash ;;
        *) err "Cannot auto-install on this platform"; return 1 ;;
      esac
      ;;
    minikube)
      case "$os_type" in
        macos) brew install minikube ;;
        debian|rhel)
          curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
          sudo install minikube-linux-amd64 /usr/local/bin/minikube
          rm minikube-linux-amd64
          ;;
        *) err "Cannot auto-install on this platform"; return 1 ;;
      esac
      ;;
    docker)
      case "$os_type" in
        macos) 
          warn "Docker Desktop must be installed manually on macOS"
          warn "Download from: https://www.docker.com/products/docker-desktop"
          return 1
          ;;
        debian)
          log "Installing Docker on Debian/Ubuntu..."
          sudo apt-get update
          sudo apt-get install -y ca-certificates curl
          sudo install -m 0755 -d /etc/apt/keyrings
          sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
          sudo chmod a+r /etc/apt/keyrings/docker.asc
          echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
          sudo apt-get update
          sudo apt-get install -y docker-ce docker-ce-cli containerd.io
          sudo usermod -aG docker $USER
          log "Docker installed. You may need to log out and back in for group changes to take effect"
          ;;
        rhel)
          log "Installing Docker on RHEL/CentOS..."
          sudo yum install -y yum-utils
          sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
          sudo yum install -y docker-ce docker-ce-cli containerd.io
          sudo systemctl start docker
          sudo systemctl enable docker
          sudo usermod -aG docker $USER
          log "Docker installed. You may need to log out and back in for group changes to take effect"
          ;;
        *) err "Cannot auto-install Docker on this platform"; return 1 ;;
      esac
      ;;
    huggingface_hub)
      # Install huggingface_hub Python library (used by Customizer for model downloads)
      pip install --upgrade huggingface_hub
      ;;
  esac
}

check_and_install_dependencies() {
  local missing_deps=()
  local os_type=$(detect_os)
  
  log "Checking dependencies..."
  echo ""
  
  # Check all dependencies
  check_dependency "jq" "jq" || missing_deps+=("jq")
  check_dependency "kubectl" "kubectl" || missing_deps+=("kubectl")
  check_dependency "helm" "helm" || missing_deps+=("helm")
  check_dependency "minikube" "minikube" || missing_deps+=("minikube")
  check_dependency "docker" "docker" || missing_deps+=("docker")
  
  # Check huggingface_hub Python library (used by Customizer for model downloads)
  if python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "✓ huggingface_hub (Python library)"
  else
    echo "✗ huggingface_hub (missing)"
    missing_deps+=("huggingface_hub")
  fi
  
  echo ""
  
  # If in check-only mode, show instructions and exit
  if [[ "$CHECK_DEPS_ONLY" == "true" ]]; then
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
      log "✓ All dependencies are installed!"
      exit 0
    else
      warn "Missing ${#missing_deps[@]} dependencies"
      echo ""
      echo "To install missing dependencies on $os_type:"
      echo ""
      for dep in "${missing_deps[@]}"; do
        echo "  $dep:"
        show_install_instructions "$dep"
        echo ""
      done
      
      echo "Or run this script with --install-deps to install automatically."
      exit 1
    fi
  fi
  
  # If dependencies are missing and install mode is enabled
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    if [[ "$INSTALL_DEPS" == "true" ]]; then
      warn "Missing ${#missing_deps[@]} dependencies: ${missing_deps[*]}"
      
      if [[ "$FORCE_MODE" != "true" ]]; then
        if ! confirm_action "Install missing dependencies automatically?"; then
          err "Cannot proceed without required dependencies"
          echo ""
          echo "To install manually:"
          for dep in "${missing_deps[@]}"; do
            echo "  $dep:"
            show_install_instructions "$dep"
            echo ""
          done
          exit 1
        fi
      else
        log "Force mode enabled - installing dependencies without confirmation"
      fi
      
      # Install each missing dependency
      for dep in "${missing_deps[@]}"; do
        if ! install_dependency "$dep"; then
          err "Failed to install $dep"
          suggest_fix "Please install $dep manually and try again"
          exit 1
        fi
      done
      
      log "All dependencies installed successfully!"
      
      # Refresh PATH to ensure newly installed tools are available
      export PATH="$HOME/.local/bin:/snap/bin:$PATH"
      log "Updated PATH to include newly installed tools"
    else
      err "Missing required dependencies: ${missing_deps[*]}"
      echo ""
      suggest_fix "Run with --check-deps to see installation instructions"
      suggest_fix "Or run with --install-deps to install automatically"
      exit 1
    fi
  else
    log "✓ All dependencies are installed"
  fi
}

# === Phase 0: Preflight Checks ===
check_prereqs() {
  log "Checking system requirements..."

  # Check jq
  if ! command -v jq >/dev/null; then
    die "jq is required but not found"
  fi

  # Check NVIDIA Container Toolkit version
  if command -v nvidia-ctk >/dev/null 2>&1; then
    nvidia_ctk_version=$(nvidia-ctk --version 2>/dev/null | head -n1 | awk '{print $6}')
    if [[ "$nvidia_ctk_version" == "0.0.0" ]]; then
      die "nvidia-ctk is installed but version check failed. Please ensure it's properly installed."
    fi
    if [[ "$(printf '%s\n' "1.16.2" "$nvidia_ctk_version" | sort -V | head -n1)" != "1.16.2" ]]; then
      warn "NVIDIA Container Toolkit v1.16.2 or higher is recommended. Found: $nvidia_ctk_version"
    fi
    log "NVIDIA Container Toolkit version: $nvidia_ctk_version"
  else
    die "nvidia-ctk is not installed. Please install it first."
  fi

  # Check NVIDIA GPU Driver version
  nvidia_driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
  if [[ "$(printf '%s\n' "560.35.03" "$nvidia_driver_version" | sort -V | head -n1)" != "560.35.03" ]]; then
    die "NVIDIA GPU Driver 560.35.03 or higher is required. Found: $nvidia_driver_version"
  fi

  # Check GPU models
  valid_gpus=0
  while IFS= read -r gpu; do
    log "Checking GPU: $gpu"
    if [[ "$gpu" == *"A100"*"80GB"* ]] || \
       [[ "$gpu" == *"H100"* ]] || \
       [[ "$gpu" == *"6000"* ]] || \
       [[ "$gpu" == *"5880"* ]] || \
       [[ "$gpu" == *"H200"* ]]; then
      log "Found valid GPU: $gpu"
      valid_gpus=$((valid_gpus + 1))
    fi
  done < <(nvidia-smi --query-gpu=name --format=csv,noheader)
  log "Total valid GPUs found: $valid_gpus"
  if ((valid_gpus < REQUIRED_GPUS)); then
    warn "At least $REQUIRED_GPUS A100 80GB, H100 80GB, RTX 6000, or RTX 5880 GPUs are required."
    warn "We could not confirm that you have the correct set of GPUs."
    warn "This could be a script error. Please check that you have the right set of GPUs."
    warn "Found: $valid_gpus"
  fi

  # Check filesystem type
  filesystem_type=$(df -T / | awk 'NR==2 {print $2}')
  if [[ "$filesystem_type" != "ext4" ]]; then
    warn "Warning: Filesystem type is $filesystem_type. EXT4 is recommended for proper file locking support."
  fi

  # Check free disk space
  free_space_gb=$(df / | awk 'NR==2 {print int($4 / 1024 / 1024)}')
  if ((free_space_gb < REQUIRED_DISK_GB)); then
    warn "Warning: Your root filesystem does not have enough free disk space."
    warn "This may not be a problem if you have other filesystems mounted,"
    warn "but you should check the output of df (below) to ensure that you"
    warn "have enough space for images and PVCs. Required: ${REQUIRED_DISK_GB} GB"
    df -kP
  fi

  # Check for minikube
  if ! command -v minikube >/dev/null; then
    die 'minikube is required to be in $PATH but not found'
  fi

  # Check for docker
  if ! command -v docker >/dev/null; then
    die 'docker executable is required to be in $PATH but not found'
  fi

  # Check minikube version
  minikube_version=$(minikube version --short 2>/dev/null | cut -d'v' -f2)
  if [[ "$(printf '%s\n' "1.33.0" "$minikube_version" | sort -V | head -n1)" != "1.33.0" ]]; then
    die "minikube v1.33.0 or higher is required. Found: $minikube_version"
  fi

  # Check Docker version
  docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  if [[ "$(printf '%s\n' "27.0.0" "$docker_version" | sort -V | head -n1)" != "27.0.0" ]]; then
    die "Docker v27.0.0 or higher is required. Found: $docker_version"
  fi

  # Check docker permissions
  if ! docker ps >/dev/null 2>&1; then
    die "User does not have permission to run docker commands. Please ensure your user has permission to run 'docker ps' without issues."
  fi

  # Check kubectl version
  if ! command -v kubectl >/dev/null; then
    die "kubectl is required but not found"
  fi
  kubectl_version=$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion' | sed 's/^v//')
  if [[ -z "$kubectl_version" ]]; then
    die "Could not determine kubectl version"
  fi

  # Check helm version
  if ! command -v helm >/dev/null; then
    die "helm is required but not found"
  fi
  helm_version=$(helm version --template='{{.Version}}' | sed 's/^v//')
  if [[ -z "$helm_version" ]]; then
    die "Could not determine helm version"
  fi

  # Check huggingface_hub Python library
  if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    err "huggingface_hub Python library is required but not found"
    suggest_fix "Install with: pip install --upgrade huggingface_hub"
    suggest_fix "Or run with: ./$(basename $0) --install-deps"
    exit 1
  fi

  log "All prerequisites are met."
}

# === Phase 1: Minikube Setup ===
start_minikube() {
  log "Checking Minikube status..."
  if minikube status &>/dev/null; then
    log "Minikube is already running. Checking for existing NMP deployment..."

    # Check if nemo helm release exists and uninstall it if it does
    if helm list -n "$NAMESPACE" | grep -q "nemo"; then
      log "Found existing 'nemo' helm release. Performing complete cleanup..."

      if confirm_action "Remove existing 'nemo' helm release?"; then
        log "Removing existing 'nemo' helm release..."
      else
        die "Existing 'nemo' helm release found and must be removed before continuing."
      fi

      # First, manually clean up NIM-related resources that persist beyond Helm uninstall
      log "Cleaning up NIM services..."
      kubectl delete nimservice --all -n "$NAMESPACE" --ignore-not-found=true || warn "Failed to delete some NIM services"

      log "Cleaning up NIM caches..."
      kubectl delete nimcache --all -n "$NAMESPACE" --ignore-not-found=true || warn "Failed to delete some NIM caches"

      log "Cleaning up model deployment configmaps..."
      kubectl delete configmap -n "$NAMESPACE" -l "app.nvidia.com/config-type=modelDeployment" --ignore-not-found=true || warn "Failed to delete some model deployment configmaps"

      log "Cleaning up CRDs..."
      kubectl get crd -o name | grep "nvidia.com" | xargs -I {} kubectl delete {} --ignore-not-found=true || warn "Failed to delete some CRDs"

      # Wait for custom resource cleanup
      sleep 5

      # Now uninstall the Helm release
      log "Uninstalling existing 'nemo' helm release..."
      helm uninstall nemo -n "$NAMESPACE" || warn "Failed to uninstall existing nemo release, but continuing..."

      # Wait a bit for cleanup
      sleep 10
    else
      log "No existing 'nemo' helm release found. Continuing with existing minikube cluster."
    fi

    # Ensure ingress addon is enabled
    if ! minikube addons list | grep -q "ingress.*enabled"; then
      log "Enabling ingress addon..."
      minikube addons enable ingress
    else
      log "Ingress addon already enabled."
    fi

    # Ensure GPU label is set
    if ! kubectl get node minikube -o jsonpath='{.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present}' | grep -q "true"; then
      log "Labeling minikube node with NVIDIA GPU label..."
      kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true --overwrite
    else
      log "GPU label already set on minikube node."
    fi

    log "Using existing minikube cluster."
    return 0
  fi

  log "Starting Minikube with GPU support..."

  # Add --force flag if running as root
  local extra_args=""
  if is_root; then
    extra_args="--force"
    log "Running as root, adding --force flag to minikube command"
  fi

  minikube start \
    --driver=docker \
    --container-runtime=docker \
    --cpus=no-limit \
    --memory=no-limit \
    --gpus=all \
    $extra_args

  log "Enabling ingress addon..."
  minikube addons enable ingress

  log "Labeling minikube node with NVIDIA GPU label..."
  kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true --overwrite
}

# === Phase 2: API Key Setup ===
setup_api_keys() {
  log "Setting up authentication..."
  echo ""
  
  # Get NVIDIA API key if not already set
  if [[ -z "$NVIDIA_API_KEY" ]]; then
    read -rsp "Enter your NVIDIA API Key (from build.nvidia.com): " NVIDIA_API_KEY
    echo
    if [[ -z "$NVIDIA_API_KEY" ]]; then
      err "NVIDIA API key is required"
      suggest_fix "Get your key from https://build.nvidia.com/explore/discover#llama-3_1-8b-instruct"
      exit 1
    fi
  fi
  
  # Get HuggingFace token if not already set
  if [[ -z "$HF_TOKEN" ]]; then
    read -rsp "Enter your HuggingFace token (from huggingface.co): " HF_TOKEN
    echo
    if [[ -z "$HF_TOKEN" ]]; then
      err "HuggingFace token is required"
      suggest_fix "Get your token from https://huggingface.co/settings/tokens"
      exit 1
    fi
  fi
  
  export NVIDIA_API_KEY
  export HF_TOKEN
  
  echo ""
  log "Creating Kubernetes secrets..."
  
  # Delete existing secrets if they exist
  kubectl delete secret nvcrimagepullsecret -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret ngc-api -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret nvidia-api -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret hf-token -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  
  # Create NGC registry secret (uses NVIDIA_API_KEY)
  kubectl create secret docker-registry nvcrimagepullsecret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NVIDIA_API_KEY" || {
      err "Failed to create NGC image pull secret"
      suggest_fix "Verify your NVIDIA API key is correct and has NGC access"
      exit 1
    }
  
  # Create NGC API secret (uses NVIDIA_API_KEY - Helm chart expects this)
  kubectl create secret generic ngc-api \
    --from-literal=NGC_API_KEY="$NVIDIA_API_KEY" || {
      err "Failed to create NGC API secret"
      exit 1
    }
  
  # Create NVIDIA API secret (same key, used by other services)
  kubectl create secret generic nvidia-api \
    --from-literal=NVIDIA_API_KEY="$NVIDIA_API_KEY" || {
      err "Failed to create NVIDIA API secret"
      exit 1
    }
  
  # Create HuggingFace token secret
  kubectl create secret generic hf-token \
    --from-literal=HF_TOKEN="$HF_TOKEN" || {
      err "Failed to create HuggingFace token secret"
      exit 1
    }
  
  log "✓ All authentication secrets created successfully"
}

# === Phase 3: Deploy Helm Chart ===
download_helm_chart() {
  helm_args=()
  for values_file in "${ADDITIONAL_VALUES_FILES[@]}"; do
    if [[ ! -f "$values_file" ]]; then
      die "Values file not found: $values_file"
    fi
    helm_args+=("-f" "$values_file")
  done

  if [[ -n "$HELM_CHART_VERSION" ]]; then
    # Using chart version from repo index
    log "Setting up NeMo microservices Helm repository for version $HELM_CHART_VERSION..."

    # Validate NVIDIA API key is available
    if [[ -z "$NVIDIA_API_KEY" ]]; then
      err "NVIDIA_API_KEY not set when configuring helm repository"
      suggest_fix "Export NVIDIA_API_KEY before running: export NVIDIA_API_KEY='nvapi-xxx'"
      suggest_fix "Or run the script interactively and enter it when prompted"
      exit 1
    fi

    # Add the helm repository (--force-update makes it idempotent)
    log "Authenticating with NGC helm repository..."
    helm repo add nmp https://helm.ngc.nvidia.com/nvidia/nemo-microservices \
      --username='$oauthtoken' \
      --password="$NVIDIA_API_KEY" \
      --force-update || die "Failed to add helm repository"

    log "Updating helm repository..."
    helm repo update || die "Failed to update helm repository"

    log "Helm repository setup complete. Chart version $HELM_CHART_VERSION will be installed directly from the repository."
  else
    # Using direct chart URL (legacy method)
    log "Downloading NeMo microservices Helm chart from direct URL..."
    log "Note: You will be prompted for confirmation before removing any existing chart files."

    # Clean up any existing chart files to ensure fresh download
    if [[ -d "nemo-microservices-helm-chart" ]]; then
      log "Found existing chart directory 'nemo-microservices-helm-chart'."
      if confirm_action "Remove existing chart directory to ensure fresh download?"; then
        log "Removing existing chart directory..."
        rm -rf nemo-microservices-helm-chart
        log "Chart directory removed successfully."
      else
        log "Skipping chart directory cleanup. Using existing directory."
      fi
    fi

    if ls nemo-microservices-helm-chart-*.tgz 1>/dev/null 2>&1; then
      log "Found existing chart tgz file(s):"
      ls -la | grep nemo-microservices-helm-chart
      if confirm_action "Remove existing chart tgz files to ensure fresh download?"; then
        log "Removing existing chart tgz files..."
        rm -rf nemo-microservices-helm-chart-*.tgz
        log "Chart tgz files removed successfully."
      else
        log "Skipping chart tgz file cleanup. Using existing files."
      fi
    fi

    # Check if we have the required chart files for installation
    if [[ ! -d "nemo-microservices-helm-chart" ]] && ! ls nemo-microservices-helm-chart-*.tgz 1>/dev/null 2>&1; then
      log "Downloading fresh NeMo microservices Helm chart..."

      helm fetch --untar "$HELM_CHART_URL" \
        --username='$oauthtoken' \
        --password="$NGC_API_KEY"
    else
      # If user skipped cleanup but we have a URL, we need fresh files
      die "Cannot proceed with --helm-chart-url when existing chart files are present. Please either allow cleanup of existing files or remove them manually."
    fi
  fi
}

install_nemo_microservices() {
  log "Installing NeMo microservices Helm chart..."

  volcano_version="v1.9.0"
  log "Installing Volcano scheduler version: $volcano_version"
  kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/${volcano_version}/installer/volcano-development.yaml 2>&1 | filter_k8s_warnings

  sleep 15

  if [[ -n "$HELM_CHART_VERSION" ]]; then
    # Install from the helm repository with specific version
    if [[ "$HELM_CHART_VERSION" == "latest" ]]; then
      log "Installing latest available NeMo microservices version from helm repository..."
      helm install nemo nmp/nemo-microservices-helm-chart --namespace "$NAMESPACE" \
        "${helm_args[@]}" \
        --set guardrails.guardrails.nvcfAPIKeySecretName="nvidia-api" \
        --timeout 30m 2>&1 | filter_k8s_warnings
    else
      log "Installing NeMo microservices version $HELM_CHART_VERSION from helm repository..."
      helm install nemo nmp/nemo-microservices-helm-chart --namespace "$NAMESPACE" \
        --version "$HELM_CHART_VERSION" \
        "${helm_args[@]}" \
        --set guardrails.guardrails.nvcfAPIKeySecretName="nvidia-api" \
        --timeout 30m 2>&1 | filter_k8s_warnings
    fi
  else
    # Install from local chart file (legacy method)
    log "Installing NeMo microservices from local chart file..."
    helm install nemo nemo-microservices-helm-chart --namespace "$NAMESPACE" \
      "${helm_args[@]}" \
      --set guardrails.guardrails.nvcfAPIKeySecretName="nvidia-api" \
      --timeout 30m 2>&1 | filter_k8s_warnings
  fi

  sleep 20
}

wait_for_pods() {
  log "Waiting for pods to initialize (up to 30 minutes)..."
  log "You may see some CrashLoops initially - that's normal and they'll recover."
  log "Showing progress every 30 seconds..."
  echo ""

  local old_err_trap=$(trap -p ERR)
  trap 'echo "Interrupted by user. Exiting."; exit 1;' SIGINT

  local start_time=$(date +%s)
  local end_time=$((start_time + 1800))
  local last_status_time=$start_time

  while true; do
    # Get current pod statuses
    local pod_statuses
    if ! pod_statuses=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null); then
      warn "Failed to get pod statuses from kubectl. Retrying..."
      sleep 5
      continue
    fi

    # --- Show periodic progress ---
    local current_time=$(date +%s)
    if ((current_time - last_status_time >= 30)); then
      local elapsed=$((current_time - start_time))
      local elapsed_min=$((elapsed / 60))
      
      # Count pod states (strip newlines)
      local total_pods=$(echo "$pod_statuses" | wc -l | tr -d '\n')
      local running=$(echo "$pod_statuses" | grep -c "Running" 2>/dev/null || echo "0")
      local completed=$(echo "$pod_statuses" | grep -c "Completed" 2>/dev/null || echo "0")
      local pending=$(echo "$pod_statuses" | grep -c "Pending" 2>/dev/null || echo "0")
      local init=$(echo "$pod_statuses" | grep -c "Init:" 2>/dev/null || echo "0")
      local container_creating=$(echo "$pod_statuses" | grep -c "ContainerCreating" 2>/dev/null || echo "0")
      local crash_loop=$(echo "$pod_statuses" | grep -c "CrashLoop" 2>/dev/null || echo "0")
      
      # Trim whitespace from all counts
      total_pods=$(echo "$total_pods" | xargs)
      running=$(echo "$running" | xargs)
      completed=$(echo "$completed" | xargs)
      pending=$(echo "$pending" | xargs)
      init=$(echo "$init" | xargs)
      container_creating=$(echo "$container_creating" | xargs)
      crash_loop=$(echo "$crash_loop" | xargs)
      
      echo ""
      log "⏱️  Status after ${elapsed_min} minutes:"
      echo "  📊 Total pods: $total_pods | ✅ Running: $running | 🏁 Completed: $completed"
      
      # Check if any non-zero counts exist (safely)
      local has_pending=0
      [[ "$pending" != "0" ]] && has_pending=1
      [[ "$init" != "0" ]] && has_pending=1
      [[ "$container_creating" != "0" ]] && has_pending=1
      [[ "$crash_loop" != "0" ]] && has_pending=1
      
      if [[ $has_pending -eq 1 ]]; then
        echo "  ⏳ Pending: $pending | 🔄 Init: $init | 📦 Creating: $container_creating | ⚠️ CrashLoop: $crash_loop"
      fi
      
      # Show a few pods that are still not ready
      local not_ready=$(echo "$pod_statuses" | grep -v "Running" | grep -v "Completed" | head -n 3)
      if [[ -n "$not_ready" ]]; then
        echo "  Sample pods initializing:"
        echo "$not_ready" | awk '{printf "    • %s: %s\n", $1, $3}'
      fi
      echo ""
      
      last_status_time=$current_time
    fi

    # --- Premature exit for ImagePull errors ---
    local image_pull_errors
    image_pull_errors=$(echo "$pod_statuses" | grep -E "ImagePullBackOff|ErrImagePull" || true)
    if [[ -n "$image_pull_errors" ]]; then
      err "Detected ImagePull errors!"
      echo "$image_pull_errors" >&2 # Show the specific pods with errors
      warn "Gathering diagnostics for pods with ImagePull errors..."
      # Extract pod names with errors and collect diagnostics
      local error_pods=($(echo "$image_pull_errors" | awk '{print $1}'))
      local err_dir="nemo-errors-$(date +%s)"
      mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"
      for pod in "${error_pods[@]}"; do
        collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
      done
      # Restore trap before dying
      eval "$old_err_trap"
      trap - SIGINT
      echo ""
      err "Exiting due to ImagePull errors"
      echo ""
      suggest_fix "This usually indicates an authentication issue with NGC registry"
      suggest_fix "Verify your NVIDIA API key is correct:"
      echo "  curl -H \"Authorization: Bearer \$NVIDIA_API_KEY\" https://api.ngc.nvidia.com/v2/org"
      echo ""
      suggest_fix "If authentication fails, regenerate your key at build.nvidia.com"
      suggest_fix "Then run: ./$(basename $0) --force to skip confirmations"
      echo ""
      suggest_fix "Diagnostics collected to: $err_dir"
      exit 1
    fi
    # --- End ImagePull check ---

    # Check if any non-Completed pods are in other problematic states
    if ! echo "$pod_statuses" | grep -v "Completed" | grep -qE "0/|Pending|CrashLoop|Error"; then
      log "All necessary pods are ready or succeeded."
      break
    fi

    # Check for timeout
    local current_time=$(date +%s)
    if ((current_time >= end_time)); then
      warn "Timeout waiting for pods to stabilize. Gathering diagnostics..."
      check_pod_health # Attempt to collect info before exiting
      # Restore trap before dying
      eval "$old_err_trap"
      trap - SIGINT
      die "Timeout waiting for pods to stabilize after 30 minutes. Diagnostics collected (if possible)."
    fi

    sleep 10
  done

  # Restore the original ERR trap and remove the SIGINT trap
  eval "$old_err_trap"
  trap - SIGINT

  log "Pods have stabilized."
}

# === Phase 4: Pod Health Verification ===
check_pod_health() {
  log "Checking pod health and collecting errors if needed..."
  local err_dir="nemo-errors-$(date +%s)"
  # Try to create the directory, but continue even if it fails (e.g., permissions)
  mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"

  # Check for image pull issues first
  # Use a temporary variable to store the return code
  local secrets_ok=0
  check_image_pull_secrets "$NAMESPACE" || secrets_ok=$?
  if [[ $secrets_ok -ne 0 ]]; then
    # If secrets check fails, we likely can't proceed usefully, but we already logged.
    # Let's still try to get pod status before potentially dying.
    warn "Image pull secret issues detected. Pods might fail to start."
  fi

  # Get all pods in the namespace
  # Use process substitution and check kubectl's exit code
  local all_pods=()
  if ! mapfile -t all_pods < <(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name); then
    warn "Failed to get pod list from kubectl."
    # Optionally, decide if this is fatal or if we can continue
    # For now, we'll just warn and might have an empty list
  fi

  # Track unhealthy pods
  local unhealthy_pods=()
  local pending_pods=()

  for pod in "${all_pods[@]}"; do
    local pod_status=""
    # Get status, handle potential kubectl errors
    if ! pod_status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null); then
      warn "Failed to get status for pod: $pod"
      unhealthy_pods+=("$pod") # Treat error getting status as unhealthy
      continue
    fi

    if [[ "$pod_status" != "Running" && "$pod_status" != "Succeeded" ]]; then
      if [[ "$pod_status" == "Pending" ]]; then
        pending_pods+=("$pod")
      # Add Failed status as unhealthy explicitly
      elif [[ "$pod_status" == "Failed" ]]; then
        warn "Pod $pod is in Failed state."
        unhealthy_pods+=("$pod")
      else
        # Catch other non-Running/Succeeded/Pending states (like Unknown)
        warn "Pod $pod is in unexpected state: $pod_status"
        unhealthy_pods+=("$pod")
      fi
    fi
  done

  # Handle pending pods first
  if ((${#pending_pods[@]} > 0)); then
    warn "Detected ${#pending_pods[@]} pending pods. Checking if they eventually run..."
    local still_pending=()
    for pod in "${pending_pods[@]}"; do
      # Give pending pods a short time to resolve (e.g., 60 seconds)
      timeout 60 bash -c "while kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Pending; do sleep 5; done" || {
        warn "Pod $pod remained in Pending state."
        unhealthy_pods+=("$pod") # Add to unhealthy if it stays pending
      }
    done
  fi

  # Handle unhealthy pods
  if ((${#unhealthy_pods[@]} > 0)); then
    warn "Detected ${#unhealthy_pods[@]} unhealthy pods. Gathering diagnostics..."
    # De-duplicate unhealthy list before collecting diagnostics
    local unique_unhealthy=($(printf "%s\n" "${unhealthy_pods[@]}" | sort -u))

    for pod in "${unique_unhealthy[@]}"; do
      collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
    done

    # Collect cluster-wide events
    log "Collecting cluster-wide events..."
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' >"$err_dir/cluster_events.txt" 2>/dev/null || warn "Failed to get cluster events."

    warn "Diagnostics written to $err_dir (if possible)"
    # This function is now just for checking, not dying. The caller decides.
    return 1 # Indicate unhealthy state
  else
    log "All pods are healthy (Running or Succeeded)."
    return 0 # Indicate healthy state
  fi
}

# === Phase 5: DNS Configuration ===
configure_dns() {
  log "Configuring DNS for ingress..."
  minikube_ip=$(minikube ip)
  
  log "Using Minikube IP: $minikube_ip"

  # Backup /etc/hosts
  log "Creating backup of /etc/hosts..."
  maybe_sudo cp /etc/hosts "/etc/hosts.backup.$(date +%Y%m%d%H%M%S)"

  # Check if entries already exist with correct IP
  if grep -q "$minikube_ip.*nim.test" /etc/hosts && \
     grep -q "$minikube_ip.*data-store.test" /etc/hosts && \
     grep -q "$minikube_ip.*nemo.test" /etc/hosts; then
    log "DNS entries already correctly configured, skipping..."
    return 0
  fi

  # Remove any existing entries for these hostnames
  if grep -q "nim.test\|data-store.test\|nemo.test" /etc/hosts; then
    warn "Existing entries found in /etc/hosts. Updating with current Minikube IP..."
    maybe_sudo sed -i.bak "/nemo.test/d" /etc/hosts
    maybe_sudo sed -i.bak "/nim.test/d" /etc/hosts
    maybe_sudo sed -i.bak "/data-store.test/d" /etc/hosts
  fi

  # Add new entries
  {
    echo "# Added by NeMo setup script"
    echo "$minikube_ip nim.test"
    echo "$minikube_ip data-store.test"
    echo "$minikube_ip nemo.test"
  } | maybe_sudo tee -a /etc/hosts >/dev/null

  log "✓ DNS configured successfully"
  log "  • nim.test → $minikube_ip"
  log "  • data-store.test → $minikube_ip"
  log "  • nemo.test → $minikube_ip"
}

# === Phase 6: Deploy LLaMA NIM ===
deploy_llama_nim() {
  local nim_name="llama-3.1-8b-instruct"
  local nim_api_namespace="meta"
  local minikube_ip=$(minikube ip)

  log "Requesting deployment of $nim_name NIM..."
  # Use timeout and fail fast for the curl command itself
  if ! curl --fail \
    --connect-timeout 10 \
    --max-time 30 \
    --location "http://nemo.test/v1/deployment/model-deployments" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "{
        \"name\": \"$nim_name\",
        \"namespace\": \"$nim_api_namespace\",
        \"config\": {
          \"model\": \"$nim_api_namespace/$nim_name\",
          \"nim_deployment\": {
            \"image_name\": \"nvcr.io/nim/$nim_api_namespace/$nim_name\",
            \"image_tag\": \"1.8.3\",
            \"pvc_size\": \"25Gi\",
            \"gpu\": 1,
            \"additional_envs\": {
              \"NIM_GUIDED_DECODING_BACKEND\": \"fast_outlines\"
            }
          }
        }
      }"; then
    die "Failed to submit NIM deployment request for $nim_name."
  fi
  log "NIM deployment request for $nim_name submitted."
}

# === Phase 7: Wait for NIM Readiness ===
wait_for_nim() {
  local nim_name="llama-3.1-8b-instruct"
  local nim_api_namespace="meta"
  local nim_label_selector="app=$nim_name"
  local minikube_ip=$(minikube ip)
  local nim_api_url="http://nemo.test/v1/deployment/model-deployments/$nim_api_namespace/$nim_name"

  log "Waiting for $nim_name NIM to reach READY status (up to 30 minutes)... Press Ctrl+C to exit early."

  local old_err_trap=$(trap -p ERR)
  trap 'echo "Interrupted by user during NIM wait. Exiting."; exit 1;' SIGINT

  local start_time=$(date +%s)
  local end_time=$((start_time + 1800))

  while true; do
    # 1. Get underlying Pod status
    local nim_pod_statuses
    nim_pod_statuses=$(kubectl get pods -n "$NAMESPACE" -l "$nim_label_selector" --no-headers 2>/dev/null || true)
    local nim_pod_names=($(echo "$nim_pod_statuses" | awk '{print $1}' || true))

    # 2. Check for critical ImagePull errors first
    if [[ -n "$nim_pod_statuses" ]]; then
      local image_pull_errors
      image_pull_errors=$(echo "$nim_pod_statuses" | grep -E "ImagePullBackOff|ErrImagePull" || true)
      if [[ -n "$image_pull_errors" ]]; then
        err "Detected ImagePull errors for $nim_name NIM pods!"
        echo "$image_pull_errors" >&2
        warn "Gathering diagnostics for $nim_name pods with ImagePull errors..."
        local error_pods=($(echo "$image_pull_errors" | awk '{print $1}'))
        local err_dir="nemo-errors-$(date +%s)"
        mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"
        for pod in "${error_pods[@]}"; do
          collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
        done
        eval "$old_err_trap"
        trap - SIGINT
        echo ""
        err "Exiting due to ImagePull errors during $nim_name deployment"
        echo ""
        suggest_fix "This usually indicates an authentication issue with NGC registry"
        suggest_fix "Verify your NVIDIA API key is correct:"
        echo "  curl -H \"Authorization: Bearer \$NVIDIA_API_KEY\" https://api.ngc.nvidia.com/v2/org"
        echo ""
        suggest_fix "If authentication fails, regenerate your key at build.nvidia.com"
        suggest_fix "Then clean up and retry:"
        echo "  ./destroy-nmp-deployment.sh"
        echo "  ./$(basename $0)"
        echo ""
        suggest_fix "Diagnostics collected to: $err_dir"
        exit 1
      fi
    fi

    # 3. Get NIM API status
    local status
    if ! status=$(curl -s --fail --connect-timeout 5 --max-time 10 "$nim_api_url" | jq -r '.status_details.status' 2>/dev/null); then
      # If API fails, could be transient or NIM not registered yet
      status="API_UNAVAILABLE"
    elif [[ "$status" == "null" ]]; then
      # Explicit null means API knows about it but no firm status yet
      status="PENDING_API"
    fi

    # 4. Check for READY state (Goal)
    if [[ "$status" == "ready" ]]; then
      log "$nim_name NIM deployment successful and status is READY."
      break
    fi

    # 5. Check for Downloading/Loading state (API not READY, Pod exists, 0/N ready, Logs started)
    local is_downloading=false
    if [[ "$status" != "ready" ]] && [[ ${#nim_pod_names[@]} -gt 0 ]]; then
      # Check the first pod found (assuming single replica NIM)
      local nim_pod_name="${nim_pod_names[0]}"
      local pod_line=$(echo "$nim_pod_statuses" | grep "$nim_pod_name" || true)
      local readiness=$(echo "$pod_line" | awk '{print $2}' || true) # e.g., 0/1

      # Check if readiness starts with "0/" (e.g., 0/1)
      if [[ "$readiness" == "0/"* ]]; then
        # Pod exists and is 0/N ready. Check if logs have started.
        local log_check_output
        # Use --quiet to suppress "error: container ... is not running"
        log_check_output=$(kubectl logs "$nim_pod_name" -n "$NAMESPACE" --tail 1 --quiet 2>/dev/null || true)
        if [[ -n "$log_check_output" ]]; then
          # Pod is 0/N ready but HAS logs -> Downloading/Loading
          is_downloading=true
          log "NIM pod $nim_pod_name is not ready ($readiness) but has logs; likely downloading/loading weights. API status: $status. Waiting..."
        fi
      fi
    fi

    # 6. Check for Timeout
    local current_time=$(date +%s)
    if ((current_time >= end_time)); then
      err "Timeout waiting for $nim_name NIM to reach READY state after 30 minutes."
      warn "Gathering final diagnostics for $nim_name pods (if any exist)..."
      local final_pods=($(kubectl get pods -n "$NAMESPACE" -l "$nim_label_selector" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true))
      local err_dir="nemo-errors-$(date +%s)"
      mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"
      if [[ ${#final_pods[@]} -gt 0 ]]; then
        for pod in "${final_pods[@]}"; do
          collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
        done
      else
        log "No pods found matching label $nim_label_selector to collect diagnostics from."
      fi
      log "Last known API status for $nim_name: $status"
      kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' >"$err_dir/cluster_events.txt" 2>/dev/null || warn "Failed to get cluster events."
      eval "$old_err_trap"
      trap - SIGINT
      die "NIM deployment $nim_name did not reach READY state in time. Diagnostics gathered to $err_dir (if possible)."
    fi

    # 7. Log generic waiting message if not downloading/loading
    if ! $is_downloading; then
      if [[ ${#nim_pod_names[@]} -eq 0 ]]; then
        log "Waiting for NIM pod(s) with label $nim_label_selector to be created... API status: $status"
      else
        log "Current $nim_name NIM status: $status. Pod(s) found: ${nim_pod_names[*]}. Waiting..."
      fi
    fi

    sleep 15
  done

  # Restore traps on successful completion
  eval "$old_err_trap"
  trap - SIGINT
  log "NIM deployment check complete."
}

# === Phase 8: Verify NIM Endpoint ===
verify_nim_endpoint() {
  local models_endpoint="http://nim.test/v1/models"
  log "Verifying NIM endpoint $models_endpoint is responsive..."

  # Try curling the endpoint a few times with short delays
  local attempts=3
  local delay=5 # seconds
  for ((i = 1; i <= attempts; i++)); do
    if curl --fail \
      --silent \
      --show-error \
      --connect-timeout 5 \
      --max-time 10 \
      "$models_endpoint" >/dev/null; then
      log "✓ NIM endpoint $models_endpoint is up and responding"
      return 0 # Success
    fi
    if ((i < attempts)); then
      warn "NIM endpoint check failed (attempt $i/$attempts). Retrying in ${delay}s..."
      sleep $delay
    fi
  done

  # If all attempts failed
  echo ""
  err "Failed to verify NIM endpoint $models_endpoint after $attempts attempts"
  echo ""
  suggest_fix "This usually indicates a DNS or networking issue"
  suggest_fix "Verify DNS configuration:"
  echo "  cat /etc/hosts | grep nemo.test"
  echo "  Expected: $(minikube ip) nemo.test"
  echo ""
  suggest_fix "Test DNS resolution:"
  echo "  ping -c 1 nim.test"
  echo ""
  suggest_fix "Check ingress controller:"
  echo "  kubectl get ingress -n default"
  echo "  kubectl get pods -n ingress-nginx"
  echo ""
  warn "Attempting verbose connection for debugging:"
  curl -v "$models_endpoint" 2>&1 || true
  echo ""
  exit 1
}

# === Main Entrypoint ===
main() {
  parse_args "$@"
  validate_args
  
  # Check and optionally install dependencies early
  check_and_install_dependencies
  
  check_prereqs
  check_sudo_access
  download_helm_chart
  start_minikube
  # Ingress needs a few more seconds after it reports ready before the containers can get installed
  sleep 10
  setup_api_keys
  install_nemo_microservices
  wait_for_pods
  check_pod_health || die "Base cluster is not healthy after waiting. Investigate and re-run."
  configure_dns
  deploy_llama_nim
  wait_for_nim
  verify_nim_endpoint
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "🎉 Setup Complete! NeMo Microservices Platform is ready!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  minikube_ip=$(minikube ip)
  
  log "📍 Your endpoints:"
  echo "  • NIM Gateway:   http://nim.test"
  echo "  • Data Store:    http://data-store.test"
  echo "  • Platform APIs: http://nemo.test (all /v1/* endpoints)"
  echo ""
  log "📚 Quick tests:"
  echo "  • List models:        curl http://nim.test/v1/models"
  echo "  • Data Store health:  curl http://data-store.test/v1/health"
  echo "  • List namespaces:    curl http://nemo.test/v1/namespaces"
  echo "  • Customization API:  curl http://nemo.test/v1/customization/jobs"
  echo ""
  log "💡 Useful commands:"
  echo "  • View all pods:        kubectl get pods -n default"
  echo "  • Check service status: kubectl get svc -n default"
  echo "  • View logs:            kubectl logs <pod-name> -n default"
  echo "  • Clean up:             ./destroy-nmp-deployment.sh"
  echo ""
  log "📖 Documentation: https://docs.nvidia.com/nemo/microservices/"
  echo ""
}

main "$@"
