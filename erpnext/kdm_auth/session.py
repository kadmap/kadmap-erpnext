"""
KDM session hooks — applied via erpnext/hooks.py.

  auto_login_from_kdm_session  before_request hook
      Validates the user's KDM Django session cookie against the KDM API and
      auto-logs them into ERPNext.  No login page is ever shown; the user's
      existing k-client/Authentik session is the sole credential.

  suppress_user_welcome_email  doc_events → User → before_insert
      Prevents Frappe sending "Welcome to ERPNext" emails.

  on_session_creation          on_session_creation hook
      On first login, ensures the user has at least one role so they can
      reach the desk.

  block_password_reset         override_whitelisted_methods
      Replaces frappe.core.doctype.user.user.reset_password so the endpoint
      returns a clear error instead of sending a reset email.
"""

import os

import frappe
from frappe import _

# Paths that never need auto-login (assets, API, sockets, etc.)
_SKIP_PREFIXES = ("/api/", "/assets/", "/files/", "/__/", "/socket.io", "/favicon", "/robots")


def auto_login_from_kdm_session():
    """
    Frappe before_request hook: validate the browser's KDM session cookie
    against the KDM API and auto-login the user into ERPNext.

    Runs before every request; exits immediately when:
    - The user already has a valid ERPNext session (not Guest).
    - The request is for a non-HTML path (assets, API, etc.).
    - No 'sessionid' cookie is present.
    - The KDM API does not confirm the session (network error, 401, etc.).
    """
    # Already authenticated — nothing to do.
    if getattr(frappe.local, "session", None) and frappe.session.user not in ("", "Guest"):
        return

    # Avoid re-running within the same request lifecycle.
    if getattr(frappe.local, "_kdm_auto_login_attempted", False):
        return
    frappe.local._kdm_auto_login_attempted = True

    # Skip non-page requests (assets, API calls, WebSocket handshakes, etc.)
    path = getattr(frappe.request, "path", "")
    if any(path.startswith(p) for p in _SKIP_PREFIXES):
        return

    session_key = frappe.request.cookies.get("sessionid", "")
    if not session_key:
        return

    kdm_url = os.environ.get("KDM_API_INTERNAL_URL", "http://django-api:8000").rstrip("/")
    try:
        import requests as _req
        resp = _req.get(
            f"{kdm_url}/api/marketplace/isv-session/",
            cookies={"sessionid": session_key},
            timeout=2,
        )
    except Exception:
        return

    if resp.status_code != 200:
        return

    email = resp.json().get("email", "")
    if not email:
        return

    # Create the user in ERPNext if this is their first access.
    if not frappe.db.exists("User", email):
        _ensure_frappe_user(email, resp.json().get("name", ""))

    # Login without password — sets the Frappe session cookie in the response
    # so subsequent requests come in already authenticated.
    frappe.local.login_manager.login_as(email)
    frappe.db.commit()


def _ensure_frappe_user(email: str, full_name: str = "") -> None:
    """Create a minimal ERPNext User document for a first-time KDM login."""
    parts = full_name.strip().split(" ", 1) if full_name.strip() else []
    user = frappe.new_doc("User")
    user.email = email
    user.first_name = parts[0] if parts else email.split("@")[0]
    user.last_name = parts[1] if len(parts) > 1 else ""
    user.enabled = 1
    user.user_type = "System User"
    user.send_welcome_email = 0
    user.save(ignore_permissions=True)
    frappe.db.commit()


def suppress_user_welcome_email(doc, method=None):
    doc.send_welcome_email = 0


def on_session_creation(login_manager):
    user = frappe.get_cached_doc("User", login_manager.user)

    # Skip Administrator and Guest — they are not OIDC-provisioned users.
    if user.name in ("Administrator", "Guest"):
        return

    # If the user already has roles assigned (returning user), nothing to do.
    if user.roles:
        return

    # Assign the default "All" role profile so the user can at least reach the
    # desk. KDM admins configure proper roles through Authentik groups → ERPNext
    # role profiles mapping.
    if frappe.db.exists("Role Profile", "All"):
        user.role_profile_name = "All"
    else:
        # Fallback: directly grant the built-in All role
        user.append("roles", {"role": "All"})

    user.save(ignore_permissions=True)
    frappe.db.commit()


@frappe.whitelist(allow_guest=True)
def block_password_reset(**kwargs):
    frappe.throw(
        _("Password reset is disabled. Please sign in using your organisation's SSO."),
        frappe.PermissionError,
    )
