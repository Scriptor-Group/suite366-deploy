# Security Policy

Suite 366 appliance (“Diwy”) — Scriptor Artis.

This policy is our coordinated vulnerability disclosure process and our product
security contact, as required by Regulation (EU) 2024/2847 (Cyber Resilience
Act), Annex I Part II.

## Reporting a vulnerability

**security@scriptor-artis.com**

Write in French or English. If you prefer encrypted mail, ask for our key in a
first message and we will reply with it.

Please include, as far as you can:

- the appliance version (`cat /etc/suite366/release` or the footer of the web app)
- what the issue allows an attacker to do, and from which position (LAN,
  authenticated user, administrator, physical access)
- the steps to reproduce it
- whether you believe it is already being exploited

Do not open a public GitHub issue for a security problem. Do not test against an
appliance you do not own.

## What we commit to

| | |
|---|---|
| Acknowledgement | within **2 working days** |
| First assessment, with severity and an indicative timeline | within **10 working days** |
| Fix, for a confirmed critical or high severity issue | targeted within **30 days** of the assessment |
| Credit | your name or handle in the release notes, unless you prefer otherwise |

We will keep you informed while we work, and we will tell you when the fix ships
and under which version.

We do not operate a paid bug bounty. We do not take legal action against
researchers who follow this policy, who act in good faith, who stay within their
own appliance, and who give us a reasonable time to fix before publishing.

## Disclosure

We prefer coordinated disclosure. Our default is to publish an advisory once the
fix is available to customers, and we will agree the timing with you. If we
cannot ship a fix in a reasonable time, we will say so rather than let the
report sit.

Advisories are published in the release notes of this repository and reach
appliance administrators through the in-app update notice.

## Regulatory reporting

Where a vulnerability in this product is **actively exploited**, or where a
**severe incident** affects the security of the product, Scriptor Artis reports
it to the competent CSIRT and to ENISA through the Single Reporting Platform,
within the deadlines of Article 14 of the Cyber Resilience Act: an early warning
within 24 hours of becoming aware, a notification within 72 hours, and a final
report within 14 days of a corrective measure being available.

Affected administrators are informed directly, with the mitigation available to
them, without waiting for the final report.

Reporting to the authorities does not replace telling you, the reporter, what
happened to your report.

## Support period

Each appliance release is supported with security updates for **5 years** from
its release date.

During that period we provide security updates free of charge, through the same
signed update channel as functional updates, including the offline path for
appliances without outbound access.

The end-of-support date of the version you are running is shown in the
administration console and in the release notes.

## Scope

In scope: the installer and scripts in this repository, the Suite 366
application chart it deploys, the appliance configuration it produces, and the
update and backup mechanisms.

Out of scope: vulnerabilities in third-party components for which no Scriptor
Artis configuration is at fault — report those upstream, and tell us so we can
pull the fix; findings that require physical disassembly of the machine; social
engineering of our staff or of customers; and denial of service achieved purely
by saturating the hardware.

Rented appliances operated by Scriptor Artis are covered by this policy too. The
support tunnel, the backup storage and the publication proxy that serve them are
services rather than products, and are covered by our internal incident
procedure.
