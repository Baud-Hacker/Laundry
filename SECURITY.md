# Security Policy

## Intended use

Laundry is for hosting **you own or are explicitly authorized to operate** — protecting
discreet admin surfaces, deniable/private hosting, and similar defensive use cases. It is
not intended for evading access controls on systems you do not control. Deploy it only
where you have that authority.

## Reporting a vulnerability

Please report suspected vulnerabilities privately rather than opening a public issue:

- Use GitHub's **private vulnerability reporting** ("Report a vulnerability" under the
  repository's *Security* tab), or
- email the maintainer.

Include a description, affected version/commit, and reproduction steps. You'll get an
acknowledgement, and a fix or mitigation timeline once triaged.

## Operational security notes

These are documented in full in [GUIDE.md](GUIDE.md); the essentials:

- **Always serve over TLS** with a real certificate. Basic auth is base64, not encryption.
- **Use high-entropy pre-shared keys** (the CLI mints 256-bit) and deliver them out of band.
- **Keep the pepper (`LAUNDRY_SERVER_KEY[_FILE]`) out of the database** and readable only by
  the service account.
- Residual risks (traffic analysis, PSK replay under broken TLS, decoy realism) are listed
  in the guide — review them against your threat model before relying on this.
