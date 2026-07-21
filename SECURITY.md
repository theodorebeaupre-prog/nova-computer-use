# Security Policy

## Reporting a Vulnerability

**Do not open a public issue, discussion, or pull request for a suspected vulnerability.** Public reports can expose Nova users before a fix is available.

Once the public repository exists and private vulnerability reporting is enabled, open the repository's **Security** tab and choose **Report a vulnerability**. Until that control is available, Nova does not claim an operational private reporting channel. Do not disclose the issue publicly; check this policy again after repository setup.

When reporting becomes available, include:

- the affected commit or version;
- macOS version and Mac architecture;
- the smallest reproducible sequence;
- expected and observed behavior;
- impact and any known mitigations;
- sanitized logs or test code when needed.

Never include passwords, tokens, personal data, full Accessibility trees, or captured screens. If a safe reproduction is impossible without sensitive material, describe the situation first and wait for a secure coordination method.

You should receive an acknowledgement within seven days. Please allow time to reproduce, fix, test, and coordinate disclosure before publishing details. No bounty or specific remediation timeline is promised.

## Supported Versions

Nova has not published a stable release yet. Security fixes currently target the latest commit on `main`. This policy will be updated with a version support table before the first stable release.

## Security Boundaries

Nova's native computer-control engine makes no network requests, but it operates with macOS Accessibility and Screen Recording permissions and passes results to its MCP client. Those permissions can expose sensitive on-screen data and cause real UI side effects. Review the guarantees and limitations in the [README](README.md#security-model) before testing or deploying Nova.
