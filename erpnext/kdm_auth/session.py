"""
KDM session hooks — applied via erpnext/hooks.py.

  suppress_user_welcome_email  doc_events → User → before_insert
      Prevents Frappe sending "Welcome to ERPNext" emails; Authentik handles
      user onboarding so these emails are redundant and confusing.

  on_session_creation          on_session_creation hook
      On first OIDC login, ensures the user has at least one role so they can
      reach the desk. Administrators can tighten permissions afterwards.

  block_password_reset         override_whitelisted_methods
      Replaces frappe.core.doctype.user.user.reset_password so the endpoint
      returns a clear error instead of sending a reset email.
"""

import frappe
from frappe import _


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
