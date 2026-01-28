#!/bin/bash
# =============================================================================
# Kimi K2.5 Startup Script for Container-Optimized OS
# =============================================================================
# This script runs on instance startup to configure the vLLM inference server
# using Docker Compose on Container-Optimized OS.
# =============================================================================

set -e
set -o pipefail

# Configuration
MODEL_PATH="${model_path}"
TENSOR_PARALLEL="${tensor_parallel}"
API_PORT="${api_port}"
HUGGINGFACE_TOKEN="${huggingface_token}"
ENABLE_AUTO_SHUTDOWN="${ENABLE_AUTO_SHUTDOWN}"
MOUNT_POINT="/mnt/disks/model-storage"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting Kimi K2.5 setup..."

# =============================================================================
# Mount Persistent Disk
# =============================================================================
log "Mounting persistent disk..."

# Find the model storage disk (largest non-boot disk)
DISK_DEVICE=$(lsblk -dnpo NAME,SIZE,TYPE | grep disk | grep -v $(lsblk -no NAME $(findmnt -n -o SOURCE /) | head -n1) | sort -k2 -hr | head -n1 | awk '{print $1}')

if [ -n "$DISK_DEVICE" ]; then
    log "Found disk device: $DISK_DEVICE"
    # Check if disk is already formatted
    if ! blkid "$DISK_DEVICE" > /dev/null 2>&1; then
        log "Formatting disk $DISK_DEVICE..."
        mkfs.ext4 -F "$DISK_DEVICE"
    fi
    
    # Create mount point and mount
    mkdir -p "$MOUNT_POINT"
    mount "$DISK_DEVICE" "$MOUNT_POINT" || log "Disk may already be mounted"
    
    # Set permissions
    chmod 755 "$MOUNT_POINT"
    log "Disk mounted at $MOUNT_POINT"
else
    log "WARNING: No additional disk found, using local storage"
    mkdir -p "$MOUNT_POINT"
fi

# =============================================================================
# Install Docker Compose
# =============================================================================
log "Setting up Docker Compose..."

# On COS, we use the built-in Docker
mkdir -p /var/lib/docker-compose

# =============================================================================
# Create Docker Compose Configuration
# =============================================================================
log "Creating Docker Compose configuration..."

cat > /var/lib/docker-compose/docker-compose.yaml << 'EOF'
services:
  vllm-server:
    image: vllm/vllm-openai:v0.11.0
    container_name: kimi-k25-server
    runtime: nvidia
    restart: unless-stopped
    ports:
      - "${API_PORT}:${API_PORT}"
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - CUDA_DEVICE_ORDER=PCI_BUS_ID
      - HUGGING_FACE_HUB_TOKEN=${HUGGINGFACE_TOKEN}
      - VLLM_LOGGING_LEVEL=INFO
    volumes:
      - /mnt/disks/model-storage:/root/.cache/huggingface
      - /mnt/disks/model-storage:/models
    command:
      - python
      - -m
      - vllm.entrypoints.openai.api_server
      - --model=${MODEL_PATH}
      - --tensor-parallel-size=${TENSOR_PARALLEL}
      - --trust-remote-code
      - --max-model-len=32768
      - --dtype=bfloat16
      - --tool-call-parser=kimi_k2
      - --reasoning-parser=kimi_k2
      - --port=${API_PORT}
      - --download-dir=/models
      - --load-format=auto
      - --quantization=None
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${API_PORT}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 300s
    logging:
      driver: "gcplogs"
      options:
        gcp-project: "${google_cloud_project}"
EOF

# =============================================================================
# Install NVIDIA Drivers for COS
# =============================================================================
log "Installing NVIDIA drivers..."
# Standard COS method for A100/H100
docker run --rm --privileged gcr.io/cos-cloud/cos-gpu-installer:latest install

# =============================================================================
# Configure NVIDIA Container Runtime
# =============================================================================
log "Configuring NVIDIA Container Runtime..."

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

# Restart Docker to apply changes
log "Restarting Docker..."
systemctl restart docker

# =============================================================================
# Create Systemd Service (Docker Run)
# =============================================================================
log "Creating systemd service..."

cat > /etc/systemd/system/kimi-vllm.service << EOF
[Unit]
Description=Kimi K2.5 vLLM Inference Server
Requires=docker.service
After=docker.service

[Service]
Restart=always
ExecStartPre=-/usr/bin/docker stop kimi-k25-server
ExecStartPre=-/usr/bin/docker rm kimi-k25-server
ExecStart=/usr/bin/docker run \\
    --name kimi-k25-server \\
    --runtime=nvidia \\
    -p ${api_port}:${api_port} \\
    -v /mnt/disks/model-storage:/root/.cache/huggingface \\
    -v /mnt/disks/model-storage:/models \\
    -e NVIDIA_VISIBLE_DEVICES=all \\
    -e HUGGING_FACE_HUB_TOKEN=${huggingface_token} \\
    vllm/vllm-openai:v0.11.0 \\
    python -m vllm.entrypoints.openai.api_server \\
    --model=${model_path} \\
    --tensor-parallel-size=${tensor_parallel} \\
    --trust-remote-code \\
    --max-model-len=32768 \\
    --dtype=bfloat16 \\
    --tool-call-parser=kimi_k2 \\
    --reasoning-parser=kimi_k2 \\
    --port=${api_port} \\
    --download-dir=/models \\
    --load-format=auto \\
    --quantization=None

ExecStop=/usr/bin/docker stop kimi-k25-server

[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
# Pull Model (if not present)
# =============================================================================
log "Checking for model..."

if [ -n "$HUGGINGFACE_TOKEN" ]; then
    log "HuggingFace token configured"
    echo "$HUGGINGFACE_TOKEN" > /mnt/disks/model-storage/huggingface.token
    chmod 600 /mnt/disks/model-storage/huggingface.token
fi

# =============================================================================
# Start Services
# =============================================================================
log "Starting vLLM service..."

# Reload systemd
systemctl daemon-reload

# Enable and start the service
systemctl enable kimi-vllm.service
systemctl start kimi-vllm.service

# =============================================================================
# Create Status Script
# =============================================================================
log "Creating helper scripts..."

cat > /usr/local/bin/kimi-status << 'EOF'
#!/bin/bash
echo "=== Kimi K2.5 Status ==="
echo ""
echo "Container Status:"
docker ps --filter name=kimi-k25-server --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "GPU Status:"
nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used --format=csv
echo ""
echo "API Health:"
curl -s http://localhost:8000/health 2>/dev/null || echo "API not responding"
echo ""
echo "Logs (last 50 lines):"
docker logs --tail 50 kimi-k25-server 2>&1 | tail -20
EOF
chmod +x /usr/local/bin/kimi-status

cat > /usr/local/bin/kimi-logs << 'EOF'
#!/bin/bash
docker logs -f kimi-k25-server
EOF
chmod +x /usr/local/bin/kimi-logs

cat > /usr/local/bin/kimi-restart << 'EOF'
#!/bin/bash
echo "Restarting Kimi K2.5 server..."
cd /var/lib/docker-compose && docker compose restart
echo "Restart complete. Check status with: kimi-status"
EOF
chmod +x /usr/local/bin/kimi-restart

# =============================================================================
# Setup Auto-shutdown (Optional)
# =============================================================================
log "Setting up auto-shutdown monitoring..."

cat > /usr/local/bin/kimi-auto-shutdown.sh << 'EOF'
#!/bin/bash
# Auto-shutdown if no API requests for 30 minutes
IDLE_TIME_LIMIT=1800000  # 30 min in ms
LOG_FILE="/var/log/kimi-requests.log"

# Create log file if not exists
touch "$LOG_FILE"

while true; do
    # Check if vLLM is receiving traffic
    if [ -f "$LOG_FILE" ]; then
        LAST_REQUEST=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo "0")
        CURRENT=$(date +%s)
        IDLE=$(( (CURRENT - LAST_REQUEST) * 1000 ))
        
        if [ $IDLE -gt $IDLE_TIME_LIMIT ]; then
            echo "No activity for 30min, shutting down..."
            # Only shutdown if idle monitoring is enabled
            if [ -f /etc/kimi-auto-shutdown-enabled ]; then
                shutdown -h now
            fi
        fi
    fi
    sleep 60
done
EOF
chmod +x /usr/local/bin/kimi-auto-shutdown.sh

# Enable and start monitoring if requested
if [ "$ENABLE_AUTO_SHUTDOWN" = "true" ]; then
    log "Activating auto-shutdown..."
    touch /etc/kimi-auto-shutdown-enabled
    
    # Start activity tracker and shutdown monitor
    nohup /usr/local/bin/kimi-auto-shutdown.sh > /var/log/kimi-auto-shutdown.log 2>&1 &
    
    # Simple activity tracker: touches log file if docker logs show HTTP activity
    cat > /usr/local/bin/kimi-activity-tracker.sh << 'EOF'
#!/bin/bash
while true; do
    if docker ps | grep -q kimi-k25-server; then
        docker logs --since 1m kimi-k25-server 2>&1 | grep -q "HTTP" && touch /var/log/kimi-requests.log
    fi
    sleep 60
done
EOF
    chmod +x /usr/local/bin/kimi-activity-tracker.sh
    nohup /usr/local/bin/kimi-activity-tracker.sh > /dev/null 2>&1 &
fi

# =============================================================================
# Final Status
# =============================================================================
log "Setup complete!"
log ""
log "Useful commands:"
log "  - Check status:  kimi-status"
log "  - View logs:     kimi-logs"
log "  - Restart:       kimi-restart"
log "  - SSH access:    gcloud compute ssh $(hostname) --zone=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" | cut -d/ -f4)"
log ""
log "API will be available at: http://$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" -H "Metadata-Flavor: Google"):${API_PORT}/v1"
log ""
log "Note: First startup may take 5-10 minutes to download the model."

# Write completion marker
echo "$(date)" > /var/lib/kimi-setup-complete
