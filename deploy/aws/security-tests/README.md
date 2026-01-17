# OpenRAG Security Tests

Comprehensive security testing suite for OpenRAG cloud deployments using open source tools.

## Quick Start

### 1. Verify Configuration (Pre-deployment)

Run this locally before deploying to check your configuration files:

```bash
./verify-config.sh
```

This checks:
- Nginx security headers and configuration
- Docker Compose security settings
- Setup script security features
- Environment file best practices

### 2. Run Full Security Tests (Post-deployment)

After deployment, run the full security test suite:

```bash
# Basic test (no auth)
./run-security-tests.sh --url https://your-openrag-domain.com

# With authentication token
./run-security-tests.sh \
    --url https://your-openrag-domain.com \
    --token sk-openrag-your-token
```

## Tools Used

The test suite uses these open source security tools:

| Tool | Purpose | License |
|------|---------|---------|
| [testssl.sh](https://testssl.sh/) | SSL/TLS analysis | GPLv2 |
| [Trivy](https://trivy.dev/) | Container vulnerability scanning | Apache 2.0 |
| [Lynis](https://cisofy.com/lynis/) | System security auditing | GPLv3 |
| [Nikto](https://cirt.net/Nikto2) | Web server scanning | GPLv2 |
| OpenSSL | SSL certificate checks | Apache 2.0 |

## Test Categories

### SSL/TLS Tests
- Protocol version verification (TLS 1.2+)
- Certificate validity and strength
- Cipher suite security
- OCSP stapling

### HTTP Security Headers
- Strict-Transport-Security (HSTS)
- X-Content-Type-Options
- X-Frame-Options
- Content-Security-Policy
- Referrer-Policy

### API Security
- Authentication enforcement
- Invalid token rejection
- SQL injection protection
- Path traversal prevention
- Rate limiting verification

### Container Security
- Image vulnerability scanning
- Privileged container detection
- Root user detection
- Security option verification

### System Security
- Firewall status (UFW)
- fail2ban status
- SSH configuration
- Open port audit
- File permissions

## Test Reports

Reports are saved to `./security-reports/report_TIMESTAMP/`:

```
security-reports/
└── report_20240115_143022/
    ├── SUMMARY.md          # Overview and recommendations
    ├── ssl_test.txt        # SSL/TLS results
    ├── headers_test.txt    # HTTP header results
    ├── api_test.txt        # API security results
    ├── container_test.txt  # Container scan results
    ├── system_test.txt     # System audit results
    ├── testssl.json        # Detailed SSL analysis
    └── lynis_report.dat    # System audit data
```

## Scheduled Testing

For continuous security monitoring, add to crontab:

```bash
# Run security tests weekly
0 2 * * 0 /opt/openrag/deploy/aws/security-tests/run-security-tests.sh \
    --url https://your-domain.com \
    --token $AUTH_TOKEN \
    --output /var/log/openrag-security \
    --skip-install >> /var/log/openrag-security.log 2>&1
```

## Interpreting Results

| Status | Meaning | Action |
|--------|---------|--------|
| **PASS** | Test passed | None required |
| **FAIL** | Security issue found | Fix immediately |
| **WARN** | Potential issue | Review and consider fixing |

## Common Issues and Fixes

### SSL/TLS Issues

```bash
# Regenerate stronger SSL certificate
openssl ecparam -genkey -name secp384r1 -out privkey.pem
openssl req -new -x509 -sha384 -days 365 -key privkey.pem -out fullchain.pem
```

### Missing Security Headers

Edit `nginx.conf` and ensure these headers are present:
```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
```

### Rate Limiting Not Working

Check nginx configuration:
```nginx
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
limit_req zone=api_limit burst=20 nodelay;
```

### Container Vulnerabilities

Update container images:
```bash
docker compose pull
docker compose up -d
```

## Security Best Practices

1. **Regular Testing**: Run security tests at least weekly
2. **Update Images**: Keep all container images updated
3. **Monitor Logs**: Review fail2ban and nginx logs
4. **Backup Regularly**: Test backup restoration
5. **Rotate Secrets**: Change AUTH_TOKEN periodically
6. **Network Segmentation**: Use private networks where possible

## Contributing

To add new security tests:

1. Add test function in `run-security-tests.sh`
2. Update the summary generator
3. Document in this README
4. Test thoroughly before committing
