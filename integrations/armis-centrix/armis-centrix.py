#!/usr/bin/env python3
"""
Armis Centrix to Veza OAA Integration Script
Collects identity and permission data from Armis Centrix and pushes to Veza.
"""
import argparse
import logging
import os
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

import requests
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission, OAAPropertyType

# Shorthand for permissions that represent administrative / full-control access
_ADMIN_PERMS = [
    OAAPermission.DataRead,
    OAAPermission.DataWrite,
    OAAPermission.MetadataRead,
    OAAPermission.MetadataWrite,
]

log = logging.getLogger(__name__)

# ── OAA permission registry ─────────────────────────────────────────────────
# Each entry: (oaa_permission_name, [OAAPermission types])
ARMIS_PERMISSIONS = [
    # Alerts
    ("alert.read",                      [OAAPermission.DataRead]),
    ("alert.manage",                    [OAAPermission.DataWrite]),
    ("alert.manage.resolve",            [OAAPermission.DataWrite]),
    ("alert.manage.ignore",             [OAAPermission.DataWrite]),
    ("alert.manage.whitelist",          [OAAPermission.DataWrite]),
    # Devices
    ("device.read",                     [OAAPermission.DataRead]),
    ("device.manage.edit",              [OAAPermission.DataWrite]),
    ("device.manage.create",            [OAAPermission.DataCreate]),
    ("device.manage.delete",            [OAAPermission.DataDelete]),
    ("device.manage.enforce",           [OAAPermission.DataWrite]),
    ("device.manage.tags",              [OAAPermission.DataWrite]),
    ("device.manage.merge",             [OAAPermission.DataWrite]),
    # Policies
    ("policy.read",                     [OAAPermission.DataRead]),
    ("policy.manage",                   [OAAPermission.DataWrite]),
    # Reports
    ("report.read",                     [OAAPermission.DataRead]),
    ("report.export",                   [OAAPermission.DataRead]),
    ("report.manage.create",            [OAAPermission.DataCreate]),
    ("report.manage.edit",              [OAAPermission.DataWrite]),
    ("report.manage.delete",            [OAAPermission.DataDelete]),
    # Risk Factors
    ("risk_factor.read",                [OAAPermission.DataRead]),
    ("risk_factor.manage",              [OAAPermission.DataWrite]),
    # Vulnerabilities
    ("vulnerability.read",              [OAAPermission.DataRead]),
    ("vulnerability.manage",            [OAAPermission.DataWrite]),
    # Users & Roles (settings.usersAndRoles)
    ("user.read",                       [OAAPermission.DataRead]),
    ("user.manage",                     [OAAPermission.DataWrite]),
    ("settings.usersAndRoles.read",     [OAAPermission.DataRead]),
    ("settings.usersAndRoles.manage",   _ADMIN_PERMS),
    # Integrations
    ("settings.integration.read",       [OAAPermission.DataRead]),
    ("settings.integration.manage",     [OAAPermission.DataWrite]),
    # Sites & Sensors
    ("settings.sitesAndSensors.read",   [OAAPermission.DataRead]),
    ("settings.sitesAndSensors.manage", [OAAPermission.DataWrite]),
    # General Settings
    ("settings.read",                   [OAAPermission.DataRead]),
    ("settings.manage",                 _ADMIN_PERMS),
    ("settings.auditLog",               [OAAPermission.DataRead]),
    ("settings.secretKey",              _ADMIN_PERMS),
    # Business Applications
    ("business_applications.read",      [OAAPermission.DataRead]),
    ("business_applications.manage",    [OAAPermission.DataWrite]),
    # PII / Advanced Permissions
    ("pii.deviceNames",                 [OAAPermission.DataRead]),
    ("pii.ipAddresses",                 [OAAPermission.DataRead]),
    ("pii.macAddresses",                [OAAPermission.DataRead]),
    ("pii.phoneNumbers",                [OAAPermission.DataRead]),
    ("pii.behavioral",                  [OAAPermission.DataRead]),
]

# Maps flattened Armis permission tree paths → OAA permission name.
# Multiple Armis paths can map to the same OAA perm; any True path grants it.
# Parent propagation is handled in PermissionMapper._is_granted().
PERM_MAP: dict[str, str] = {
    "alert.read":                               "alert.read",
    "alert.manage":                             "alert.manage",
    "alert.manage.resolve":                     "alert.manage.resolve",
    "alert.manage.ignore":                      "alert.manage.ignore",
    "alert.manage.whitelistDevices":            "alert.manage.whitelist",
    "device.read":                              "device.read",
    "device.manage.edit":                       "device.manage.edit",
    "device.manage.create":                     "device.manage.create",
    "device.manage.delete":                     "device.manage.delete",
    "device.manage.enforce":                    "device.manage.enforce",
    "device.manage.tags":                       "device.manage.tags",
    "device.manage.merge":                      "device.manage.merge",
    "policy.read":                              "policy.read",
    "policy.manage":                            "policy.manage",
    "report.read":                              "report.read",
    "report.export":                            "report.export",
    "report.manage.create":                     "report.manage.create",
    "report.manage.edit":                       "report.manage.edit",
    "report.manage.delete":                     "report.manage.delete",
    "risk_factor.read":                         "risk_factor.read",
    "risk_factor.manage":                       "risk_factor.manage",
    "vulnerability.read":                       "vulnerability.read",
    "vulnerability.manage":                     "vulnerability.manage",
    "user.read":                                "user.read",
    "user.manage":                              "user.manage",
    "settings.read":                            "settings.read",
    "settings.manage":                          "settings.manage",
    "settings.auditLog":                        "settings.auditLog",
    "settings.secretKey":                       "settings.secretKey",
    "settings.usersAndRoles.read":              "settings.usersAndRoles.read",
    "settings.usersAndRoles.manage":            "settings.usersAndRoles.manage",
    "settings.integration.read":               "settings.integration.read",
    "settings.integration.manage":             "settings.integration.manage",
    "settings.sitesAndSensors.read":            "settings.sitesAndSensors.read",
    "settings.sitesAndSensors.manage":          "settings.sitesAndSensors.manage",
    "business_applications.read":               "business_applications.read",
    "business_applications.manage":             "business_applications.manage",
    "advancedPermissions.device.deviceNames":       "pii.deviceNames",
    "advancedPermissions.device.ipAddresses":       "pii.ipAddresses",
    "advancedPermissions.device.macAddresses":      "pii.macAddresses",
    "advancedPermissions.device.phoneNumbers":      "pii.phoneNumbers",
    "advancedPermissions.behavioral.applicationName": "pii.behavioral",
    "advancedPermissions.behavioral.hostName":       "pii.behavioral",
    "advancedPermissions.behavioral.serviceName":    "pii.behavioral",
}


# ── Armis API client ─────────────────────────────────────────────────────────

class ArmisClient:
    def __init__(self, tenant: str, secret_key: str):
        self._base_url = f"https://{tenant}.armis.com"
        self._session = requests.Session()
        # Armis auth uses no "Bearer" prefix
        self._session.headers["Authorization"] = self._get_access_token(secret_key)

    def _get_access_token(self, secret_key: str) -> str:
        url = f"{self._base_url}/api/v1/access_token/"
        resp = self._session.post(
            url,
            data={"secret_key": secret_key},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=30,
        )
        resp.raise_for_status()
        body = resp.json()
        if not body.get("success"):
            raise RuntimeError(f"Armis authentication failed: {body}")
        token = body["data"]["access_token"]
        log.info("Authenticated with Armis at %s", self._base_url)
        return token

    def get_users(self) -> list[dict]:
        """Paginate through all console users."""
        users: list[dict] = []
        from_idx = 0
        page_size = 500
        while True:
            resp = self._session.get(
                f"{self._base_url}/api/v1/users/",
                params={"length": page_size, "from": from_idx},
                timeout=30,
            )
            resp.raise_for_status()
            page = resp.json()["data"]["users"]
            users.extend(page)
            log.debug("Fetched users page: %d items (from=%d)", len(page), from_idx)
            if len(page) < page_size:
                break
            from_idx += page_size
        log.info("Total Armis users fetched: %d", len(users))
        return users

    def get_roles(self) -> list[dict]:
        """Fetch all roles — single call, no pagination needed."""
        resp = self._session.get(f"{self._base_url}/api/v1/roles/", timeout=30)
        resp.raise_for_status()
        roles = resp.json()
        log.info("Total Armis roles fetched: %d", len(roles))
        return roles

    def get_sites(self) -> list[dict]:
        """Paginate through all sites (optional enrichment)."""
        sites: list[dict] = []
        from_idx = 0
        page_size = 500
        while True:
            resp = self._session.get(
                f"{self._base_url}/api/v1/sites/",
                params={"length": page_size, "from": from_idx},
                timeout=30,
            )
            resp.raise_for_status()
            page = resp.json()["data"].get("sites", [])
            sites.extend(page)
            if len(page) < page_size:
                break
            from_idx += page_size
        log.info("Total Armis sites fetched: %d", len(sites))
        return sites

    def get_boundaries(self) -> list[dict]:
        """Paginate through all boundaries (optional enrichment)."""
        boundaries: list[dict] = []
        from_idx = 0
        page_size = 500
        while True:
            resp = self._session.get(
                f"{self._base_url}/api/v1/boundaries/",
                params={"length": page_size, "from": from_idx},
                timeout=30,
            )
            resp.raise_for_status()
            data = resp.json().get("data", {})
            page = data.get("boundaries", [])
            boundaries.extend(page)
            if len(page) < page_size:
                break
            from_idx += page_size
        log.info("Total Armis boundaries fetched: %d", len(boundaries))
        return boundaries


# ── Permission mapper ─────────────────────────────────────────────────────────

class PermissionMapper:
    @staticmethod
    def flatten(perm_tree: dict, prefix: str = "") -> dict[str, bool]:
        """Recursively extract every node that has an 'all' flag."""
        result: dict[str, bool] = {}
        for key, value in perm_tree.items():
            path = f"{prefix}.{key}" if prefix else key
            if isinstance(value, dict):
                if "all" in value:
                    result[path] = bool(value["all"])
                result.update(PermissionMapper.flatten(value, path))
        return result

    @staticmethod
    def _is_granted(flat_perms: dict[str, bool], armis_key: str) -> bool:
        """True if the specific key or any ancestor 'all' flag is True."""
        if flat_perms.get(armis_key, False):
            return True
        parts = armis_key.split(".")
        for i in range(1, len(parts)):
            parent = ".".join(parts[:i])
            if flat_perms.get(parent, False):
                return True
        return False

    @classmethod
    def get_granted_permissions(cls, flat_perms: dict[str, bool]) -> set[str]:
        """Return the set of OAA permission names granted by this flat permission dict."""
        granted: set[str] = set()
        for armis_key, oaa_perm in PERM_MAP.items():
            if cls._is_granted(flat_perms, armis_key):
                granted.add(oaa_perm)
        return granted


# ── OAA payload builder ───────────────────────────────────────────────────────

class ArmisOAABuilder:
    def __init__(self, provider_name: str, datasource_name: str):
        self.app = CustomApplication(
            name=datasource_name,
            application_type=provider_name,
        )
        self._define_permissions()
        self._define_user_properties()

    def _define_permissions(self) -> None:
        for perm_name, oaa_types in ARMIS_PERMISSIONS:
            self.app.add_custom_permission(perm_name, oaa_types)

    def _define_user_properties(self) -> None:
        self.app.property_definitions.define_local_user_property(
            "two_factor_authentication", OAAPropertyType.BOOLEAN
        )
        self.app.property_definitions.define_local_user_property(
            "enforce_login_via_creds", OAAPropertyType.BOOLEAN
        )
        self.app.property_definitions.define_local_user_property(
            "report_permissions", OAAPropertyType.STRING
        )

    def build_roles(self, roles: list[dict]) -> None:
        """Create local_roles and assign permissions from the Armis permission tree."""
        mapper = PermissionMapper()
        for role_data in roles:
            role_id = str(role_data["roleId"])
            role_name = role_data["name"]
            role = self.app.add_local_role(role_name, unique_id=role_id)
            flat_perms = mapper.flatten(role_data.get("permissions", {}))
            granted = mapper.get_granted_permissions(flat_perms)
            if granted:
                role.add_permissions(sorted(granted))
            log.debug("Role %r (id=%s): %d OAA permissions granted", role_name, role_id, len(granted))

    def build_users(self, users: list[dict]) -> None:
        """Create local_users and assign roles from roleAssignment (authoritative field)."""
        for user_data in users:
            # Prefer username, fall back to email, then id
            username = (
                user_data.get("username")
                or user_data.get("email")
                or str(user_data["id"])
            )
            email = user_data.get("email") or None

            user = self.app.add_local_user(
                name=username,
                unique_id=str(user_data["id"]),
            )
            if email:
                user.email = email
            user.is_active = bool(user_data.get("isActive", True))

            user.set_property(
                "two_factor_authentication",
                bool(user_data.get("twoFactorAuthentication", False)),
            )
            user.set_property(
                "enforce_login_via_creds",
                bool(user_data.get("enforceLoginViaCreds", False)),
            )
            report_perms = user_data.get("reportPermissions") or "NONE"
            user.set_property("report_permissions", report_perms)

            # roleAssignment is authoritative; can be null (no role assigned)
            role_assignments = user_data.get("roleAssignment") or []
            for assignment in role_assignments:
                for role_name in assignment.get("name", []):
                    user.add_role(role_name)
                    log.debug("User %r → role %r", username, role_name)

            log.debug(
                "User %r (id=%s): active=%s, roles=%d",
                username,
                user_data["id"],
                user.is_active,
                sum(len(a.get("name", [])) for a in role_assignments),
            )


# ── Configuration & push ──────────────────────────────────────────────────────

def load_config(args: argparse.Namespace) -> dict:
    env_file = getattr(args, "env_file", ".env")
    if env_file and os.path.exists(env_file):
        load_dotenv(env_file)
    return {
        "armis_tenant":    getattr(args, "armis_tenant", None)    or os.getenv("ARMIS_TENANT", ""),
        "armis_secret_key": getattr(args, "armis_secret_key", None) or os.getenv("ARMIS_SECRET_KEY", ""),
        "veza_url":        getattr(args, "veza_url", None)         or os.getenv("VEZA_URL", ""),
        "veza_api_key":    getattr(args, "veza_api_key", None)     or os.getenv("VEZA_API_KEY", ""),
    }


def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool = False,
    save_json: bool = False,
) -> None:
    if save_json:
        import json
        payload_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "armis_oaa_payload.json")
        with open(payload_path, "w", encoding="utf-8") as fh:
            json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("OAA payload saved to %s", payload_path)
        print(f"Payload saved → {payload_path}")

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping Veza push")
        print("[DRY RUN] Payload built successfully — skipping Veza push")
        return

    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)
        log.info("Successfully pushed to Veza")
        print("Successfully pushed to Veza")
    except OAAClientError as e:
        log.error("Veza push failed: %s — %s (HTTP %s)", e.error, e.message, e.status_code)
        if hasattr(e, "details"):
            for d in e.details:
                log.error("  Detail: %s", d)
        sys.exit(1)


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Armis Centrix → Veza OAA Integration",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Credentials are read from env vars or the --env-file. CLI args override both.",
    )
    # Connection
    parser.add_argument("--env-file", default=".env", metavar="PATH",
                        help="Path to .env file (default: .env)")
    parser.add_argument("--armis-tenant", default=None, metavar="SUBDOMAIN",
                        help="Armis tenant subdomain (e.g. demo-veza). Env: ARMIS_TENANT")
    parser.add_argument("--armis-secret-key", default=None, metavar="KEY",
                        help="Armis API secret key. Env: ARMIS_SECRET_KEY")
    parser.add_argument("--veza-url", default=None, metavar="URL",
                        help="Veza URL. Env: VEZA_URL")
    parser.add_argument("--veza-api-key", default=None, metavar="KEY",
                        help="Veza API key. Env: VEZA_API_KEY")
    # OAA identity
    parser.add_argument("--provider-name", default="Armis",
                        help="Provider name in Veza (default: Armis)")
    parser.add_argument("--datasource-name", default="Armis Centrix",
                        help="Datasource name in Veza (default: Armis Centrix)")
    # Run control
    parser.add_argument("--dry-run", action="store_true",
                        help="Build OAA payload without pushing to Veza")
    parser.add_argument("--save-json", action="store_true",
                        help="Save OAA payload as JSON for inspection")
    parser.add_argument("--log-level", default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                        help="Logging verbosity (default: INFO)")
    parser.add_argument("--data-dir", default=None, metavar="PATH",
                        help="(Not used — data is fetched live from the Armis API)")
    # Optional enrichment
    parser.add_argument("--skip-sites", action="store_true",
                        help="Skip fetching sites (optional enrichment)")
    parser.add_argument("--skip-boundaries", action="store_true",
                        help="Skip fetching boundaries (optional enrichment)")
    return parser.parse_args()


def _setup_logging(log_level: str = "INFO") -> None:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file, when="h", interval=1, backupCount=24, encoding="utf-8"
    )
    handler.setFormatter(logging.Formatter(
        fmt="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    ))
    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper()))
    root.addHandler(handler)


def main() -> None:
    print("Armis Centrix → Veza OAA Integration")
    args = parse_args()
    _setup_logging(args.log_level)
    config = load_config(args)

    # Validate required config
    missing = []
    if not config["armis_tenant"]:
        missing.append("ARMIS_TENANT (--armis-tenant)")
    if not config["armis_secret_key"]:
        missing.append("ARMIS_SECRET_KEY (--armis-secret-key)")
    if not args.dry_run:
        if not config["veza_url"]:
            missing.append("VEZA_URL (--veza-url)")
        if not config["veza_api_key"]:
            missing.append("VEZA_API_KEY (--veza-api-key)")
    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        print(f"ERROR: Missing required config: {', '.join(missing)}")
        sys.exit(1)

    # Fetch data from Armis
    client = ArmisClient(config["armis_tenant"], config["armis_secret_key"])
    users = client.get_users()
    roles = client.get_roles()

    # Build OAA payload
    builder = ArmisOAABuilder(args.provider_name, args.datasource_name)
    builder.build_roles(roles)
    builder.build_users(users)

    log.info(
        "OAA payload built: %d users, %d roles",
        len(users), len(roles),
    )
    print(f"Payload built: {len(users)} users, {len(roles)} roles")

    push_to_veza(
        veza_url=config["veza_url"],
        veza_api_key=config["veza_api_key"],
        provider_name=args.provider_name,
        datasource_name=args.datasource_name,
        app=builder.app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )


if __name__ == "__main__":
    main()
