"""
KDM ERPNext startup configuration.

Creates the Frappe Social Login Key for Authentik OIDC. Called once per
container start by kdm-entrypoint.sh after migrations complete.

Authentication flow
-------------------
1. User visits ERPNext → Frappe checks session → Guest
2. Frappe redirects to /login
3. erpnext-proxy nginx catches /login → 302 to login_via_provider?provider=Authentik
4. Frappe calls login_via_provider → looks up "Authentik" Social Login Key
5. Frappe builds authorization URL → redirects browser to Authentik
6. Authentik sees existing KDM/k-client session → immediately approves
7. Authentik redirects back with auth code to Frappe callback URL
8. Frappe exchanges code (server-side via nginx-gateway) → access token → userinfo
9. Frappe creates/updates User document → logs in → user sees the desk

Required env vars (injected by KDM provisioner):
  OIDC_CLIENT_ID      Authentik OAuth2 client ID
  OIDC_CLIENT_SECRET  Authentik OAuth2 client secret
  OIDC_APP_SLUG       Authentik application slug (e.g. erpnext-from-kadmap-ws-general)
  AUTHENTIK_URL       Browser-facing KDM URL (e.g. https://kdm-serial.local)
  APP_PUBLIC_URL      Public URL of this ERPNext instance

Networking note
---------------
Token exchange and userinfo calls are made server-side by Frappe from inside the
erpnext-web container. We route these through nginx-gateway's /oidc-internal/
HTTP proxy rather than directly to authentik-server:9000, because nginx sets
"Host: KDM_HOSTNAME" which Authentik requires to build correct issuer URLs.
"""
import os
import sys

import frappe


def seed_authentik_provider() -> None:
    """
    Create (or update) the "Authentik" Social Login Key from env vars.

    Calls sys.exit(1) when OIDC env vars are missing so the entrypoint can
    detect the failure and keep password login enabled rather than locking
    the administrator out.
    """
    client_id      = os.environ.get("OIDC_CLIENT_ID", "")
    client_secret  = os.environ.get("OIDC_CLIENT_SECRET", "")
    authentik_url  = os.environ.get("AUTHENTIK_URL", "").rstrip("/")
    oidc_app_slug  = os.environ.get("OIDC_APP_SLUG", "")
    app_public_url = os.environ.get("APP_PUBLIC_URL", "").rstrip("/")

    if not all([client_id, client_secret, authentik_url, oidc_app_slug, app_public_url]):
        frappe.logger().warning(
            "KDM: OIDC env vars missing — Social Login Key NOT configured. "
            "Password login will remain enabled. "
            f"(client_id={bool(client_id)} client_secret={bool(client_secret)} "
            f"authentik_url={bool(authentik_url)} oidc_app_slug={bool(oidc_app_slug)} "
            f"app_public_url={bool(app_public_url)})"
        )
        sys.exit(1)

    # Authorization URL — browser-facing; the user's browser is redirected here.
    authorize_url = f"{authentik_url}/application/o/{oidc_app_slug}/authorize/"

    # Token + userinfo — server-side calls made by Frappe from inside erpnext-web.
    # nginx-gateway's /oidc-internal/ HTTP proxy forwards to authentik-server:9000
    # with Host: KDM_HOSTNAME so Authentik validates the issuer correctly.
    access_token_url = f"http://nginx-gateway/oidc-internal/{oidc_app_slug}/token/"
    userinfo_url     = "http://nginx-gateway/oidc-internal/userinfo/"

    redirect_url = f"{app_public_url}/api/method/frappe.integrations.oauth2_logins.custom"

    if frappe.db.exists("Social Login Key", "Authentik"):
        doc = frappe.get_doc("Social Login Key", "Authentik")
    else:
        doc = frappe.new_doc("Social Login Key")
        doc.name = "Authentik"

    doc.social_login_provider             = "Custom"
    doc.provider_name                     = "Authentik"
    doc.enable_social_login               = 1
    doc.sign_ups                          = "Allow"
    doc.client_id                         = client_id
    doc.client_secret                     = client_secret
    doc.base_url                          = f"{authentik_url}/application/o/{oidc_app_slug}/"
    doc.authorize_url                     = authorize_url
    doc.access_token_url                  = access_token_url
    doc.redirect_url                      = redirect_url
    doc.api_endpoint                      = userinfo_url
    doc.user_id_property                  = "email"
    doc.trust_email_without_verified_claim = 1
    doc.auth_url_data                     = '{"scope": "openid profile email"}'
    doc.save(ignore_permissions=True)
    frappe.db.commit()

    system_settings = frappe.get_single("System Settings")
    if not system_settings.enable_social_login:
        system_settings.enable_social_login = 1
        system_settings.save(ignore_permissions=True)
        frappe.db.commit()

    frappe.logger().info(f"KDM: Authentik OIDC configured — provider slug: {oidc_app_slug}")
