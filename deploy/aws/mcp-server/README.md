# OpenRAG MCP Server for Claude Code

This MCP (Model Context Protocol) server enables Claude Code to search and query your personal OpenRAG knowledge base.

## What You Can Do

Once configured, you can ask Claude Code things like:

- "Search my knowledge base for information about X"
- "What do my documents say about Y?"
- "Find all references to Z in my indexed files"

Claude Code will automatically query your OpenRAG instance and include the relevant context in its responses.

## Setup

### 1. Install Dependencies

```bash
cd deploy/aws/mcp-server
pip install -r requirements.txt
```

### 2. Configure the Server

Edit `config.json` with your OpenRAG instance details:

```json
{
  "openrag_url": "https://your-openrag-instance.com",
  "api_token": "sk-openrag-your-token-here",
  "default_partition": "default",
  "timeout": 30
}
```

Or use environment variables:
```bash
export OPENRAG_URL="https://your-openrag-instance.com"
export OPENRAG_API_TOKEN="sk-openrag-your-token-here"
```

### 3. Add to Claude Code

#### Option A: Using claude_desktop_config.json

Add to your Claude Code MCP configuration (`~/.config/claude/claude_desktop_config.json` on Linux, `~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

```json
{
  "mcpServers": {
    "openrag": {
      "command": "python",
      "args": ["/path/to/openrag/deploy/aws/mcp-server/openrag-mcp-server.py"],
      "env": {
        "OPENRAG_URL": "https://your-openrag-instance.com",
        "OPENRAG_API_TOKEN": "sk-openrag-your-token-here"
      }
    }
  }
}
```

#### Option B: Using UV (recommended)

```json
{
  "mcpServers": {
    "openrag": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/linagora/openrag#subdirectory=deploy/aws/mcp-server", "openrag-mcp-server"],
      "env": {
        "OPENRAG_URL": "https://your-openrag-instance.com",
        "OPENRAG_API_TOKEN": "sk-openrag-your-token-here"
      }
    }
  }
}
```

### 4. Restart Claude Code

After adding the configuration, restart Claude Code to load the MCP server.

## Available Tools

The MCP server provides these tools to Claude Code:

### `openrag_search`
Search your knowledge base for relevant documents.

```
Query: "machine learning best practices"
Returns: Top matching document chunks with sources and relevance scores
```

### `openrag_chat`
Ask a question and get an answer generated from your knowledge base.

```
Question: "What is our company's vacation policy?"
Returns: Answer synthesized from relevant documents with sources
```

### `openrag_list_partitions`
List all available document collections/partitions.

```
Returns: List of partitions with document counts
```

### `openrag_partition_info`
Get detailed information about a specific partition.

```
Partition: "company-docs"
Returns: Document count, chunk count, creation date, etc.
```

## Usage Examples

Once configured, you can use natural language with Claude Code:

**Search for information:**
```
User: "Search my OpenRAG for information about API authentication"
Claude: [Uses openrag_search tool, returns relevant documents]
```

**Ask questions:**
```
User: "Based on my knowledge base, how do I set up the development environment?"
Claude: [Uses openrag_chat tool, returns synthesized answer with sources]
```

**Check what's indexed:**
```
User: "What document collections do I have in OpenRAG?"
Claude: [Uses openrag_list_partitions tool, returns list]
```

## Troubleshooting

### Connection Errors

1. Verify your OpenRAG instance is running:
   ```bash
   curl https://your-openrag-instance.com/health
   ```

2. Check your API token is correct:
   ```bash
   curl -H "Authorization: Bearer sk-openrag-your-token" \
        https://your-openrag-instance.com/partition
   ```

### MCP Server Not Loading

1. Check Claude Code logs for errors
2. Verify Python path is correct in config
3. Test the server manually:
   ```bash
   python openrag-mcp-server.py
   # Should start without errors
   ```

### Slow Responses

- Increase timeout in `config.json`
- Check OpenRAG instance performance
- Consider reducing `top_k` for faster searches

## Security Notes

- Your API token is sent with each request
- Use HTTPS for your OpenRAG instance
- Don't commit `config.json` with real tokens to version control
- Consider using environment variables for tokens

## Integration with Claude Cowork

The same MCP server works with Claude Cowork. Add the configuration to your team's shared MCP settings to enable knowledge base access for all team members.
