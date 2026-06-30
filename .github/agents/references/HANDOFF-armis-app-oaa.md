# Handoff: Armis as an Application — Veza OAA Connector

## Goal

Build a Python script that models **Armis Centrix itself as an application** in Veza — mapping which console users exist, which roles they hold, and what actions each role permits. This is distinct from the device-risk OAA connector (`HANDOFF-oaa-connector.md`), which maps device posture to identity.

The output answers the question: **"Who can do what inside the Armis platform?"**

---

## Authentication

```
POST https://<tenant>.armis.com/api/v1/access_token/
Content-Type: application/x-www-form-urlencoded

secret_key=<SECRET_KEY>
```

Response:
```json
{ "data": { "access_token": "<token>" }, "success": true }
```

All subsequent requests use header: `Authorization: <access_token>` (no "Bearer" prefix).

Demo tenant: `demo-veza.armis.com`

---

## API Endpoints (confirmed working)

### 1. List console users
```
GET /api/v1/users/?length=500&from=0
```

**Confirmed response shape** (from live API):
```json
{
  "data": {
    "users": [
      {
        "id": 18,
        "name": "Biomed User",
        "username": "BiomedUserACME",
        "email": "biomedanalyst@acmehealth.com",
        "title": "Biomed Analyst - ACME Health",
        "location": null,
        "phone": null,
        "isActive": true,
        "lastLoginTime": null,
        "twoFactorAuthentication": false,
        "enforceLoginViaCreds": false,
        "role": "READ_ONLY",
        "roleAssignment": [{ "name": ["Read Only"] }],
        "reportPermissions": "NONE",
        "atiEulaSigningDate": null,
        "povEulaSigningDate": null,
        "prodEulaSigningDate": null
      }
    ]
  },
  "success": true
}
```

**Field notes:**
- `role` — legacy enum (`ADMIN`, `READ_ONLY`, or `null`). Unreliable for multi-role users; ignore.
- `roleAssignment` — authoritative. Array of `{ "name": ["Role Name", ...] }`. Can be `null` (no role assigned). User 21 (Admin) has `enforceLoginViaCreds: true` — local password auth.
- `reportPermissions` — enum: `"NONE"`, `"EXPORT"`, or `null`.
- Pagination: no `total` field in users response. Paginate until the returned array is shorter than `length`.

**Users seen in demo (17 users, IDs 5–21):**
- IDs 5–17: `roleAssignment: null` (no role assigned — demo/test users)
- ID 18: `Read Only`
- ID 19: `Read Only` + `Asset Manager` (multi-role)
- ID 20: `Security Analyst`
- ID 21: `Admin`

### 2. List roles with full permission tree
```
GET /api/v1/roles/
```

No pagination needed — returns all roles in a flat array. No `length`/`from` params required.

**Confirmed response shape:**
```json
[
  {
    "roleId": 1,
    "name": "Admin",
    "viprRole": false,
    "vmdrRole": false,
    "permissions": { ... }
  }
]
```

**Roles found in demo (8 roles):**

| roleId | name | Notes |
|--------|------|-------|
| 1 | Admin | Full access everywhere |
| 2 | Read Only | View-only (alerts, devices, policies, reports, vulnerabilities) |
| 3 | User Manager | Read only + full usersAndRoles manage |
| 4 | Asset Manager | Read only + device edit/tags, policy manage, report manage |
| 5 | Security Analyst | Read only + alert manage, device enforce/tags, policy manage, integrations |
| 6 | Integrations Manager | Read only + integrations manage, sitesAndSensors manage |
| 10 | Read Only Admin | Read only + full settings read, usersAndRoles read |
| 11 | Read Only No PII | Read only, PII masked (advancedPermissions all false) |

**Permission tree structure** (all boolean `all` fields):
```
permissions:
  alert:
    read.all
    manage.all → manage.resolve.all, manage.ignore.all, manage.whitelistDevices.all
  device:
    read.all
    manage.all → manage.create, manage.delete, manage.edit, manage.enforce, manage.merge,
                 manage.tags, manage.request_deleted_data
  policy:
    read.all
    manage.all
  report:
    read.all
    export.all
    manage.all → manage.create, manage.delete, manage.edit
  risk_factor:
    read.all
    manage.all → manage.customization (create/disable/edit), manage.status (ignore/resolve)
  vulnerability:
    read.all
    manage.all → manage.ignore, manage.resolve, manage.write
  user:
    read.all
    manage.all → manage.upsert
  business_applications:
    read.all
    manage.all → manage.upsert, manage.delete
  settings:
    read.all
    manage.all
    auditLog.all
    secretKey.all
    securitySettings.all
    boundary.read.all / boundary.manage.all (create/delete/edit)
    integration.read.all / integration.manage.all
    sitesAndSensors.read.all / sitesAndSensors.manage.all (sensors/sites)
    usersAndRoles.read.all / usersAndRoles.manage.all → roles (create/delete/edit), users (create/delete/edit)
    businessImpact.read.all / businessImpact.manage.all
    collector.read.all / collector.manage.all
    customProperties.read.all / customProperties.manage.all
    internalIps.read.all / internalIps.manage.all
    lists.read.all / lists.manage.all
    notifications.read.all / notifications.manage.all
    oidc.read.all / oidc.manage.all
    saml.read.all / saml.manage.all
    packet_capture.manage.all
  advancedPermissions (PII visibility):
    device.deviceNames.all
    device.ipAddresses.all
    device.macAddresses.all
    device.phoneNumbers.all
    behavioral.applicationName.all
    behavioral.hostName.all
    behavioral.serviceName.all
```

### 3. List sites (for scoped access metadata)
```
GET /api/v1/sites/?length=500&from=0
```

Response: `{ "data": { "sites": [...], "count": N, "next": N, "prev": N } }`

Each site: `{ "id": "40072", "name": "Palo Alto Enterprise", "location": "Palo Alto", "lat": ..., "lng": ..., "parentId": "40075" }`

Sites are hierarchical (parentId). Demo has 10+ sites across USA, Switzerland, Healthcare.

### 4. List boundaries
```
GET /api/v1/boundaries/?length=500&from=0
```

Each boundary: `{ "id": 1, "name": "Corporate", "ruleAql": null, "affectedSites": "" }`

Demo boundaries: Corporate, Diagnostic Imaging, Nursing Units, Medical, BYOD, BMS, Guest, RLN, Internal, Stores.

> **Note:** The current `/api/v1/users/` response does **not** include allowed sites or boundaries per user. These fields are set in the UI but may not be exposed in the v1 users API. Include as optional enrichment if found; proceed without if not.

---

## Veza OAA Data Model

### Concept mapping

| Armis concept | Veza OAA concept |
|---------------|-----------------|
| Console user | `local_user` |
| Role (Admin, Read Only, etc.) | `local_role` |
| Permission (e.g. `alert.read`) | `permission` on the `CustomApplication` |
| User → role assignment | `local_user.add_role(role_name)` |
| Role → permission grants | `local_role.add_permission(perm_name, apply_to_application=True)` |

**Why `local_role` and not `local_group`:** Armis is a pure RBAC system — users are assigned roles directly, and roles define permissions. There is no concept of "a group of users" in Armis; the role itself is the permission container. `local_role` models this accurately in Veza. Using `local_group` would misrepresent the access model and produce incorrect effective-permission graphs in Veza's authorization intelligence.

### OAA permissions to define

Flatten the role permission tree into discrete named permissions. Use dot-notation:

```python
ARMIS_PERMISSIONS = [
    # Alerts
    ("alert.read",                  [OAAPermission.DataRead]),
    ("alert.manage",                [OAAPermission.DataWrite]),
    ("alert.manage.resolve",        [OAAPermission.DataWrite]),
    ("alert.manage.ignore",         [OAAPermission.DataWrite]),
    ("alert.manage.whitelist",      [OAAPermission.DataWrite]),
    # Devices
    ("device.read",                 [OAAPermission.DataRead]),
    ("device.manage.edit",          [OAAPermission.DataWrite]),
    ("device.manage.create",        [OAAPermission.DataCreate]),
    ("device.manage.delete",        [OAAPermission.DataDelete]),
    ("device.manage.enforce",       [OAAPermission.DataWrite]),
    ("device.manage.tags",          [OAAPermission.DataWrite]),
    ("device.manage.merge",         [OAAPermission.DataWrite]),
    # Policies
    ("policy.read",                 [OAAPermission.DataRead]),
    ("policy.manage",               [OAAPermission.DataWrite]),
    # Reports
    ("report.read",                 [OAAPermission.DataRead]),
    ("report.export",               [OAAPermission.DataRead]),
    ("report.manage.create",        [OAAPermission.DataCreate]),
    ("report.manage.edit",          [OAAPermission.DataWrite]),
    ("report.manage.delete",        [OAAPermission.DataDelete]),
    # Risk Factors
    ("risk_factor.read",            [OAAPermission.DataRead]),
    ("risk_factor.manage",          [OAAPermission.DataWrite]),
    # Vulnerabilities
    ("vulnerability.read",          [OAAPermission.DataRead]),
    ("vulnerability.manage",        [OAAPermission.DataWrite]),
    # Users & Roles (settings.usersAndRoles)
    ("user.read",                   [OAAPermission.DataRead]),
    ("user.manage",                 [OAAPermission.DataWrite]),
    ("settings.usersAndRoles.read", [OAAPermission.DataRead]),
    ("settings.usersAndRoles.manage", [OAAPermission.Admin]),
    # Integrations
    ("settings.integration.read",   [OAAPermission.DataRead]),
    ("settings.integration.manage", [OAAPermission.DataWrite]),
    # Sites & Sensors
    ("settings.sitesAndSensors.read",   [OAAPermission.DataRead]),
    ("settings.sitesAndSensors.manage", [OAAPermission.DataWrite]),
    # General Settings
    ("settings.read",               [OAAPermission.DataRead]),
    ("settings.manage",             [OAAPermission.Admin]),
    ("settings.auditLog",           [OAAPermission.DataRead]),
    ("settings.secretKey",          [OAAPermission.Admin]),
    # Business Applications
    ("business_applications.read",  [OAAPermission.DataRead]),
    ("business_applications.manage",[OAAPermission.DataWrite]),
    # PII / Advanced Permissions
    ("pii.deviceNames",             [OAAPermission.DataRead]),
    ("pii.ipAddresses",             [OAAPermission.DataRead]),
    ("pii.macAddresses",            [OAAPermission.DataRead]),
    ("pii.phoneNumbers",            [OAAPermission.DataRead]),
    ("pii.behavioral",              [OAAPermission.DataRead]),
]
```

### Permission flattening logic

The role permission tree uses `all: true/false` at each node. A permission is granted if the leaf node or any ancestor's `all` is `true`. Walk the tree recursively:

```python
def flatten_permissions(perm_tree: dict, prefix: str = "") -> dict[str, bool]:
    """Recursively extract leaf permissions from Armis role permission tree."""
    result = {}
    for key, value in perm_tree.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            if "all" in value:
                result[path] = value["all"]
            result.update(flatten_permissions(value, path))
    return result
```

Map the flattened keys to your named OAA permissions. Example:
- `alert.read.all == True` → role grants `alert.read`
- `settings.usersAndRoles.manage.roles.create.all == True` → role grants `settings.usersAndRoles.manage`

---

## Script Architecture

```
armis_app_oaa.py
├── ArmisClient
│   ├── get_access_token() → str
│   ├── get_users() → list[dict]          # paginated
│   ├── get_roles() → list[dict]          # single call
│   ├── get_sites() → list[dict]          # paginated, optional
│   └── get_boundaries() → list[dict]     # paginated, optional
│
├── PermissionMapper
│   ├── flatten_role_permissions(role_permissions: dict) → dict[str, bool]
│   └── map_to_oaa_permissions(flat_perms: dict) → list[str]
│
├── ArmisOAABuilder
│   ├── build_application() → CustomApplication
│   ├── build_local_roles(roles) → None      # roles → local_roles + permission grants
│   ├── build_local_users(users) → None      # users + role assignments
│   └── build_payload() → dict
│
├── VezaClient
│   └── push_oaa(app: CustomApplication) → None
│
└── main()
    1. auth → Armis access token
    2. fetch users, roles, sites, boundaries
    3. build CustomApplication
    4. define all permissions on app
    5. create local_roles from roles, assign permissions
    6. create local_users, assign roles
    7. validate
    8. push to Veza
```

---

## Key Implementation Details

### User with no role
Several users have `roleAssignment: null`. Create the `local_user` but do not call `add_group()`. They will appear in Veza as Armis users with no permissions.

### Multi-role users
User 19 (Asset Inventory) has two roles: `["Read Only", "Asset Manager"]`. The `roleAssignment` structure is:
```json
[{ "name": ["Read Only", "Asset Manager"] }]
```
Iterate `role_assignment["name"]` and call `local_user.add_role()` for each.

### Report permissions
The `reportPermissions` field (`NONE`, `EXPORT`, `null`) is a separate legacy permission gate. Map it as a user-level custom property, not a group permission.

### Two-factor authentication and auth type
Expose as user properties:
- `twoFactorAuthentication: bool`
- `enforceLoginViaCreds: bool` (local password auth when true; SSO otherwise)

### Role ID as stable identifier
Use `roleId` (int) as the stable identifier for groups, not `name` (which could be renamed). Store `name` as display label.

---

## Environment Variables

```bash
ARMIS_TENANT=demo-veza              # subdomain only
ARMIS_SECRET_KEY=<secret_key>       # v1 auth
VEZA_URL=https://<tenant>.vezacloud.com
VEZA_API_KEY=<api_key>
```

---

## Acceptance Criteria

1. All 17 users from the demo appear as `local_users` in Veza, linked to `armis` application
2. All 8 roles appear as `local_roles` with the correct permission grants
3. User ID 19 (Asset Inventory) is assigned both `Read Only` and `Asset Manager` roles
4. User IDs 5–17 (no role) appear as users with zero role assignments
5. User ID 11 (Read Only No PII) role has `pii.*` permissions set to false/absent
6. Admin role has all permissions granted
7. Script runs without error on the demo tenant using a fresh access token
8. Payload validates before push (no missing required fields)

---

## Reference Files

| File | Purpose |
|------|---------|
| `armis-mcp-capabilities.md` | MCP/ASQ reference |
| `hford-devices-oaa.json` | Device-risk OAA example (different use case) |
| `HANDOFF-oaa-connector.md` | Device-risk connector handoff (different script) |
| `HANDOFF-armis-app-oaa.md` | This document |

---

## Appendix: Live API Samples

### Sample user (with role)
```json
{
  "id": 21,
  "name": "Adam Johnson",
  "username": "adam.johnson3@servicenow.com",
  "email": "adam.johnson3@servicenow.com",
  "title": "",
  "location": "",
  "phone": "",
  "isActive": true,
  "lastLoginTime": null,
  "twoFactorAuthentication": false,
  "enforceLoginViaCreds": true,
  "role": "ADMIN",
  "roleAssignment": [{ "name": ["Admin"] }],
  "reportPermissions": "EXPORT"
}
```

### Sample role (abbreviated — Admin)
```json
{
  "roleId": 1,
  "name": "Admin",
  "viprRole": false,
  "vmdrRole": false,
  "permissions": {
    "alert":       { "all": true,  "read": { "all": true }, "manage": { "all": true, "resolve": { "all": true }, "ignore": { "all": true } } },
    "device":      { "all": true,  "read": { "all": true }, "manage": { "all": true, "edit": { "all": true }, "delete": { "all": true } } },
    "policy":      { "all": true,  "read": { "all": true }, "manage": { "all": true } },
    "report":      { "all": true,  "read": { "all": true }, "export": { "all": true }, "manage": { "all": true } },
    "vulnerability":{ "all": true, "read": { "all": true }, "manage": { "all": true } },
    "settings":    { "all": true,  "read": { "all": true }, "manage": { "all": true }, "secretKey": { "all": true }, "usersAndRoles": { "all": true, "manage": { "all": true } } },
    "advancedPermissions": { "all": true, "device": { "all": true, "deviceNames": { "all": true }, "ipAddresses": { "all": true } } }
  }
}
```

### Sample role (abbreviated — Read Only No PII, roleId 11)
```json
{
  "roleId": 11,
  "name": "Read Only No PII",
  "permissions": {
    "alert":    { "read": { "all": true }, "manage": { "all": false } },
    "device":   { "read": { "all": true }, "manage": { "all": false } },
    "settings": { "all": false, "read": { "all": true }, "manage": { "all": false } },
    "advancedPermissions": { "all": false, "device": { "all": false, "deviceNames": { "all": false }, "ipAddresses": { "all": false }, "macAddresses": { "all": false }, "phoneNumbers": { "all": false } } }
  }
}
```
