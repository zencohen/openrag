#!/usr/bin/env python3
"""
OpenRAG MCP Server for Claude Code Integration

This MCP (Model Context Protocol) server allows Claude Code to query your
personal OpenRAG instance for document retrieval and search.

Usage:
    1. Configure your OpenRAG URL and API token in config.json
    2. Add this server to your Claude Code MCP settings
    3. Claude Code can now search your knowledge base!
"""

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Any

import httpx

# MCP SDK imports
try:
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import (
        Tool,
        TextContent,
        CallToolResult,
    )
except ImportError:
    print("Error: MCP SDK not installed. Run: pip install mcp", file=sys.stderr)
    sys.exit(1)


# Configuration
CONFIG_PATH = Path(__file__).parent / "config.json"
DEFAULT_CONFIG = {
    "openrag_url": "https://your-openrag-instance.com",
    "api_token": "sk-openrag-your-token-here",
    "default_partition": "default",
    "timeout": 30,
}


def load_config() -> dict:
    """Load configuration from config.json or environment variables."""
    config = DEFAULT_CONFIG.copy()

    # Try loading from config file
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            file_config = json.load(f)
            config.update(file_config)

    # Environment variables override config file
    if os.environ.get("OPENRAG_URL"):
        config["openrag_url"] = os.environ["OPENRAG_URL"]
    if os.environ.get("OPENRAG_API_TOKEN"):
        config["api_token"] = os.environ["OPENRAG_API_TOKEN"]
    if os.environ.get("OPENRAG_PARTITION"):
        config["default_partition"] = os.environ["OPENRAG_PARTITION"]

    return config


# Initialize server
server = Server("openrag-mcp")
config = load_config()


def get_headers() -> dict:
    """Get HTTP headers for OpenRAG API requests."""
    return {
        "Authorization": f"Bearer {config['api_token']}",
        "Content-Type": "application/json",
    }


@server.list_tools()
async def list_tools() -> list[Tool]:
    """List available tools for Claude Code."""
    return [
        Tool(
            name="openrag_search",
            description="Search your personal OpenRAG knowledge base for relevant documents. "
                       "Use this to find information from your indexed documents, PDFs, notes, etc.",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The search query to find relevant documents"
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Number of results to return (default: 5, max: 20)",
                        "default": 5
                    },
                    "partition": {
                        "type": "string",
                        "description": "Document partition/collection to search (optional)"
                    }
                },
                "required": ["query"]
            }
        ),
        Tool(
            name="openrag_chat",
            description="Ask a question that will be answered using your OpenRAG knowledge base. "
                       "The system will retrieve relevant documents and generate an answer.",
            inputSchema={
                "type": "object",
                "properties": {
                    "question": {
                        "type": "string",
                        "description": "Your question to be answered using the knowledge base"
                    },
                    "partition": {
                        "type": "string",
                        "description": "Document partition/collection to use (optional)"
                    }
                },
                "required": ["question"]
            }
        ),
        Tool(
            name="openrag_list_partitions",
            description="List all available document partitions/collections in your OpenRAG instance.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="openrag_partition_info",
            description="Get information about a specific partition including document count and metadata.",
            inputSchema={
                "type": "object",
                "properties": {
                    "partition": {
                        "type": "string",
                        "description": "Name of the partition to get info about"
                    }
                },
                "required": ["partition"]
            }
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    """Handle tool calls from Claude Code."""

    async with httpx.AsyncClient(timeout=config["timeout"]) as client:
        try:
            if name == "openrag_search":
                return await handle_search(client, arguments)
            elif name == "openrag_chat":
                return await handle_chat(client, arguments)
            elif name == "openrag_list_partitions":
                return await handle_list_partitions(client)
            elif name == "openrag_partition_info":
                return await handle_partition_info(client, arguments)
            else:
                return [TextContent(type="text", text=f"Unknown tool: {name}")]
        except httpx.HTTPError as e:
            return [TextContent(type="text", text=f"HTTP Error: {str(e)}")]
        except Exception as e:
            return [TextContent(type="text", text=f"Error: {str(e)}")]


async def handle_search(client: httpx.AsyncClient, arguments: dict) -> list[TextContent]:
    """Handle document search."""
    query = arguments.get("query", "")
    top_k = min(arguments.get("top_k", 5), 20)
    partition = arguments.get("partition", config["default_partition"])

    response = await client.post(
        f"{config['openrag_url']}/search",
        headers=get_headers(),
        json={
            "query": query,
            "top_k": top_k,
            "partition_name": partition
        }
    )
    response.raise_for_status()
    results = response.json()

    # Format results for Claude
    output = f"## Search Results for: '{query}'\n\n"

    if not results.get("documents"):
        output += "No documents found matching your query.\n"
    else:
        for i, doc in enumerate(results["documents"], 1):
            output += f"### Result {i}\n"
            output += f"**Source:** {doc.get('metadata', {}).get('source', 'Unknown')}\n"
            output += f"**Score:** {doc.get('score', 'N/A')}\n"
            output += f"**Content:**\n{doc.get('content', '')[:1000]}...\n\n"

    return [TextContent(type="text", text=output)]


async def handle_chat(client: httpx.AsyncClient, arguments: dict) -> list[TextContent]:
    """Handle RAG-powered chat."""
    question = arguments.get("question", "")
    partition = arguments.get("partition", config["default_partition"])

    response = await client.post(
        f"{config['openrag_url']}/v1/chat/completions",
        headers=get_headers(),
        json={
            "model": "openrag",
            "messages": [
                {"role": "user", "content": question}
            ],
            "partition_name": partition
        }
    )
    response.raise_for_status()
    result = response.json()

    # Extract answer
    answer = result.get("choices", [{}])[0].get("message", {}).get("content", "No answer generated")

    output = f"## Answer from OpenRAG\n\n{answer}\n"

    # Include sources if available
    if "sources" in result:
        output += "\n### Sources\n"
        for source in result["sources"]:
            output += f"- {source}\n"

    return [TextContent(type="text", text=output)]


async def handle_list_partitions(client: httpx.AsyncClient) -> list[TextContent]:
    """List all partitions."""
    response = await client.get(
        f"{config['openrag_url']}/partition",
        headers=get_headers()
    )
    response.raise_for_status()
    partitions = response.json()

    output = "## Available Partitions\n\n"

    if not partitions:
        output += "No partitions found.\n"
    else:
        for p in partitions:
            name = p.get("name", "Unknown")
            doc_count = p.get("document_count", "N/A")
            output += f"- **{name}**: {doc_count} documents\n"

    return [TextContent(type="text", text=output)]


async def handle_partition_info(client: httpx.AsyncClient, arguments: dict) -> list[TextContent]:
    """Get partition details."""
    partition = arguments.get("partition", config["default_partition"])

    response = await client.get(
        f"{config['openrag_url']}/partition/{partition}",
        headers=get_headers()
    )
    response.raise_for_status()
    info = response.json()

    output = f"## Partition: {partition}\n\n"
    output += f"- **Documents:** {info.get('document_count', 'N/A')}\n"
    output += f"- **Chunks:** {info.get('chunk_count', 'N/A')}\n"
    output += f"- **Created:** {info.get('created_at', 'N/A')}\n"
    output += f"- **Updated:** {info.get('updated_at', 'N/A')}\n"

    return [TextContent(type="text", text=output)]


async def main():
    """Run the MCP server."""
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options()
        )


if __name__ == "__main__":
    asyncio.run(main())
