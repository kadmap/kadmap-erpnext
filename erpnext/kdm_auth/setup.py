"""
KDM marketplace build: seed Authentik OIDC provider into Social Login Key.

Called by docker/kdm-entrypoint.sh on every container start so the config
stays in sync with whatever env vars the MKDM pipeline injects.

Required env vars:
  AUTHENTIK_URL      - full base URL of the KDM's Authentik (e.g. https://auth.mycompany.local)
  OIDC_CLIENT_ID     - client_id from the Authentik OAuth2 provider application
  OIDC_CLIENT_SECRET - client_secret from the Authentik OAuth2 provider application

Optional:
  OIDC_APP_SLUG      - Authentik application slug (defaults to "erpnext")
"""

import os

import frappe


def seed_authentik_provider():
    authentik_url = os.environ.get("AUTHENTIK_URL", "").rstrip("/")
    client_id = os.environ.get("OIDC_CLIENT_ID", "")
    client_secret = os.environ.get("OIDC_CLIENT_SECRET", "")
    app_slug = os.environ.get("OIDC_APP_SLUG", "erpnext")

    if not all([authentik_url, client_id, client_secret]):
        frappe.log_error(
            "KDM: AUTHENTIK_URL, OIDC_CLIENT_ID, and OIDC_CLIENT_SECRET must all be set",
            "KDM OIDC Setup",
        )
        return

    provider_name = "Authentik"

    if frappe.db.exists("Social Login Key", provider_name):
        doc = frappe.get_doc("Social Login Key", provider_name)
    else:
        doc = frappe.new_doc("Social Login Key")
        doc.name = provider_name

    doc.update(
        {
            "enable_social_login": 1,
            "provider_name": provider_name,
            "client_id": client_id,
            "client_secret": client_secret,
            "base_url": authentik_url,
            "custom_base_url": 1,
            "authorize_url": f"{authentik_url}/application/o/{app_slug}/authorize/",
            "access_token_url": f"{authentik_url}/application/o/{app_slug}/token/",
            "api_endpoint": f"{authentik_url}/application/o/userinfo/",
            "redirect_to": "/desk",
            "user_id_property": "sub",
            "icon": f"{authentik_url}/application/o/{app_slug}/icon/",
        }
    )
    doc.save(ignore_permissions=True)
    frappe.db.commit()

    frappe.logger().info("KDM: Authentik Social Login Key seeded for %s", authentik_url)
