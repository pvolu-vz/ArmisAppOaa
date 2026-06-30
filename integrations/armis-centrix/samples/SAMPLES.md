# Armis Centrix — Sample Data

This connector fetches data live from the Armis REST API. No sample files are required for deployment.

For offline testing or payload inspection, you can save the API responses manually:

## What to capture

### Users (`/api/v1/users/`)
Save a JSON file (`sample_users.json`) with the full response body from:
```
GET https://<tenant>.armis.com/api/v1/users/?length=500&from=0
```

Expected shape:
```json
{
  "data": {
    "users": [
      {
        "id": 21,
        "name": "Adam Johnson",
        "username": "adam.johnson@example.com",
        "email": "adam.johnson@example.com",
        "isActive": true,
        "twoFactorAuthentication": false,
        "enforceLoginViaCreds": true,
        "role": "ADMIN",
        "roleAssignment": [{ "name": ["Admin"] }],
        "reportPermissions": "EXPORT"
      }
    ]
  },
  "success": true
}
```

### Roles (`/api/v1/roles/`)
Save a JSON file (`sample_roles.json`) with the full response body from:
```
GET https://<tenant>.armis.com/api/v1/roles/
```

Expected shape — an array of role objects:
```json
[
  {
    "roleId": 1,
    "name": "Admin",
    "permissions": {
      "alert": { "all": true, "read": { "all": true }, "manage": { "all": true } },
      "device": { "all": true, "read": { "all": true }, "manage": { "all": true } }
    }
  }
]
```

## Running a dry-run
Once you have live credentials, run without pushing to Veza:
```bash
python3 armis-centrix.py --dry-run --save-json --log-level DEBUG
```
The payload will be written to `armis_oaa_payload.json` for inspection.
