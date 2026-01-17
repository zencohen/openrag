#!/bin/bash
set -e

# OpenRAG Cloud Deployment Setup Script for AWS EC2
# This script automates the deployment of OpenRAG on an AWS EC2 instance with GPU

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
DEPLOY_DIR="/opt/openrag"
DOMAIN=""
EMAIL=""
SKIP_SSL=false

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║     OpenRAG Cloud Deployment - AWS EC2 Setup              ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --domain DOMAIN    Domain name for SSL certificate"
    echo "  -e, --email EMAIL      Email for Let's Encrypt notifications"
    echo "  --skip-ssl             Skip SSL setup (use self-signed cert)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --domain openrag.example.com --email admin@example.com"
    echo "  $0 --skip-ssl  # For testing without a domain"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -e|--email)
                EMAIL="$2"
                shift 2
                ;;
            --skip-ssl)
                SKIP_SSL=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_gpu() {
    log_info "Checking for NVIDIA GPU..."
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
        log_success "NVIDIA GPU detected"
        return 0
    else
        log_warn "No NVIDIA GPU detected. Will attempt to install drivers."
        return 1
    fi
}

install_dependencies() {
    log_info "Installing system dependencies..."

    # Update system
    apt-get update -y
    apt-get upgrade -y

    # Install required packages
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        git \
        jq \
        openssl \
        ufw

    log_success "System dependencies installed"
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker already installed: $(docker --version)"
        return 0
    fi

    log_info "Installing Docker..."

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add the repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Start and enable Docker
    systemctl start docker
    systemctl enable docker

    log_success "Docker installed: $(docker --version)"
}

install_nvidia_drivers() {
    if command -v nvidia-smi &> /dev/null; then
        log_info "NVIDIA drivers already installed"
        return 0
    fi

    log_info "Installing NVIDIA drivers and container toolkit..."

    # Install NVIDIA driver
    apt-get install -y nvidia-driver-535

    # Add NVIDIA Container Toolkit repository
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -y
    apt-get install -y nvidia-container-toolkit

    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    log_success "NVIDIA drivers and container toolkit installed"
    log_warn "A reboot may be required for GPU to be fully available"
}

setup_firewall() {
    log_info "Configuring firewall..."

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp    # HTTP
    ufw allow 443/tcp   # HTTPS

    # Enable firewall if not already enabled
    echo "y" | ufw enable

    log_success "Firewall configured"
}

setup_deploy_directory() {
    log_info "Setting up deployment directory..."

    # Get the repo root directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

    # Create symlink to repo or copy repo
    if [[ -d "$REPO_DIR/.git" ]]; then
        # We're running from within the repo
        if [[ "$REPO_DIR" != "$DEPLOY_DIR" ]]; then
            mkdir -p "$(dirname $DEPLOY_DIR)"
            if [[ -L "$DEPLOY_DIR" ]]; then
                rm "$DEPLOY_DIR"
            fi
            ln -sf "$REPO_DIR" "$DEPLOY_DIR"
        fi
    else
        # Clone fresh copy if not in repo
        if [[ ! -d "$DEPLOY_DIR" ]]; then
            git clone https://github.com/linagora/openrag.git "$DEPLOY_DIR"
        fi
    fi

    cd "$DEPLOY_DIR"

    # Create required directories
    mkdir -p ssl data logs volumes

    # Copy nginx config to deploy location
    cp "$DEPLOY_DIR/deploy/aws/nginx.conf" "$DEPLOY_DIR/nginx.conf" 2>/dev/null || true

    log_success "Deployment directory ready at $DEPLOY_DIR"
}

generate_self_signed_cert() {
    log_info "Generating self-signed SSL certificate..."

    mkdir -p "$DEPLOY_DIR/ssl/live/openrag"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$DEPLOY_DIR/ssl/live/openrag/privkey.pem" \
        -out "$DEPLOY_DIR/ssl/live/openrag/fullchain.pem" \
        -subj "/CN=${DOMAIN:-localhost}/O=OpenRAG/C=US"

    log_success "Self-signed certificate generated"
}

setup_letsencrypt() {
    if [[ -z "$DOMAIN" ]] || [[ -z "$EMAIL" ]]; then
        log_warn "Domain or email not provided, skipping Let's Encrypt setup"
        generate_self_signed_cert
        return
    fi

    log_info "Setting up Let's Encrypt SSL certificate for $DOMAIN..."

    # Create temporary nginx config for ACME challenge
    cat > "$DEPLOY_DIR/nginx-temp.conf" << 'NGINX_TEMP'
events { worker_connections 1024; }
http {
    server {
        listen 80;
        server_name _;
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 200 'OpenRAG Setup'; }
    }
}
NGINX_TEMP

    # Start temporary nginx
    docker run -d --name nginx-temp \
        -p 80:80 \
        -v "$DEPLOY_DIR/nginx-temp.conf:/etc/nginx/nginx.conf:ro" \
        -v "$DEPLOY_DIR/ssl/webroot:/var/www/certbot" \
        nginx:alpine

    sleep 5

    # Get certificate
    docker run --rm \
        -v "$DEPLOY_DIR/ssl:/etc/letsencrypt" \
        -v "$DEPLOY_DIR/ssl/webroot:/var/www/certbot" \
        certbot/certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$DOMAIN"

    # Stop temporary nginx
    docker stop nginx-temp
    docker rm nginx-temp
    rm "$DEPLOY_DIR/nginx-temp.conf"

    # Create symlink for consistent path
    mkdir -p "$DEPLOY_DIR/ssl/live/openrag"
    ln -sf "$DEPLOY_DIR/ssl/live/$DOMAIN/fullchain.pem" "$DEPLOY_DIR/ssl/live/openrag/fullchain.pem"
    ln -sf "$DEPLOY_DIR/ssl/live/$DOMAIN/privkey.pem" "$DEPLOY_DIR/ssl/live/openrag/privkey.pem"

    log_success "SSL certificate obtained for $DOMAIN"
}

create_env_file() {
    log_info "Creating environment configuration..."

    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        log_warn ".env file already exists, backing up..."
        cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/.env.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Generate secure passwords
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    AUTH_TOKEN="sk-openrag-$(openssl rand -hex 16)"

    # Determine external URL
    if [[ -n "$DOMAIN" ]]; then
        EXTERNAL_URL="https://$DOMAIN"
    else
        PUBLIC_IP=$(curl -s http://checkip.amazonaws.com || echo "localhost")
        EXTERNAL_URL="https://$PUBLIC_IP"
    fi

    cat > "$DEPLOY_DIR/.env" << ENV_FILE
# OpenRAG Cloud Deployment Configuration
# Generated on $(date)

# ============================================
# LLM Configuration (Anthropic Claude)
# ============================================
# IMPORTANT: Add your Anthropic API key here
# Get it from: https://console.anthropic.com/
BASE_URL=https://api.anthropic.com/v1
API_KEY=REPLACE_WITH_YOUR_ANTHROPIC_API_KEY
MODEL=claude-sonnet-4-20250514

VLM_BASE_URL=https://api.anthropic.com/v1
VLM_API_KEY=REPLACE_WITH_YOUR_ANTHROPIC_API_KEY
VLM_MODEL=claude-sonnet-4-20250514

# ============================================
# Security (Auto-generated - keep these secret!)
# ============================================
AUTH_TOKEN=$AUTH_TOKEN
POSTGRES_USER=openrag
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=openrag

# ============================================
# External Access
# ============================================
EXTERNAL_URL=$EXTERNAL_URL
INCLUDE_CREDENTIALS=true

# ============================================
# Embedder
# ============================================
EMBEDDER_MODEL_NAME=jinaai/jina-embeddings-v3
EMBEDDER_BASE_URL=http://vllm:8000/v1
EMBEDDER_API_KEY=EMPTY
MAX_MODEL_LEN=8192

# ============================================
# Reranker
# ============================================
RERANKER_ENABLED=true
RERANKER_MODEL=Alibaba-NLP/gte-multilingual-reranker-base

# ============================================
# Features
# ============================================
WITH_CHAINLIT_UI=true
CHAINLIT_PORT=8090
PDFLoader=MarkerLoader
IMAGE_CAPTIONING=true
SAVE_UPLOADED_FILES=true

# ============================================
# Ray
# ============================================
RAY_DEDUP_LOGS=0
RAY_ENABLE_RECORD_ACTOR_TASK_LOGGING=1
RAY_task_retry_delay_ms=3000
RAY_ENABLE_UV_RUN_RUNTIME_ENV=0
RAY_NUM_GPUS=0.5

# ============================================
# Logging
# ============================================
LOG_LEVEL=INFO

# ============================================
# Prompts
# ============================================
PROMPTS_DIR=../prompts/example1
ENV_FILE

    chmod 600 "$DEPLOY_DIR/.env"
    log_success "Environment file created"
    log_warn "IMPORTANT: Edit $DEPLOY_DIR/.env and add your Anthropic API key!"
}

create_systemd_service() {
    log_info "Creating systemd service for auto-start..."

    cat > /etc/systemd/system/openrag.service << SERVICE
[Unit]
Description=OpenRAG RAG Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DEPLOY_DIR
ExecStart=/usr/bin/docker compose -f deploy/aws/docker-compose.cloud.yaml up -d
ExecStop=/usr/bin/docker compose -f deploy/aws/docker-compose.cloud.yaml down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable openrag.service

    log_success "Systemd service created and enabled"
}

print_summary() {
    PUBLIC_IP=$(curl -s http://checkip.amazonaws.com || echo "your-server-ip")

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          OpenRAG Deployment Complete!                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo ""
    echo "1. Edit the environment file with your Anthropic API key:"
    echo "   ${YELLOW}sudo nano $DEPLOY_DIR/.env${NC}"
    echo ""
    echo "2. Start OpenRAG:"
    echo "   ${YELLOW}cd $DEPLOY_DIR && sudo docker compose -f deploy/aws/docker-compose.cloud.yaml up -d${NC}"
    echo ""
    echo "3. Check service status:"
    echo "   ${YELLOW}cd $DEPLOY_DIR && sudo docker compose -f deploy/aws/docker-compose.cloud.yaml ps${NC}"
    echo "   ${YELLOW}cd $DEPLOY_DIR && sudo docker compose -f deploy/aws/docker-compose.cloud.yaml logs -f openrag${NC}"
    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    if [[ -n "$DOMAIN" ]]; then
        echo "   Chat UI:     https://$DOMAIN/chat/"
        echo "   Indexer UI:  https://$DOMAIN/indexer-ui/"
        echo "   API:         https://$DOMAIN/api/"
        echo "   Search API:  https://$DOMAIN/search"
    else
        echo "   Chat UI:     https://$PUBLIC_IP/chat/"
        echo "   Indexer UI:  https://$PUBLIC_IP/indexer-ui/"
        echo "   API:         https://$PUBLIC_IP/api/"
        echo "   Search API:  https://$PUBLIC_IP/search"
    fi
    echo ""
    echo -e "${BLUE}Authentication:${NC}"
    echo "   Your API token is in: $DEPLOY_DIR/.env"
    echo "   Use header: Authorization: Bearer \$AUTH_TOKEN"
    echo ""
    echo -e "${BLUE}Claude Code MCP Integration:${NC}"
    echo "   See: deploy/aws/mcp-server/README.md"
    echo ""
    echo -e "${YELLOW}Security Reminder:${NC}"
    echo "   - Keep your .env file secure (chmod 600)"
    echo "   - Change the AUTH_TOKEN if you suspect it's compromised"
    echo "   - Regular backups: docker compose exec rdb pg_dump -U openrag openrag > backup.sql"
    echo ""
}

# Main execution
main() {
    print_banner
    parse_args "$@"

    check_root

    log_info "Starting OpenRAG cloud deployment..."

    install_dependencies
    install_docker

    if ! check_gpu; then
        install_nvidia_drivers
    fi

    setup_firewall
    setup_deploy_directory

    if [[ "$SKIP_SSL" == "true" ]]; then
        generate_self_signed_cert
    else
        setup_letsencrypt
    fi

    create_env_file
    create_systemd_service

    print_summary
}

main "$@"
