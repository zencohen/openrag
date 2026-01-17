#!/bin/bash
set -e

# OpenRAG GPU Node Manager
# Manages the on-demand GPU EC2 instance for indexing

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration (set these or use environment variables)
GPU_INSTANCE_ID="${GPU_INSTANCE_ID:-}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g4dn.xlarge}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CONFIG_FILE="${CONFIG_FILE:-/opt/openrag/.gpu-config}"

# Load config if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

print_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  start         Start the GPU node"
    echo "  stop          Stop the GPU node"
    echo "  status        Check GPU node status"
    echo "  wait          Wait for GPU node to be ready"
    echo "  ip            Get GPU node IP address"
    echo "  setup         Initial setup (create GPU instance)"
    echo "  process-queue Start GPU, process queue, then stop"
    echo ""
    echo "Options:"
    echo "  --instance-id ID    EC2 instance ID"
    echo "  --region REGION     AWS region"
    echo ""
    echo "Environment variables:"
    echo "  GPU_INSTANCE_ID     EC2 instance ID"
    echo "  AWS_REGION          AWS region (default: us-east-1)"
}

check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not installed. Install it first:"
        echo "  curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'"
        echo "  unzip awscliv2.zip && sudo ./aws/install"
        exit 1
    fi

    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS CLI not configured. Run: aws configure"
        exit 1
    fi
}

check_instance_id() {
    if [[ -z "$GPU_INSTANCE_ID" ]]; then
        log_error "GPU_INSTANCE_ID not set. Run '$0 setup' first or set the environment variable."
        exit 1
    fi
}

get_instance_state() {
    aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "unknown"
}

get_instance_ip() {
    aws ec2 describe-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null || echo ""
}

cmd_start() {
    check_aws_cli
    check_instance_id

    local state=$(get_instance_state)

    if [[ "$state" == "running" ]]; then
        log_info "GPU node is already running"
        local ip=$(get_instance_ip)
        log_success "GPU node IP: $ip"
        return 0
    fi

    log_info "Starting GPU node ($GPU_INSTANCE_ID)..."
    aws ec2 start-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" > /dev/null

    log_info "Waiting for instance to start..."
    aws ec2 wait instance-running \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION"

    local ip=$(get_instance_ip)
    log_success "GPU node started: $ip"

    # Update CPU node environment
    update_cpu_node_config "$ip"

    # Wait for services to be ready
    cmd_wait
}

cmd_stop() {
    check_aws_cli
    check_instance_id

    local state=$(get_instance_state)

    if [[ "$state" == "stopped" ]]; then
        log_info "GPU node is already stopped"
        return 0
    fi

    log_info "Stopping GPU node ($GPU_INSTANCE_ID)..."
    aws ec2 stop-instances \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION" > /dev/null

    log_info "Waiting for instance to stop..."
    aws ec2 wait instance-stopped \
        --instance-ids "$GPU_INSTANCE_ID" \
        --region "$AWS_REGION"

    log_success "GPU node stopped"

    # Clear GPU URL from CPU node
    update_cpu_node_config ""
}

cmd_status() {
    check_aws_cli
    check_instance_id

    local state=$(get_instance_state)
    local ip=$(get_instance_ip)

    echo "GPU Node Status"
    echo "==============="
    echo "Instance ID: $GPU_INSTANCE_ID"
    echo "Region:      $AWS_REGION"
    echo "State:       $state"
    echo "IP Address:  ${ip:-N/A}"

    if [[ "$state" == "running" ]] && [[ -n "$ip" ]]; then
        echo ""
        echo "Service Status:"
        if curl -sf "http://$ip:8080/health" > /dev/null 2>&1; then
            echo "  Health:    OK"
        else
            echo "  Health:    Not ready"
        fi
        if curl -sf "http://$ip:8000/health" > /dev/null 2>&1; then
            echo "  Embedder:  OK"
        else
            echo "  Embedder:  Not ready"
        fi
    fi
}

cmd_wait() {
    check_instance_id

    local ip=$(get_instance_ip)
    if [[ -z "$ip" ]]; then
        log_error "GPU node not running or no IP assigned"
        exit 1
    fi

    log_info "Waiting for GPU services to be ready..."
    local max_attempts=60
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf "http://$ip:8000/health" > /dev/null 2>&1; then
            log_success "GPU services ready!"
            return 0
        fi
        ((attempt++))
        echo -n "."
        sleep 10
    done

    echo ""
    log_error "GPU services did not become ready in time"
    exit 1
}

cmd_ip() {
    check_instance_id

    local ip=$(get_instance_ip)
    if [[ -n "$ip" ]]; then
        echo "$ip"
    else
        log_error "GPU node not running or no IP assigned"
        exit 1
    fi
}

cmd_setup() {
    check_aws_cli

    log_info "Setting up GPU node..."

    # Get CPU node's security group and subnet
    local cpu_instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")

    if [[ -z "$cpu_instance_id" ]]; then
        log_warn "Not running on EC2, you'll need to configure security groups manually"
    fi

    # Create GPU instance (if not exists)
    if [[ -n "$GPU_INSTANCE_ID" ]]; then
        log_info "GPU instance already configured: $GPU_INSTANCE_ID"
        return 0
    fi

    log_info "Creating GPU instance..."
    log_warn "This will create a new EC2 instance. Estimated cost: ~\$0.52/hour when running"

    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi

    # Get latest Deep Learning AMI
    local ami_id=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners amazon \
        --filters "Name=name,Values=Deep Learning AMI GPU PyTorch*Ubuntu 22.04*" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)

    if [[ -z "$ami_id" ]] || [[ "$ami_id" == "None" ]]; then
        # Fallback to Ubuntu 22.04
        ami_id=$(aws ec2 describe-images \
            --region "$AWS_REGION" \
            --owners 099720109477 \
            --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
            --output text)
    fi

    log_info "Using AMI: $ami_id"

    # Create the instance (stopped)
    GPU_INSTANCE_ID=$(aws ec2 run-instances \
        --region "$AWS_REGION" \
        --image-id "$ami_id" \
        --instance-type "$GPU_INSTANCE_TYPE" \
        --count 1 \
        --instance-initiated-shutdown-behavior stop \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openrag-gpu-node}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    # Immediately stop it (we don't need it running yet)
    aws ec2 stop-instances --instance-ids "$GPU_INSTANCE_ID" --region "$AWS_REGION" > /dev/null

    # Save configuration
    cat > "$CONFIG_FILE" << EOF
GPU_INSTANCE_ID=$GPU_INSTANCE_ID
AWS_REGION=$AWS_REGION
GPU_INSTANCE_TYPE=$GPU_INSTANCE_TYPE
EOF

    log_success "GPU instance created: $GPU_INSTANCE_ID"
    log_info "Configuration saved to: $CONFIG_FILE"
    log_warn "IMPORTANT: Configure security groups to allow traffic from CPU node"
    echo ""
    echo "Next steps:"
    echo "1. Configure security group to allow ports 8000, 7997, 8080 from CPU node"
    echo "2. SSH into GPU instance and run the GPU node setup"
    echo "3. Use '$0 start' to start the GPU node when needed"
}

cmd_process_queue() {
    log_info "Starting queue processing workflow..."

    # Start GPU node
    cmd_start

    # Wait for services
    cmd_wait

    local ip=$(get_instance_ip)
    log_info "GPU node ready at: $ip"

    # Trigger queue processing on CPU node
    log_info "Triggering queue processing..."
    curl -X POST "http://localhost:8080/indexer/process-queue" \
        -H "Authorization: Bearer ${AUTH_TOKEN:-}" \
        -H "Content-Type: application/json" || true

    # Wait for queue to be empty (with timeout)
    log_info "Waiting for indexing to complete..."
    local max_wait=3600  # 1 hour max
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local queue_size=$(curl -sf "http://localhost:8080/indexer/queue-status" 2>/dev/null | jq -r '.pending // 0')
        if [[ "$queue_size" == "0" ]]; then
            log_success "Queue processing complete!"
            break
        fi
        log_info "Queue size: $queue_size, waiting..."
        sleep 60
        ((waited += 60))
    done

    # Stop GPU node
    log_info "Stopping GPU node to save costs..."
    cmd_stop

    log_success "Queue processing workflow complete!"
}

update_cpu_node_config() {
    local gpu_ip="$1"

    if [[ -n "$gpu_ip" ]]; then
        log_info "Updating CPU node to use GPU at: $gpu_ip"
        export GPU_NODE_URL="http://$gpu_ip:8080"
    else
        log_info "Clearing GPU node configuration"
        unset GPU_NODE_URL
    fi

    # Update .env file if it exists
    local env_file="/opt/openrag/.env"
    if [[ -f "$env_file" ]]; then
        if [[ -n "$gpu_ip" ]]; then
            if grep -q "^GPU_NODE_URL=" "$env_file"; then
                sed -i "s|^GPU_NODE_URL=.*|GPU_NODE_URL=http://$gpu_ip:8080|" "$env_file"
            else
                echo "GPU_NODE_URL=http://$gpu_ip:8080" >> "$env_file"
            fi
        else
            sed -i '/^GPU_NODE_URL=/d' "$env_file"
        fi
    fi
}

# Parse arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case $1 in
        start|stop|status|wait|ip|setup|process-queue)
            COMMAND="$1"
            shift
            ;;
        --instance-id)
            GPU_INSTANCE_ID="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
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

# Execute command
case "$COMMAND" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    wait) cmd_wait ;;
    ip) cmd_ip ;;
    setup) cmd_setup ;;
    process-queue) cmd_process_queue ;;
    *)
        print_usage
        exit 1
        ;;
esac
