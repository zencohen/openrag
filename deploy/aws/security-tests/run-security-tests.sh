#!/bin/bash
set -e

# OpenRAG Security Test Suite
# Uses open source tools to verify security configuration

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
OPENRAG_URL="${OPENRAG_URL:-https://localhost}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
OUTPUT_DIR="${OUTPUT_DIR:-./security-reports}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         OpenRAG Security Test Suite                       ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --url URL           OpenRAG URL (default: https://localhost)"
    echo "  -t, --token TOKEN       API authentication token"
    echo "  -o, --output DIR        Output directory for reports"
    echo "  --skip-install          Skip tool installation"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --url https://openrag.example.com --token sk-openrag-xxx"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url) OPENRAG_URL="$2"; shift 2 ;;
            -t|--token) AUTH_TOKEN="$2"; shift 2 ;;
            -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
            --skip-install) SKIP_INSTALL=true; shift ;;
            -h|--help) print_usage; exit 0 ;;
            *) echo "Unknown option: $1"; print_usage; exit 1 ;;
        esac
    done
}

install_tools() {
    if [[ "$SKIP_INSTALL" == "true" ]]; then
        log_info "Skipping tool installation"
        return
    fi

    log_info "Installing security testing tools..."

    # Install system packages
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y curl jq nmap nikto openssl netcat-openbsd
    elif command -v yum &> /dev/null; then
        sudo yum install -y curl jq nmap nikto openssl nc
    fi

    # Install testssl.sh
    if [[ ! -d "/opt/testssl" ]]; then
        log_info "Installing testssl.sh..."
        sudo git clone --depth 1 https://github.com/drwetter/testssl.sh.git /opt/testssl
    fi

    # Install trivy for container scanning
    if ! command -v trivy &> /dev/null; then
        log_info "Installing Trivy..."
        curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin
    fi

    # Install lynis for system auditing
    if ! command -v lynis &> /dev/null; then
        log_info "Installing Lynis..."
        sudo apt-get install -y lynis 2>/dev/null || \
            sudo git clone https://github.com/CISOfy/lynis /opt/lynis
    fi

    log_pass "Security tools installed"
}

setup_output_dir() {
    mkdir -p "$OUTPUT_DIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REPORT_DIR="$OUTPUT_DIR/report_$TIMESTAMP"
    mkdir -p "$REPORT_DIR"
    log_info "Reports will be saved to: $REPORT_DIR"
}

# ============================================
# SSL/TLS Tests
# ============================================
test_ssl_tls() {
    log_info "Running SSL/TLS security tests..."

    local host=$(echo "$OPENRAG_URL" | sed 's|https://||' | cut -d'/' -f1)
    local ssl_report="$REPORT_DIR/ssl_test.txt"
    local passed=0
    local failed=0

    echo "SSL/TLS Security Test Report" > "$ssl_report"
    echo "=============================" >> "$ssl_report"
    echo "Target: $host" >> "$ssl_report"
    echo "Date: $(date)" >> "$ssl_report"
    echo "" >> "$ssl_report"

    # Test 1: Check for SSLv3 (should be disabled)
    if timeout 5 openssl s_client -ssl3 -connect "$host:443" 2>&1 | grep -q "ssl handshake failure\|no protocols available"; then
        log_pass "SSLv3 disabled"
        ((passed++))
    else
        log_fail "SSLv3 may be enabled (security risk)"
        ((failed++))
    fi

    # Test 2: Check for TLS 1.0 (should be disabled)
    if timeout 5 openssl s_client -tls1 -connect "$host:443" 2>&1 | grep -q "ssl handshake failure\|no protocols available\|wrong version"; then
        log_pass "TLS 1.0 disabled"
        ((passed++))
    else
        log_warn "TLS 1.0 may be enabled (consider disabling)"
    fi

    # Test 3: Check for TLS 1.1 (should be disabled)
    if timeout 5 openssl s_client -tls1_1 -connect "$host:443" 2>&1 | grep -q "ssl handshake failure\|no protocols available\|wrong version"; then
        log_pass "TLS 1.1 disabled"
        ((passed++))
    else
        log_warn "TLS 1.1 may be enabled (consider disabling)"
    fi

    # Test 4: Check TLS 1.2 is supported
    if timeout 5 openssl s_client -tls1_2 -connect "$host:443" </dev/null 2>&1 | grep -q "CONNECTED"; then
        log_pass "TLS 1.2 supported"
        ((passed++))
    else
        log_fail "TLS 1.2 not supported"
        ((failed++))
    fi

    # Test 5: Check TLS 1.3 is supported
    if timeout 5 openssl s_client -tls1_3 -connect "$host:443" </dev/null 2>&1 | grep -q "CONNECTED"; then
        log_pass "TLS 1.3 supported"
        ((passed++))
    else
        log_warn "TLS 1.3 not supported (recommended)"
    fi

    # Test 6: Check certificate validity
    local cert_info=$(timeout 5 openssl s_client -connect "$host:443" </dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)
    if [[ -n "$cert_info" ]]; then
        echo "Certificate Info:" >> "$ssl_report"
        echo "$cert_info" >> "$ssl_report"
        log_pass "SSL certificate present"
        ((passed++))
    else
        log_fail "Could not retrieve SSL certificate"
        ((failed++))
    fi

    # Run testssl.sh if available
    if [[ -f "/opt/testssl/testssl.sh" ]]; then
        log_info "Running comprehensive SSL test with testssl.sh..."
        /opt/testssl/testssl.sh --quiet --jsonfile "$REPORT_DIR/testssl.json" "$host" >> "$ssl_report" 2>&1 || true
    fi

    echo "" >> "$ssl_report"
    echo "Summary: $passed passed, $failed failed" >> "$ssl_report"

    if [[ $failed -eq 0 ]]; then
        log_pass "SSL/TLS tests completed: $passed passed"
    else
        log_fail "SSL/TLS tests completed: $passed passed, $failed failed"
    fi
}

# ============================================
# HTTP Security Header Tests
# ============================================
test_http_headers() {
    log_info "Testing HTTP security headers..."

    local headers_report="$REPORT_DIR/headers_test.txt"
    local passed=0
    local failed=0

    echo "HTTP Security Headers Test Report" > "$headers_report"
    echo "==================================" >> "$headers_report"
    echo "Target: $OPENRAG_URL" >> "$headers_report"
    echo "Date: $(date)" >> "$headers_report"
    echo "" >> "$headers_report"

    # Get headers
    local headers=$(curl -sI -k "$OPENRAG_URL/health" 2>/dev/null)
    echo "Raw Headers:" >> "$headers_report"
    echo "$headers" >> "$headers_report"
    echo "" >> "$headers_report"

    # Test 1: Strict-Transport-Security
    if echo "$headers" | grep -qi "strict-transport-security"; then
        log_pass "HSTS header present"
        ((passed++))
    else
        log_fail "HSTS header missing"
        ((failed++))
    fi

    # Test 2: X-Content-Type-Options
    if echo "$headers" | grep -qi "x-content-type-options.*nosniff"; then
        log_pass "X-Content-Type-Options header present"
        ((passed++))
    else
        log_fail "X-Content-Type-Options header missing"
        ((failed++))
    fi

    # Test 3: X-Frame-Options
    if echo "$headers" | grep -qi "x-frame-options"; then
        log_pass "X-Frame-Options header present"
        ((passed++))
    else
        log_fail "X-Frame-Options header missing"
        ((failed++))
    fi

    # Test 4: Content-Security-Policy
    if echo "$headers" | grep -qi "content-security-policy"; then
        log_pass "Content-Security-Policy header present"
        ((passed++))
    else
        log_warn "Content-Security-Policy header missing (recommended)"
    fi

    # Test 5: Referrer-Policy
    if echo "$headers" | grep -qi "referrer-policy"; then
        log_pass "Referrer-Policy header present"
        ((passed++))
    else
        log_warn "Referrer-Policy header missing"
    fi

    # Test 6: Server header hidden
    if echo "$headers" | grep -qi "^server:.*nginx/"; then
        log_fail "Server version exposed"
        ((failed++))
    else
        log_pass "Server version hidden"
        ((passed++))
    fi

    # Test 7: Check for HTTP to HTTPS redirect
    local http_response=$(curl -sI -o /dev/null -w "%{http_code}" "http://${OPENRAG_URL#https://}/health" 2>/dev/null || echo "000")
    if [[ "$http_response" == "301" ]] || [[ "$http_response" == "302" ]]; then
        log_pass "HTTP redirects to HTTPS"
        ((passed++))
    else
        log_warn "HTTP may not redirect to HTTPS"
    fi

    echo "" >> "$headers_report"
    echo "Summary: $passed passed, $failed failed" >> "$headers_report"

    if [[ $failed -eq 0 ]]; then
        log_pass "HTTP header tests completed: $passed passed"
    else
        log_fail "HTTP header tests completed: $passed passed, $failed failed"
    fi
}

# ============================================
# API Security Tests
# ============================================
test_api_security() {
    log_info "Testing API security..."

    local api_report="$REPORT_DIR/api_test.txt"
    local passed=0
    local failed=0

    echo "API Security Test Report" > "$api_report"
    echo "========================" >> "$api_report"
    echo "Target: $OPENRAG_URL" >> "$api_report"
    echo "Date: $(date)" >> "$api_report"
    echo "" >> "$api_report"

    # Test 1: Unauthenticated access to protected endpoint
    local unauth_response=$(curl -sk -o /dev/null -w "%{http_code}" "$OPENRAG_URL/api/partition" 2>/dev/null)
    if [[ "$unauth_response" == "401" ]] || [[ "$unauth_response" == "403" ]]; then
        log_pass "Protected endpoints require authentication"
        ((passed++))
    else
        log_fail "Protected endpoints accessible without auth (HTTP $unauth_response)"
        ((failed++))
    fi

    # Test 2: Invalid token rejected
    local invalid_response=$(curl -sk -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer invalid-token-12345" \
        "$OPENRAG_URL/api/partition" 2>/dev/null)
    if [[ "$invalid_response" == "401" ]] || [[ "$invalid_response" == "403" ]]; then
        log_pass "Invalid tokens rejected"
        ((passed++))
    else
        log_fail "Invalid tokens may be accepted (HTTP $invalid_response)"
        ((failed++))
    fi

    # Test 3: SQL injection attempt (should be blocked or fail safely)
    local sqli_response=$(curl -sk -o /dev/null -w "%{http_code}" \
        "$OPENRAG_URL/api/search?query='; DROP TABLE users;--" 2>/dev/null)
    if [[ "$sqli_response" != "500" ]]; then
        log_pass "SQL injection attempt handled safely"
        ((passed++))
    else
        log_warn "SQL injection may cause server error"
    fi

    # Test 4: Path traversal attempt
    local traversal_response=$(curl -sk -o /dev/null -w "%{http_code}" \
        "$OPENRAG_URL/../../../etc/passwd" 2>/dev/null)
    if [[ "$traversal_response" == "400" ]] || [[ "$traversal_response" == "404" ]] || [[ "$traversal_response" == "301" ]]; then
        log_pass "Path traversal blocked"
        ((passed++))
    else
        log_fail "Path traversal may be possible (HTTP $traversal_response)"
        ((failed++))
    fi

    # Test 5: .env file not accessible
    local env_response=$(curl -sk -o /dev/null -w "%{http_code}" "$OPENRAG_URL/.env" 2>/dev/null)
    if [[ "$env_response" == "404" ]] || [[ "$env_response" == "403" ]]; then
        log_pass ".env file not accessible"
        ((passed++))
    else
        log_fail ".env file may be accessible (HTTP $env_response)"
        ((failed++))
    fi

    # Test 6: Rate limiting works
    log_info "Testing rate limiting (this may take a moment)..."
    local rate_limited=false
    for i in {1..50}; do
        local rl_response=$(curl -sk -o /dev/null -w "%{http_code}" "$OPENRAG_URL/api/health" 2>/dev/null)
        if [[ "$rl_response" == "429" ]]; then
            rate_limited=true
            break
        fi
    done
    if [[ "$rate_limited" == "true" ]]; then
        log_pass "Rate limiting is active"
        ((passed++))
    else
        log_warn "Rate limiting may not be active (or threshold not reached)"
    fi

    # Test with valid token if provided
    if [[ -n "$AUTH_TOKEN" ]]; then
        local auth_response=$(curl -sk -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer $AUTH_TOKEN" \
            "$OPENRAG_URL/api/partition" 2>/dev/null)
        if [[ "$auth_response" == "200" ]]; then
            log_pass "Valid token accepted"
            ((passed++))
        else
            log_warn "Valid token may not work (HTTP $auth_response)"
        fi
    fi

    echo "" >> "$api_report"
    echo "Summary: $passed passed, $failed failed" >> "$api_report"

    if [[ $failed -eq 0 ]]; then
        log_pass "API security tests completed: $passed passed"
    else
        log_fail "API security tests completed: $passed passed, $failed failed"
    fi
}

# ============================================
# Container Security Tests
# ============================================
test_container_security() {
    log_info "Testing container security..."

    local container_report="$REPORT_DIR/container_test.txt"

    echo "Container Security Test Report" > "$container_report"
    echo "==============================" >> "$container_report"
    echo "Date: $(date)" >> "$container_report"
    echo "" >> "$container_report"

    # Check if we're on the server with Docker
    if ! command -v docker &> /dev/null; then
        log_warn "Docker not available, skipping container tests"
        return
    fi

    # Test 1: Scan images with Trivy
    if command -v trivy &> /dev/null; then
        log_info "Scanning container images with Trivy..."

        local images=("linagoraai/openrag:latest" "nginx:alpine" "postgres:15")

        for image in "${images[@]}"; do
            log_info "Scanning $image..."
            trivy image --severity HIGH,CRITICAL --quiet "$image" >> "$container_report" 2>&1 || true
        done
    else
        log_warn "Trivy not installed, skipping image scanning"
    fi

    # Test 2: Check container configurations
    log_info "Checking container security configurations..."

    # Check for privileged containers
    local privileged=$(docker ps --format '{{.Names}}' | while read name; do
        docker inspect "$name" --format '{{.HostConfig.Privileged}}' 2>/dev/null | grep -q "true" && echo "$name"
    done)
    if [[ -z "$privileged" ]]; then
        log_pass "No privileged containers running"
    else
        log_fail "Privileged containers found: $privileged"
    fi

    # Check for containers running as root
    docker ps --format '{{.Names}}' | while read name; do
        local user=$(docker inspect "$name" --format '{{.Config.User}}' 2>/dev/null)
        if [[ -z "$user" ]] || [[ "$user" == "root" ]] || [[ "$user" == "0" ]]; then
            log_warn "Container $name runs as root"
        fi
    done

    log_pass "Container security tests completed"
}

# ============================================
# System Security Tests
# ============================================
test_system_security() {
    log_info "Testing system security..."

    local system_report="$REPORT_DIR/system_test.txt"
    local passed=0
    local failed=0

    echo "System Security Test Report" > "$system_report"
    echo "===========================" >> "$system_report"
    echo "Date: $(date)" >> "$system_report"
    echo "" >> "$system_report"

    # Test 1: Check firewall status
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            log_pass "UFW firewall is active"
            ((passed++))
            ufw status >> "$system_report"
        else
            log_fail "UFW firewall is not active"
            ((failed++))
        fi
    fi

    # Test 2: Check fail2ban status
    if command -v fail2ban-client &> /dev/null; then
        if systemctl is-active --quiet fail2ban; then
            log_pass "fail2ban is running"
            ((passed++))
            fail2ban-client status >> "$system_report" 2>/dev/null
        else
            log_fail "fail2ban is not running"
            ((failed++))
        fi
    fi

    # Test 3: Check SSH configuration
    if [[ -f /etc/ssh/sshd_config ]]; then
        if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
            log_pass "SSH password authentication disabled"
            ((passed++))
        else
            log_warn "SSH password authentication may be enabled"
        fi

        if grep -q "^PermitRootLogin.*no\|^PermitRootLogin.*prohibit-password" /etc/ssh/sshd_config; then
            log_pass "SSH root login restricted"
            ((passed++))
        else
            log_warn "SSH root login may be allowed"
        fi
    fi

    # Test 4: Check for listening ports
    log_info "Checking listening ports..."
    echo "" >> "$system_report"
    echo "Listening Ports:" >> "$system_report"
    ss -tlnp 2>/dev/null >> "$system_report" || netstat -tlnp 2>/dev/null >> "$system_report"

    # Check that only expected ports are open
    local unexpected_ports=$(ss -tlnp 2>/dev/null | grep -v "127.0.0.1\|::1" | grep -v ":22\|:80\|:443" | grep "LISTEN")
    if [[ -z "$unexpected_ports" ]]; then
        log_pass "Only expected ports open externally"
        ((passed++))
    else
        log_warn "Unexpected ports may be open externally"
        echo "$unexpected_ports" >> "$system_report"
    fi

    # Test 5: Check .env file permissions
    if [[ -f "/opt/openrag/.env" ]]; then
        local env_perms=$(stat -c "%a" /opt/openrag/.env 2>/dev/null)
        if [[ "$env_perms" == "600" ]]; then
            log_pass ".env file has correct permissions (600)"
            ((passed++))
        else
            log_fail ".env file permissions too open ($env_perms, should be 600)"
            ((failed++))
        fi
    fi

    # Run Lynis if available
    if command -v lynis &> /dev/null || [[ -f "/opt/lynis/lynis" ]]; then
        log_info "Running Lynis system audit (this may take a few minutes)..."
        local lynis_cmd="lynis"
        [[ -f "/opt/lynis/lynis" ]] && lynis_cmd="/opt/lynis/lynis"
        sudo $lynis_cmd audit system --quick --quiet --report-file "$REPORT_DIR/lynis_report.dat" 2>/dev/null || true
    fi

    echo "" >> "$system_report"
    echo "Summary: $passed passed, $failed failed" >> "$system_report"

    if [[ $failed -eq 0 ]]; then
        log_pass "System security tests completed: $passed passed"
    else
        log_fail "System security tests completed: $passed passed, $failed failed"
    fi
}

# ============================================
# Generate Summary Report
# ============================================
generate_summary() {
    log_info "Generating summary report..."

    local summary_file="$REPORT_DIR/SUMMARY.md"

    cat > "$summary_file" << EOF
# OpenRAG Security Test Summary

**Date:** $(date)
**Target:** $OPENRAG_URL

## Test Results

| Category | Status |
|----------|--------|
| SSL/TLS | See ssl_test.txt |
| HTTP Headers | See headers_test.txt |
| API Security | See api_test.txt |
| Container Security | See container_test.txt |
| System Security | See system_test.txt |

## Files Generated

- \`ssl_test.txt\` - SSL/TLS configuration tests
- \`headers_test.txt\` - HTTP security header tests
- \`api_test.txt\` - API security tests
- \`container_test.txt\` - Container security scan
- \`system_test.txt\` - System hardening checks
- \`testssl.json\` - Detailed SSL analysis (if testssl.sh available)
- \`lynis_report.dat\` - System audit report (if Lynis available)

## Recommendations

1. Review any FAIL or WARN items in the reports
2. Address CRITICAL and HIGH severity findings first
3. Consider implementing additional security measures:
   - Web Application Firewall (WAF)
   - Intrusion Detection System (IDS)
   - Regular security updates
   - Backup verification

## Next Steps

1. Fix identified issues
2. Re-run tests to verify fixes
3. Schedule regular security scans
EOF

    log_pass "Summary report generated: $summary_file"
}

# ============================================
# Main
# ============================================
main() {
    print_banner
    parse_args "$@"

    log_info "Starting security tests for: $OPENRAG_URL"

    install_tools
    setup_output_dir

    # Run all tests
    test_ssl_tls
    test_http_headers
    test_api_security
    test_container_security
    test_system_security

    generate_summary

    echo ""
    log_info "Security tests completed!"
    log_info "Reports saved to: $REPORT_DIR"
    echo ""
}

main "$@"
