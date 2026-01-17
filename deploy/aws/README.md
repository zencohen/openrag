# OpenRAG Cloud Deployment - AWS EC2

Deploy your personal OpenRAG instance on AWS EC2 with GPU support for fast document processing and embeddings.

## Prerequisites

- AWS account with EC2 access
- Domain name (optional, for SSL)
- Anthropic API key from [console.anthropic.com](https://console.anthropic.com/)

## Quick Start

### 1. Launch an EC2 Instance

**Recommended Instance Types:**

| Instance Type | GPU | vCPU | RAM | Use Case |
|---------------|-----|------|-----|----------|
| `g4dn.xlarge` | 1x T4 (16GB) | 4 | 16GB | Personal use, small workloads |
| `g4dn.2xlarge` | 1x T4 (16GB) | 8 | 32GB | Medium workloads, faster indexing |
| `g5.xlarge` | 1x A10G (24GB) | 4 | 16GB | Better performance, larger models |

**AMI:** Ubuntu 22.04 LTS (or Amazon Linux 2)

**Storage:** At least 100GB gp3 (for models and data)

**Security Group:**
- SSH (22) - Your IP only
- HTTP (80) - 0.0.0.0/0
- HTTPS (443) - 0.0.0.0/0

### 2. Connect and Run Setup

```bash
# SSH into your instance
ssh -i your-key.pem ubuntu@your-instance-ip

# Clone OpenRAG
git clone https://github.com/linagora/openrag.git
cd openrag

# Run setup (with domain)
sudo ./deploy/aws/setup.sh --domain your-domain.com --email your@email.com

# Or without domain (self-signed cert)
sudo ./deploy/aws/setup.sh --skip-ssl
```

### 3. Configure Your API Keys

```bash
# Edit the environment file
sudo nano /opt/openrag/.env

# Add your Anthropic API key:
# API_KEY=sk-ant-your-key-here
# VLM_API_KEY=sk-ant-your-key-here
```

### 4. Start OpenRAG

```bash
cd /opt/openrag
sudo docker compose -f deploy/aws/docker-compose.cloud.yaml up -d

# Watch logs
sudo docker compose -f deploy/aws/docker-compose.cloud.yaml logs -f
```

### 5. Access Your Instance

- **Chat UI:** `https://your-domain.com/chat/`
- **Indexer UI:** `https://your-domain.com/indexer-ui/`
- **API:** `https://your-domain.com/api/`

## Architecture

```
                    ┌─────────────────┐
                    │   Internet      │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Nginx (SSL)    │
                    │  Port 443       │
                    └────────┬────────┘
         ┌───────────────────┼───────────────────┐
         │                   │                   │
    ┌────▼────┐        ┌─────▼─────┐      ┌─────▼─────┐
    │ OpenRAG │        │  Indexer  │      │  Chainlit │
    │   API   │        │    UI     │      │  Chat UI  │
    │  :8080  │        │   :3042   │      │   :8090   │
    └────┬────┘        └───────────┘      └───────────┘
         │
    ┌────┴────────────────────┐
    │                         │
┌───▼───┐  ┌────────┐  ┌──────▼──────┐
│ vLLM  │  │ Milvus │  │  PostgreSQL │
│(embed)│  │ (VDB)  │  │    (RDB)    │
└───────┘  └────────┘  └─────────────┘
```

## Security Configuration

### API Authentication

All API requests require a Bearer token:

```bash
curl -X POST https://your-domain.com/search \
  -H "Authorization: Bearer sk-openrag-your-token" \
  -H "Content-Type: application/json" \
  -d '{"query": "your search query"}'
```

### Firewall Rules

The setup script configures UFW with:
- SSH (22): Allowed
- HTTP (80): Allowed (redirects to HTTPS)
- HTTPS (443): Allowed

### SSL Certificates

- **With domain:** Automatic Let's Encrypt certificates
- **Without domain:** Self-signed certificates (browser warning)

## Claude Code Integration

See [mcp-server/README.md](mcp-server/README.md) for setting up the MCP server to connect Claude Code to your OpenRAG instance.

## Maintenance

### Backup Database

```bash
cd /opt/openrag
# Backup PostgreSQL
docker compose -f deploy/aws/docker-compose.cloud.yaml exec rdb pg_dump -U openrag openrag > backup_$(date +%Y%m%d).sql

# Backup Milvus
docker compose -f deploy/aws/docker-compose.cloud.yaml exec milvus milvus backup create
```

### Update OpenRAG

```bash
cd /opt/openrag
git pull
docker compose -f deploy/aws/docker-compose.cloud.yaml pull
docker compose -f deploy/aws/docker-compose.cloud.yaml up -d
```

### View Logs

```bash
cd /opt/openrag
# All services
docker compose -f deploy/aws/docker-compose.cloud.yaml logs -f

# Specific service
docker compose -f deploy/aws/docker-compose.cloud.yaml logs -f openrag
```

### Restart Services

```bash
cd /opt/openrag
docker compose -f deploy/aws/docker-compose.cloud.yaml restart
# Or specific service
docker compose -f deploy/aws/docker-compose.cloud.yaml restart openrag
```

## Troubleshooting

### GPU Not Detected

```bash
# Check NVIDIA driver
nvidia-smi

# If not working, reinstall
sudo apt install --reinstall nvidia-driver-535
sudo reboot
```

### Services Not Starting

```bash
cd /opt/openrag
# Check status
docker compose -f deploy/aws/docker-compose.cloud.yaml ps

# Check specific logs
docker compose -f deploy/aws/docker-compose.cloud.yaml logs openrag
docker compose -f deploy/aws/docker-compose.cloud.yaml logs vllm-gpu
docker compose -f deploy/aws/docker-compose.cloud.yaml logs milvus
```

### Out of GPU Memory

Edit `/opt/openrag/.env`:
```bash
# Reduce GPU memory usage
RAY_NUM_GPUS=0.3
```

Then restart: `cd /opt/openrag && docker compose -f deploy/aws/docker-compose.cloud.yaml restart openrag`

## Cost Optimization

### Auto-Stop Script

Create `/opt/openrag/auto-stop.sh`:
```bash
#!/bin/bash
# Stop instance if idle for 2 hours
IDLE_THRESHOLD=7200

last_request=$(stat -c %Y /opt/openrag/logs/access.log 2>/dev/null || echo 0)
now=$(date +%s)
idle=$((now - last_request))

if [ $idle -gt $IDLE_THRESHOLD ]; then
    aws ec2 stop-instances --instance-ids $(curl -s http://169.254.169.254/latest/meta-data/instance-id)
fi
```

Add to crontab: `*/30 * * * * /opt/openrag/auto-stop.sh`

### Spot Instances

For non-critical personal use, consider using Spot Instances:
- `g4dn.xlarge` Spot: ~$0.15/hour vs $0.52/hour On-Demand
- Use persistent Spot requests with stop behavior

## Security Testing

Run security tests to verify your deployment:

```bash
# Pre-deployment: Verify configuration files
./deploy/aws/security-tests/verify-config.sh

# Post-deployment: Full security scan
./deploy/aws/security-tests/run-security-tests.sh \
    --url https://your-domain.com \
    --token sk-openrag-your-token
```

See [security-tests/README.md](security-tests/README.md) for details on:
- SSL/TLS testing with testssl.sh
- Container scanning with Trivy
- System auditing with Lynis
- API security testing

## Files Reference

```
deploy/aws/
├── docker-compose.cloud.yaml  # Docker Compose for cloud
├── nginx.conf                 # Nginx reverse proxy config
├── setup.sh                   # Automated setup script
├── .env.example               # Environment template
├── mcp-server/                # Claude Code MCP integration
│   ├── openrag-mcp-server.py
│   ├── config.json
│   └── requirements.txt
├── security-tests/            # Security testing suite
│   ├── run-security-tests.sh  # Full security scan
│   ├── verify-config.sh       # Pre-deployment check
│   └── README.md              # Security test docs
└── README.md                  # This file
```
