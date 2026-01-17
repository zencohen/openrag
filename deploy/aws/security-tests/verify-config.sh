#!/bin/bash
set -e

# OpenRAG Configuration Verification Script
# Run this before deployment to verify security configuration

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES + 1)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }

FAILURES=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

echo ""
echo "OpenRAG Configuration Verification"
echo "==================================="
echo ""

# Check nginx.conf
log_info "Checking nginx.conf..."

NGINX_FILE="$PROJECT_ROOT/deploy/aws/nginx.conf"
if [[ -f "$NGINX_FILE" ]]; then
    # Check for server_tokens off
    if grep -q "server_tokens off" "$NGINX_FILE"; then
        log_pass "Nginx server tokens hidden"
    else
        log_fail "Nginx server tokens should be hidden"
    fi

    # Check for HSTS
    if grep -q "Strict-Transport-Security" "$NGINX_FILE"; then
        log_pass "HSTS header configured"
    else
        log_fail "HSTS header missing"
    fi

    # Check for rate limiting
    if grep -q "limit_req_zone" "$NGINX_FILE"; then
        log_pass "Rate limiting configured"
    else
        log_fail "Rate limiting not configured"
    fi

    # Check for CORS (should not be *)
    if grep -q 'Access-Control-Allow-Origin "\*"' "$NGINX_FILE"; then
        log_fail "CORS allows all origins (insecure)"
    else
        log_pass "CORS properly restricted"
    fi

    # Check for SSL protocols
    if grep -q "ssl_protocols TLSv1.2 TLSv1.3" "$NGINX_FILE"; then
        log_pass "Only TLS 1.2+ enabled"
    else
        log_warn "Check SSL protocol configuration"
    fi

    # Check for sensitive path blocking
    if grep -q 'location ~ /\\.' "$NGINX_FILE"; then
        log_pass "Hidden files blocked"
    else
        log_warn "Hidden files may be accessible"
    fi
else
    log_fail "nginx.conf not found"
fi

# Check docker-compose
log_info "Checking docker-compose.cloud.yaml..."

COMPOSE_FILE="$PROJECT_ROOT/deploy/aws/docker-compose.cloud.yaml"
if [[ -f "$COMPOSE_FILE" ]]; then
    # Check for localhost binding
    if grep -q '127.0.0.1:8080' "$COMPOSE_FILE"; then
        log_pass "Internal services bound to localhost"
    else
        log_warn "Internal services may be exposed"
    fi

    # Check for security_opt
    if grep -q "no-new-privileges" "$COMPOSE_FILE"; then
        log_pass "Container privilege escalation restricted"
    else
        log_warn "Consider adding no-new-privileges"
    fi

    # Check for read_only
    if grep -q "read_only: true" "$COMPOSE_FILE"; then
        log_pass "Read-only filesystem used where possible"
    else
        log_warn "Consider read-only filesystems"
    fi
else
    log_fail "docker-compose.cloud.yaml not found"
fi

# Check setup.sh
log_info "Checking setup.sh..."

SETUP_FILE="$PROJECT_ROOT/deploy/aws/setup.sh"
if [[ -f "$SETUP_FILE" ]]; then
    # Check for fail2ban
    if grep -q "fail2ban" "$SETUP_FILE"; then
        log_pass "fail2ban installation included"
    else
        log_warn "fail2ban not installed"
    fi

    # Check for firewall setup
    if grep -q "ufw" "$SETUP_FILE"; then
        log_pass "Firewall configuration included"
    else
        log_fail "Firewall configuration missing"
    fi

    # Check for SSH hardening
    if grep -q "harden_ssh\|PasswordAuthentication no" "$SETUP_FILE"; then
        log_pass "SSH hardening included"
    else
        log_warn "SSH hardening not included"
    fi

    # Check for automatic updates
    if grep -q "unattended-upgrades" "$SETUP_FILE"; then
        log_pass "Automatic security updates configured"
    else
        log_warn "Automatic updates not configured"
    fi

    # Check SSL key strength
    if grep -q "rsa:4096\|secp384r1\|secp256r1" "$SETUP_FILE"; then
        log_pass "Strong SSL keys configured"
    else
        log_warn "Check SSL key strength"
    fi
else
    log_fail "setup.sh not found"
fi

# Check .env.example
log_info "Checking .env.example..."

ENV_FILE="$PROJECT_ROOT/deploy/aws/.env.example"
if [[ -f "$ENV_FILE" ]]; then
    # Check for placeholder API keys
    if grep -q "REPLACE_WITH\|your-.*-here\|change-this" "$ENV_FILE"; then
        log_pass "Placeholder values used (not real secrets)"
    else
        log_warn "Check for hardcoded secrets"
    fi

    # Check AUTH_TOKEN format
    if grep -q "AUTH_TOKEN=sk-openrag-" "$ENV_FILE"; then
        log_pass "AUTH_TOKEN format looks secure"
    else
        log_warn "Check AUTH_TOKEN format"
    fi
else
    log_fail ".env.example not found"
fi

# Check MCP server
log_info "Checking MCP server configuration..."

MCP_FILE="$PROJECT_ROOT/deploy/aws/mcp-server/openrag-mcp-server.py"
if [[ -f "$MCP_FILE" ]]; then
    # Check for HTTPS enforcement
    if grep -q "https://" "$MCP_FILE" || grep -q "http_origin" "$MCP_FILE"; then
        log_pass "MCP server configured"
    fi

    # Check config.json for placeholder values
    MCP_CONFIG="$PROJECT_ROOT/deploy/aws/mcp-server/config.json"
    if [[ -f "$MCP_CONFIG" ]]; then
        if grep -q "your-.*-here\|your-token" "$MCP_CONFIG"; then
            log_pass "MCP config uses placeholder values"
        else
            log_warn "Check MCP config for hardcoded values"
        fi
    fi
else
    log_warn "MCP server not found"
fi

echo ""
echo "==================================="
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES check(s) failed${NC}"
    echo "Please fix the issues above before deployment."
    exit 1
fi
