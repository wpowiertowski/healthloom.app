# CloudKit schema

`schema.ckdb` is the schema of the `iCloud.app.healthloom` container. It's the one
definition: the app's record builders (`HealthLoomApp/iCloud/CloudSyncPayload.swift`)
must produce exactly these fields and types, and `CloudKitSchemaTests` fails if they
drift apart.

- **Record types:** `SyncSettings`, `InsightPrefs` and `CoachTurn`, all in the private
  database's default zone (architecture.md **D17**).
- **`Users`:** CloudKit's built-in type. Every container has it and every export includes
  it, so it stays in the file.
- **Queryable index:** `CoachTurn`'s `___recordID` is marked `QUERYABLE` because the
  coach-history pull queries every `CoachTurn`, and CloudKit refuses that query without
  the index.

## Why this file exists

TestFlight and App Store builds talk to the container's **Production** environment,
which never creates record types on its own. Until a schema is deployed there, every
save fails. That's what TestFlight showed before WP-47:
`Cannot create new type SyncSettings in production schema`. Types are created in
**Development** and then deployed to Production.

**A deployed Production schema is permanent.** Record types and fields can be added
later but never removed or retyped, so review a change to this file as a one-way door.

## One-time setup: a management token

`cktool` needs a CloudKit management token. Only the account owner can create one.

1. In CloudKit Console, go to **Settings → Tokens → Management Tokens** and create a
   token.
2. Save it to the keychain: `xcrun cktool save-token --type management`. It prompts for
   the token.

## Applying a schema change

Team `6AS496S47T`, container `iCloud.app.healthloom`.

```bash
# 1. Check the file against Development
xcrun cktool validate-schema --team-id 6AS496S47T \
  --container-id iCloud.app.healthloom --environment development --file CloudKit/schema.ckdb

# 2. Import it into Development
xcrun cktool import-schema --team-id 6AS496S47T \
  --container-id iCloud.app.healthloom --environment development --file CloudKit/schema.ckdb

# 3. Confirm what landed
xcrun cktool export-schema --team-id 6AS496S47T \
  --container-id iCloud.app.healthloom --environment development --output-file /tmp/dev.ckdb
diff CloudKit/schema.ckdb /tmp/dev.ckdb
```

4. **Deploy to Production** in CloudKit Console: **Schema → Deploy Schema Changes…**.
   This is a person's click, on purpose. It's the irreversible step.
5. Tap **Settings → iCloud Sync → Sync Now** on a TestFlight build. The status should
   read "Synced …".

## Checking Production for drift

```bash
xcrun cktool export-schema --team-id 6AS496S47T \
  --container-id iCloud.app.healthloom --environment production --output-file /tmp/prod.ckdb
diff CloudKit/schema.ckdb /tmp/prod.ckdb
```
