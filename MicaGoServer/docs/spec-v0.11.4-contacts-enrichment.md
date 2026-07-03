# v0.11.4 — Contacts Enrichment

Status: **Planned** (spec only; no code in this pass). Depends conceptually on
[`spec-v0.11.3-sync-control-and-privacy-rules.md`](spec-v0.11.3-sync-control-and-privacy-rules.md)
(contact names make rule targets recognizable).

## Goal

Use macOS **Contacts** purely to help the user **recognize handles** (map
`+15551234567` / `name@icloud.com` to "Jane Doe") and configure sync rules.
Read-only, local-only, optional. Core server operation never depends on it.

## BlueBubbles reference inspected

- `server/api/interfaces/contactInterface.ts` + `api/lib/ContactsLib.ts` —
  reads macOS contacts via a native lib, **normalizes** phones/emails, maps
  addresses to display names.
- `server/utils/PermissionUtils.ts` — `ContactsLib.getAuthStatus()` /
  `requestAccess()` for the Contacts TCC permission.

We adopt the **concept** (read-only contacts, normalization, address→name map);
we use Apple's `Contacts.framework` directly from SwiftUI, not the BlueBubbles
code.

## Where it lives

**Companion-owned (SwiftUI).** The Mac companion has the user session and is the
natural place to request Contacts access and read the address book via
`Contacts.framework` (`CNContactStore`). The Go server stays contacts-agnostic;
it deals only in handle addresses. This keeps the relay free of a contacts
dependency and keeps personal data on the Mac, out of `relay.db` and off the
network.

## Design

### Contacts permission request & onboarding

- Add `NSContactsUsageDescription` to the companion Info.plist (e.g. "micaGO
  uses Contacts only on this Mac to show names for message handles and to help
  you set sync rules. Contacts are never uploaded.").
- A **Contacts** affordance (in Sync Control or a small Contacts panel): shows
  current authorization (`CNContactStore.authorizationStatus(for: .contacts)`)
  and a "Allow Contacts access" button that calls `requestAccess`. Clearly
  optional; if denied, the app works with raw handles.

### Read-only macOS Contacts import

- Use `CNContactStore` with read keys for **name + phone numbers + email
  addresses only** (`CNContactGivenNameKey`, `CNContactFamilyNameKey`,
  `CNContactPhoneNumbersKey`, `CNContactEmailAddressesKey`,
  `CNContactImageDataAvailableKey` optional). Never request or store notes,
  birthdays, postal addresses, etc.
- Read-only: the companion never creates/edits/deletes contacts.

### Phone / email normalization

- Normalize for matching against iMessage handles:
  - **Phone**: strip spaces/punctuation; keep `+` country code; best-effort
    E.164 (use the device region for bare national numbers). Keep a "last N
    digits" fallback match for numbers that don't normalize cleanly.
  - **Email**: lowercase, trim.
- Build an in-memory map `normalizedAddress → ContactDisplay { name, hasImage }`.

### Mapping handle addresses to display names

- iMessage handles in `relay.db` / status are raw addresses
  (`HandleJSON.id`). The companion resolves each handle through the normalized
  map to a display name for UI only.
- Unmatched handles fall back to the raw address (no error, no blocking).

### Showing contact names in Recent Messages / Sync Control

- Recent Messages rows and the chat/contact detail page show the contact name
  (when matched) instead of the raw handle, with the raw address available on
  hover/secondary line.
- Group chats: show participant names where resolvable.

### Contact search for rule creation

- A search field over the local contact cache lets the user find a person and
  create a **handle rule** (sync/push) for their phone/email directly — useful
  for whitelisting/blocklisting someone before any message arrives.

### Local-only contact cache (if needed)

- For performance, the companion may keep an **in-memory** (or on-disk under the
  app's sandbox/container) normalized cache, refreshed on launch and on
  `CNContactStoreDidChange`. The cache holds only name + normalized
  phones/emails. It is **never** written to `relay.db` and never sent to the
  server or any cloud.

### No contact upload to Firebase or cloud

- Contacts data stays on the Mac. It is **not** synced to Firebase (v0.12),
  not stored server-side, and not included in any push payload. This is a hard
  invariant restated in the Firebase spec's "never store" list.

## Privacy model

- **Optional**: declining Contacts access leaves the app fully functional with
  raw handles.
- **Read-only, minimal keys**: name + phones + emails only.
- **Local-only**: resolution and cache live in the companion; the Go server and
  `relay.db` never receive contact names; nothing is uploaded.
- Contact names are presentation-only; sync **rules** are stored by normalized
  address/`chat.guid`, not by contact identity, so revoking Contacts access does
  not break existing rules.

## Non-goals

No contact editing; no contact cloud sync; no full address-book product; no
required dependency on Contacts for core server operation.

## Manual test checklist

1. First use shows an optional "Allow Contacts access" prompt with a clear
   purpose string; declining keeps the app working with raw handles.
2. After granting, Recent Messages / Sync Control show contact **names** for
   matched handles; unmatched handles show the raw address.
3. Phone normalization matches `+1 (555) 123-4567`, `5551234567`, and
   `+15551234567` to the same contact; email matching is case-insensitive.
4. Contact search finds a person and creates a working **handle rule**.
5. Revoking Contacts access reverts the UI to raw handles without crashing and
   without losing existing rules.
6. Verify (network inspection / code review) that **no** contact data is written
   to `relay.db`, sent to the server, or included in any push/Firebase payload.
7. Companion builds; no new server dependency introduced.
