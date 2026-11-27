"""
KDM ERPNext startup configuration.

Authentication is handled by the KDM trusted-session mechanism:
  erpnext.kdm_auth.session.auto_login_from_kdm_session (before_request hook)

This module is kept for backward compatibility with the entrypoint call.
"""

import frappe


def seed_authentik_provider():
    """No-op — authentication is handled by the KDM trusted session hook."""
    frappe.logger().info("KDM: auth handled by trusted session hook; OIDC setup skipped")
