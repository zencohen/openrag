# OpenRAG Serverless Architecture

Cost-optimized deployment using managed services and on-demand EC2 Spot instances.

**Cost: ~$10-30/month** for daily use (vs ~$400/month always-on)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  FREE TIER (Always Available)                                       │
│                                                                     │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐              │
│  │   Zilliz    │   │    Neon     │   │   Lambda    │              │
│  │   Cloud     │   │  PostgreSQL │   │   + API GW  │              │
│  │  (Milvus)   │   │   (Free)    │   │   (Free)    │              │
│  │  100K vec   │   │   0.5GB     │   │   Wake Fn   │              │
│  └─────────────┘   └─────────────┘   └─────────────┘              │
│         │                 │                 │                      │
│         └─────────────────┴─────────────────┘                      │
│                           │                                         │
│                    Request arrives                                  │
│                           │                                         │
│                           ▼                                         │
│              ┌────────────────────────┐                            │
│              │  Lambda wakes EC2 Spot │                            │
│              └────────────────────────┘                            │
└─────────────────────────────────────────────────────────────────────┘
                            │
                            ▼ (2-3 min cold start)
┌─────────────────────────────────────────────────────────────────────┐
│  EC2 SPOT (On-Demand, ~$0.15/hour)                                 │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │   OpenRAG    │  │    vLLM      │  │   Reranker   │             │
│  │     API      │  │   Embedder   │  │   (GPU)      │             │
│  └──────────────┘  └──────────────┘  └──────────────┘             │
│                           │                                         │
│              Auto-stops after 15min idle                           │
└─────────────────────────────────────────────────────────────────────┘
```

## Setup Guide

### Step 1: Create Free Tier Accounts

#### Zilliz Cloud (Managed Milvus)

1. Sign up at [cloud.zilliz.com](https://cloud.zilliz.com/)
2. Create a free cluster:
   - Click "Create Cluster"
   - Select "Free" tier (100K vectors, 2 collections)
   - Choose region closest to your EC2 (e.g., `us-west-2`)
3. Note your connection details:
   - Endpoint: `xxx.api.gcp-us-west1.zillizcloud.com`
   - API Key: Generate in "API Keys" section

#### Neon PostgreSQL

1. Sign up at [neon.tech](https://neon.tech/)
2. Create a free project:
   - Click "New Project"
   - Name it `openrag`
3. Note your connection details:
   - Host: `ep-xxx-xxx-123456.us-east-1.aws.neon.tech`
   - User/Password from connection string

### Step 2: Create EC2 Spot Instance

```bash
# Create a Spot instance request
aws ec2 run-instances \
    --image-id ami-0c7217cdde317cfec \  # Ubuntu 22.04
    --instance-type g4dn.xlarge \
    --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}' \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=openrag-serverless}]' \
    --iam-instance-profile Name=openrag-ec2-role \
    --user-data file://setup-ec2.sh

# Note the instance ID
```

### Step 3: Configure the Environment

```bash
# SSH into your EC2 instance
ssh -i your-key.pem ubuntu@<instance-ip>

# Clone OpenRAG
git clone https://github.com/linagora/openrag.git
cd openrag/deploy/aws/serverless

# Copy and edit environment file
cp .env.serverless.example .env
nano .env
```

Fill in your credentials:
```bash
# Zilliz
VDB_HOST=your-cluster.api.gcp-us-west1.zillizcloud.com
ZILLIZ_API_KEY=your-api-key

# Neon
POSTGRES_HOST=ep-xxx.us-east-1.aws.neon.tech
POSTGRES_USER=your-user
POSTGRES_PASSWORD=your-password

# Anthropic
API_KEY=sk-ant-your-key
```

### Step 4: Deploy Lambda Wake Function

```bash
# Install SAM CLI
pip install aws-sam-cli

# Deploy the Lambda function
cd lambda
sam build
sam deploy --guided \
    --stack-name openrag-wake \
    --parameter-overrides EC2InstanceId=i-xxxxx
```

Note your API Gateway URL from the output.

### Step 5: Test the Setup

```bash
# Wake the instance via Lambda
curl -X POST https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/wake

# Wait for response (may take 2-3 minutes on cold start)
# Response: {"status": "ready", "ip": "x.x.x.x"}

# Access OpenRAG
curl http://<instance-ip>:8080/health
```

### Step 6: (Optional) Cloudflare Tunnel for Free HTTPS

1. Sign up at [dash.cloudflare.com](https://dash.cloudflare.com/)
2. Go to "Zero Trust" > "Tunnels"
3. Create a tunnel named `openrag`
4. Copy the tunnel token
5. Add to `.env`:
   ```
   CLOUDFLARE_TUNNEL_TOKEN=your-token
   ```
6. Start with Cloudflare:
   ```bash
   docker compose -f docker-compose.serverless.yaml --profile cloudflare up -d
   ```

## Usage

### Wake OpenRAG (Cold Start: ~2-3 min)

```bash
# Via Lambda API
curl -X POST https://your-api-gateway-url/prod/wake

# Or directly start EC2
aws ec2 start-instances --instance-ids i-xxxxx
```

### Access Services

Once running, access at:
- **Chat UI**: `http://<ip>:8080/` (or via Cloudflare Tunnel)
- **Indexer UI**: `http://<ip>:3042/`
- **API**: `http://<ip>:8080/api/`

### Auto-Stop

The instance automatically stops after 15 minutes of inactivity.

To change the idle threshold, edit `.env`:
```bash
AUTO_STOP_IDLE_SECONDS=1800  # 30 minutes
```

### Manual Stop

```bash
aws ec2 stop-instances --instance-ids i-xxxxx
```

## Claude Code Integration

Configure your MCP server to use the Lambda wake endpoint:

```json
{
  "mcpServers": {
    "openrag": {
      "command": "python",
      "args": ["/path/to/openrag-mcp-server.py"],
      "env": {
        "OPENRAG_WAKE_URL": "https://your-api-gateway/prod/wake",
        "OPENRAG_URL": "http://your-ec2-ip:8080",
        "OPENRAG_API_TOKEN": "sk-openrag-your-token"
      }
    }
  }
}
```

The MCP server will automatically wake OpenRAG when you query it.

## Cost Breakdown

| Component | Monthly Cost |
|-----------|--------------|
| Zilliz Cloud Free | $0 |
| Neon PostgreSQL Free | $0 |
| Lambda + API Gateway | ~$0 (free tier) |
| EC2 Spot (2hr/day) | ~$9 |
| EBS Storage (100GB) | ~$8 |
| Data Transfer | ~$2 |
| **Total** | **~$19/month** |

## Troubleshooting

### Cold Start Too Slow

The 2-3 minute cold start is mostly vLLM loading the model. To speed up:

1. **Use smaller embedding model**: Change `EMBEDDER_MODEL_NAME` to a smaller model
2. **Pre-warm**: Schedule Lambda to wake instance before your typical usage time
3. **Keep running during work hours**: Set `AUTO_STOP_IDLE_SECONDS=14400` (4 hours)

### Spot Interruption

Spot instances can be interrupted (rare for g4dn). To handle:

1. Use "persistent" Spot request (already configured)
2. Data is safe in Zilliz/Neon (managed services)
3. Instance auto-restarts when capacity available

### Zilliz Connection Issues

```bash
# Test Zilliz connection
curl -X POST "https://your-cluster.api.gcp-us-west1.zillizcloud.com/v1/vector/collections" \
    -H "Authorization: Bearer your-api-key" \
    -H "Content-Type: application/json"
```

### Neon Connection Issues

```bash
# Test Neon connection
psql "postgresql://user:password@ep-xxx.us-east-1.aws.neon.tech/openrag?sslmode=require"
```

## Files Reference

```
deploy/aws/serverless/
├── docker-compose.serverless.yaml   # EC2 Spot services
├── .env.serverless.example          # Environment template
├── scripts/
│   └── auto-stop-monitor.sh         # Idle shutdown script
├── lambda/
│   ├── template.yaml                # SAM deployment
│   └── wake-openrag/
│       └── index.py                 # Lambda function
└── README.md                        # This file
```
