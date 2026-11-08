"""A CA bundle that doesn't depend on the operating system's certificate store.

Some Python builds (uv/standalone on NixOS, python.org builds on macOS) don't
point OpenSSL at a usable CA file, so HTTPS to Supabase fails with
"CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate". certifi
ships Mozilla's root certificates, so using it works everywhere.
"""

from __future__ import annotations

import ssl

import certifi


def ssl_context() -> ssl.SSLContext:
    """A default TLS context that verifies against certifi's bundled roots."""
    return ssl.create_default_context(cafile=certifi.where())
