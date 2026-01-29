# Handoff: LightRAG Serverless Cloud Deployment

> **For**: Engineering implementation
> **From**: Claude (AI-assisted planning session)
> **Date**: 2026-01-29
> **Status**: READY FOR IMPLEMENTATION
> **Trust Level**: AI-generated, human-reviewed
> **Tags**: #lightrag #serverless #aws #deployment #claude-integration

---

## Summary

Deploy a personal LightRAG instance using serverless architecture for ~$7-25/month (vs ~$400/month always-on GPU). LightRAG is a graph-enhanced RAG framework that doesn't require GPU, making it ideal for cost-optimized cloud deployment. Uses Anthropic Claude for LLM, Voyage AI for embeddings, Neon PostgreSQL (free tier) for all storage, and AWS Fargate for on-demand compute.

**Key insight**: LightRAG can use PostgreSQL for everything (KV storage, vectors via pgvector, graph storage), enabling a single managed database to replace multiple services.

---

## Context Links

### Strategy
- **User goal**: Personal RAG system accessible from anywhere, integrated with Claude Code
- **Cost target**: ~$10-30/month for regular daily use
- **Previous work**: OpenRAG deployment explored but pivoted to LightRAG (no GPU requirement)

### Technical References
- **LightRAG repo**: https://github.com/HKUDS/LightRAG — official source
- **LightRAG docs**: https://lightrag.github.io/ — deployment guides
- **Docker image**: `ghcr.io/hkuds/lightrag:latest` — official container

### External Services (accounts needed)
- **Anthropic**: https://console.anthropic.com/ — Claude API key
- **Voyage AI**: https://www.voyageai.com/ — Embeddings (50M free tokens/month)
- **Neon**: https://neon.tech/ — PostgreSQL (0.5GB free tier)
- **AWS**: Fargate, API Gateway, ECR

### People
- **User**: @zencohen — project owner, will use with Claude Code/Cowork
- **Ground Truth**: This planning session (current conversation)

---

## Current State

### What Exists
- LightRAG is a mature open-source project with Docker support
- Official image available: `ghcr.io/hkuds/lightrag:latest`
- Full Anthropic Claude integration via `LLM_BINDING=anthropic`
- PostgreSQL backend supports all storage types (KV, vector, graph)
- WebUI included (React 19 + TypeScript)
- REST API on port 9621

### What's Needed
- [ ] Serverless deployment configuration for AWS Fargate
- [ ] Environment configuration for Claude + Voyage AI + Neon
- [ ] Auto-scaling (scale to zero when idle)
- [ ] MCP server for Claude Code integration
- [ ] Setup documentation

### Partial Work Done
- `deploy/serverless/.env.example` created with configuration template
- Committed to branch `claude/deploy-openrag-cloud-4OUvE`

---

## Journey

### How We Got Here
1. **Started**: User wanted personal OpenRAG cloud deployment
2. **Explored**: Created full OpenRAG deployment with GPU (g4dn.xlarge)
3. **Concern**: Cost too high (~$400/month always-on)
4. **Pivoted**: Designed serverless architecture with EC2 Spot on-demand
5. **Pivoted again**: User chose LightRAG over OpenRAG
6. **Why LightRAG**: No GPU required, simpler architecture, lower cost

### Key Decisions Made
| Decision | Rationale |
|----------|-----------|
| LightRAG over OpenRAG | No GPU needed = much cheaper instances |
| Voyage AI for embeddings | Claude doesn't offer embeddings; Voyage has 50M free tokens |
| Neon PostgreSQL | Free tier, supports pgvector, handles all storage needs |
| AWS Fargate | Serverless containers, scales to zero, simpler than EC2 Spot |
| Include WebUI | User confirmed they want the React WebUI |
| us-east-1 region | Closest to Neon's default region |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  FREE TIER (Always Available)                                    │
│                                                                  │
│  ┌─────────────────┐         ┌─────────────────┐                │
│  │ Neon PostgreSQL │         │  API Gateway    │                │
│  │ (Free: 0.5GB)   │         │  (Free Tier)    │                │
│  │ • pgvector      │         │                 │                │
│  │ • KV storage    │         │                 │                │
│  │ • Graph storage │         │                 │                │
│  └─────────────────┘         └─────────────────┘                │
│           │                          │                          │
│           └──────────────────────────┘                          │
│                       │                                          │
│              Triggers Fargate on request                         │
└──────────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│  ON-DEMAND (Pay-per-use)                                        │
│                                                                  │
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │   Fargate Task  │    │ External APIs   │                    │
│  │   (LightRAG)    │───▶│ • Claude API    │                    │
│  │   ~$0.04/hr     │    │ • Voyage AI     │                    │
│  └─────────────────┘    └─────────────────┘                    │
│                                                                  │
│  Auto-scales to zero when idle                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Open Questions

- **[?] Fargate cold start time**: Need to test — expect 30-60 seconds
- **[?] Neon connection limits**: Free tier may have limits on concurrent connections
- **[?] WebUI static hosting**: Should we serve WebUI from S3/CloudFront for faster load?
- **[?] Custom domain**: Does user want a custom domain or is API Gateway URL sufficient?

---

## Implementation Plan

### Phase 1: Create Core Deployment Files
**Goal**: Working local deployment connecting to managed services

1. Create `deploy/serverless/docker-compose.yaml`
   - Use `ghcr.io/hkuds/lightrag:latest`
   - Configure for Neon PostgreSQL connection
   - Include WebUI

2. Complete `deploy/serverless/.env.example`
   - All LightRAG environment variables
   - Claude + Voyage AI configuration
   - Neon PostgreSQL connection

3. Create `deploy/serverless/scripts/setup-neon.sh`
   - Initialize Neon database
   - Enable pgvector extension
   - Create required tables (if needed)

**Verify**: `docker compose up` connects to Neon and serves API on :9621

### Phase 2: AWS Fargate Deployment
**Goal**: Serverless deployment with auto-scaling

1. Create `deploy/serverless/aws/template.yaml` (SAM)
   - Fargate task definition
   - API Gateway HTTP API
   - Auto-scaling configuration (min: 0, max: 2)
   - VPC configuration for Neon connection
   - Secrets Manager for API keys

2. Create `deploy/serverless/aws/Dockerfile` (if customization needed)

3. Create `deploy/serverless/scripts/deploy-aws.sh`
   - SAM build and deploy
   - Output API Gateway URL

**Verify**: API Gateway endpoint responds, scales to zero after idle

### Phase 3: Claude Code Integration
**Goal**: MCP server for Claude Code to query LightRAG

1. Create `deploy/serverless/mcp-server/lightrag-mcp.py`
   - Tools: `query`, `search`, `upload_document`, `list_documents`
   - Handle wake-on-demand if Fargate task is stopped

2. Create MCP configuration example
   - `claude_desktop_config.json` snippet

**Verify**: Claude Code can query "Search my LightRAG for X"

### Phase 4: Documentation
1. Create `deploy/serverless/README.md`
   - Architecture diagram
   - Setup guide (Neon, Voyage AI, Claude)
   - Deployment instructions
   - Cost breakdown
   - Troubleshooting

---

## Files to Create

| File | Purpose |
|------|---------|
| `deploy/serverless/docker-compose.yaml` | Local testing with managed services |
| `deploy/serverless/.env.example` | Configuration template (partially done) |
| `deploy/serverless/aws/template.yaml` | SAM template for Fargate |
| `deploy/serverless/scripts/setup-neon.sh` | Initialize Neon database |
| `deploy/serverless/scripts/deploy-aws.sh` | One-command AWS deployment |
| `deploy/serverless/mcp-server/lightrag-mcp.py` | Claude Code MCP server |
| `deploy/serverless/mcp-server/requirements.txt` | MCP dependencies |
| `deploy/serverless/README.md` | Documentation |

---

## Success Criteria

- [ ] Local deployment works with `docker compose up`
- [ ] Connects to Neon PostgreSQL successfully
- [ ] Can upload a document via API
- [ ] Can query and get responses using Claude
- [ ] AWS deployment succeeds with `deploy-aws.sh`
- [ ] Fargate scales to zero after 15 minutes idle
- [ ] Claude Code can query via MCP server
- [ ] Total monthly cost <$30 for daily use

---

## Escape Hatches

| Situation | Action |
|-----------|--------|
| **Neon connection issues** | Check SSL mode (`require`), verify connection string, test with `psql` |
| **Voyage AI rate limits** | Check free tier limits, consider caching embeddings |
| **Fargate won't scale to zero** | Check Application Auto Scaling configuration, min capacity must be 0 |
| **Cold start too slow** | Consider provisioned capacity or Lambda@Edge for wake |
| **LightRAG errors** | Check `/health` endpoint, review container logs |
| **Blocked on architecture** | Ask @zencohen for requirements clarification |
| **Cost exceeding target** | Review CloudWatch metrics, optimize Fargate task size |

---

## Cost Breakdown

| Component | Monthly Cost |
|-----------|--------------|
| Neon PostgreSQL | $0 (free tier: 0.5GB) |
| Voyage AI embeddings | $0-5 (50M free tokens + overflow) |
| Claude API | $5-15 (depends on query volume) |
| Fargate compute | $2-5 (on-demand, ~2hr/day) |
| API Gateway | $0-1 (1M requests free) |
| **Total** | **~$7-25/month** |

---

## Next Actions

- [ ] **Phase 1**: Create docker-compose.yaml — implementer
- [ ] **Phase 1**: Complete .env.example — implementer
- [ ] **Phase 1**: Create setup-neon.sh — implementer
- [ ] **Phase 2**: Create SAM template — implementer
- [ ] **Phase 2**: Create deploy script — implementer
- [ ] **Phase 3**: Create MCP server — implementer
- [ ] **Phase 4**: Write README — implementer
- [ ] **Final**: Test end-to-end and document issues — implementer

---

## Key LightRAG Configuration

### Environment Variables (Essential)

```bash
# LLM
LLM_BINDING=anthropic
ANTHROPIC_API_KEY=sk-ant-xxx
LLM_MODEL=claude-sonnet-4-20250514

# Embeddings
EMBEDDING_BINDING=voyage
VOYAGE_API_KEY=pa-xxx
EMBEDDING_MODEL=voyage-3-large
EMBEDDING_DIM=1024

# Storage (all PostgreSQL)
KV_STORAGE=PGKVStorage
VECTOR_STORAGE=PGVectorStorage
GRAPH_STORAGE=PGGraphStorage
DOC_STATUS_STORAGE=PGDocStatusStorage

# Neon PostgreSQL
POSTGRES_HOST=ep-xxx.us-east-1.aws.neon.tech
POSTGRES_PORT=5432
POSTGRES_USER=xxx
POSTGRES_PASSWORD=xxx
POSTGRES_DATABASE=lightrag
POSTGRES_SSL_MODE=require

# Server
PORT=9621
LIGHTRAG_API_KEY=sk-lightrag-xxx
```

### API Endpoints (Key ones)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Health check |
| `/query` | POST | Query with RAG |
| `/query/stream` | POST | Streaming query |
| `/documents/upload` | POST | Upload document |
| `/documents/text` | POST | Insert text |
| `/documents/list` | GET | List documents |
| `/graph/label/list` | GET | List graph entities |

---

## Ground Truth References

- **LightRAG GitHub**: https://github.com/HKUDS/LightRAG
- **This planning session**: Conversation with @zencohen on 2026-01-29
- **Previous OpenRAG work**: Branch `claude/deploy-openrag-cloud-4OUvE`

---

*Handoff generated by Claude. Verify technical details against LightRAG documentation before implementation.*

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  FREE TIER (Always Available)                                    │
│                                                                  │
│  ┌─────────────────┐         ┌─────────────────┐                │
│  │ Neon PostgreSQL │         │  API Gateway    │                │
│  │ (Free: 0.5GB)   │         │  (Free Tier)    │                │
│  │ • pgvector      │         │                 │                │
│  │ • KV storage    │         │                 │                │
│  │ • Graph storage │         │                 │                │
│  └─────────────────┘         └─────────────────┘                │
│           │                          │                          │
│           └──────────────────────────┘                          │
│                       │                                          │
│              Triggers on request                                 │
└──────────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│  ON-DEMAND (Pay-per-use)                                        │
│                                                                  │
│  ┌─────────────────┐    ┌─────────────────┐                    │
│  │   Fargate Task  │    │ External APIs   │                    │
│  │   (LightRAG)    │───▶│ • Claude API    │                    │
│  │   ~$0.04/hr     │    │ • Voyage AI     │                    │
│  └─────────────────┘    └─────────────────┘                    │
│                                                                  │
│  Auto-scales to zero when idle                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Files to Create

### 1. Environment Configuration
**File**: `deploy/serverless/.env.example`
```
# LLM (Claude)
LLM_BINDING=anthropic
ANTHROPIC_API_KEY=sk-ant-xxx
LLM_MODEL=claude-sonnet-4-20250514

# Embeddings (Voyage AI - required)
EMBEDDING_BINDING=voyage
VOYAGE_API_KEY=pa-xxx
EMBEDDING_MODEL=voyage-3-large
EMBEDDING_DIM=1024

# PostgreSQL (Neon)
POSTGRES_HOST=ep-xxx.us-east-1.aws.neon.tech
POSTGRES_PORT=5432
POSTGRES_USER=xxx
POSTGRES_PASSWORD=xxx
POSTGRES_DATABASE=lightrag
POSTGRES_SSL_MODE=require

# Storage backends (all PostgreSQL)
KV_STORAGE=PGKVStorage
VECTOR_STORAGE=PGVectorStorage
GRAPH_STORAGE=PGGraphStorage
DOC_STATUS_STORAGE=PGDocStatusStorage

# Security
LIGHTRAG_API_KEY=sk-lightrag-xxx
```

### 2. Docker Compose for Local Testing
**File**: `deploy/serverless/docker-compose.yaml`
- Uses official `ghcr.io/hkuds/lightrag:latest` image
- Connects to Neon PostgreSQL
- Exposes port 9621

### 3. AWS CDK/SAM for Serverless
**File**: `deploy/serverless/aws/template.yaml`
- Fargate task definition with LightRAG container
- API Gateway HTTP API
- Auto-scaling (min: 0, max: 2)
- VPC configuration for Neon connection

### 4. Deployment Scripts
**Files**:
- `deploy/serverless/scripts/setup.sh` - Initial setup
- `deploy/serverless/scripts/deploy-aws.sh` - AWS deployment

### 5. MCP Server for Claude Code
**File**: `deploy/serverless/mcp-server/lightrag-mcp.py`
- Connects to LightRAG API
- Tools: search, query, upload document

### 6. Documentation
**File**: `deploy/serverless/README.md`
- Setup guide for Neon, Voyage AI
- Deployment instructions
- Claude Code integration

## Repository Strategy

**Starting fresh from LightRAG repo** (https://github.com/HKUDS/LightRAG):
1. Fork the official HKUDS/LightRAG repository
2. Add deployment configs in `deploy/serverless/` directory
3. This keeps upstream updates easy to merge

## Key Configuration Details

### Neon PostgreSQL Setup
1. Create project at neon.tech (free tier)
2. Enable pgvector extension: `CREATE EXTENSION vector;`
3. Note connection string

### Voyage AI Setup
1. Sign up at voyageai.com
2. Get API key (free tier: 50M tokens/month)
3. Use model: `voyage-3-large` (1024 dimensions)

### Claude Configuration
- Model: `claude-sonnet-4-20250514` (recommended for cost/quality)
- Or: `claude-3-opus-20240229` (highest quality)

## Cost Breakdown

| Component | Monthly Cost |
|-----------|--------------|
| Neon PostgreSQL | $0 (free tier) |
| Voyage AI embeddings | $0-5 (free tier + overflow) |
| Claude API | $5-15 (depends on usage) |
| Fargate compute | $2-5 (on-demand) |
| **Total** | **~$7-25/month** |

## Verification Plan

1. **Local testing**:
   ```bash
   docker compose up -d
   curl http://localhost:9621/health
   curl -X POST http://localhost:9621/documents/text \
     -H "X-API-Key: $API_KEY" \
     -d '{"content": "Test document"}'
   curl -X POST http://localhost:9621/query \
     -H "X-API-Key: $API_KEY" \
     -d '{"query": "What is in my documents?"}'
   ```

2. **AWS deployment**:
   ```bash
   ./scripts/deploy-aws.sh
   # Test API Gateway endpoint
   ```

3. **Claude Code integration**:
   - Configure MCP server
   - Test: "Search my LightRAG for..."

## User Preferences (Confirmed)

- **Embeddings**: Voyage AI (50M free tokens/month)
- **WebUI**: Yes, include React WebUI
- **Region**: us-east-1

## Implementation Steps

### Phase 0: Repository Setup
1. Fork HKUDS/LightRAG to your GitHub account
2. Clone the fork locally
3. Create feature branch for deployment configs

### Phase 1: Create Core Deployment Files
1. Create `deploy/serverless/` directory structure
2. Create `.env.example` with Claude + Voyage AI + Neon config
3. Create `docker-compose.yaml` for local testing with WebUI
4. Adapt existing Dockerfile if needed for production optimizations

### Phase 2: AWS Serverless Infrastructure
1. Create SAM template for Fargate (`deploy/serverless/aws/template.yaml`)
2. Configure API Gateway HTTP API with custom domain support
3. Set up auto-scaling (desired: 0, min: 0, max: 2)
4. Configure security groups for Neon PostgreSQL connection

### Phase 3: Claude Code Integration
1. Create MCP server for Claude Code (`deploy/serverless/mcp-server/`)
2. Implement tools: query, search, upload_document, list_documents
3. Add wake-on-demand logic if instance is stopped

### Phase 4: Setup Scripts & Security
1. Create `scripts/setup-neon.sh` - Initialize Neon with pgvector
2. Create `scripts/deploy-aws.sh` - One-command AWS deployment
3. Create security verification tests

### Phase 5: Documentation
1. Comprehensive README with architecture diagram
2. Step-by-step setup guides for Neon, Voyage AI, Claude
3. Claude Code MCP configuration guide
4. Cost optimization tips
