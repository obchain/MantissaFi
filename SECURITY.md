# Security Policy

## Reporting Vulnerabilities

**Do not** create public issues for security vulnerabilities.

Email: security@mantissafi.com

### Response Timeline
- Initial response: 48 hours
- Status update: 5 business days
- Resolution target: 90 days

## Threat Model

### Oracle Manipulation
- **Risk**: Stale prices, flash loan attacks
- **Mitigation**: Staleness checks, TWAP, multiple oracles

### Flash Loan Attacks
- **Risk**: Price manipulation during exercise
- **Mitigation**: Snapshot-based pricing, reentrancy guards

### Precision Loss
- **Risk**: Systematic mispricing from rounding
- **Mitigation**: Fixed-point math, conservative rounding

### Access Control
- **Risk**: Unauthorized admin actions
- **Mitigation**: Role-based access, timelocks

## Security Audits

- [ ] Internal review
- [ ] External audit
- [ ] Formal verification
