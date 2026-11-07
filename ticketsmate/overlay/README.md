# TicketsMate

A native macOS app for working TeamDynamix (TDX) tickets. It is for help desk and
IT teams who live in the TDX ticketing queue all day and want a fast desktop
client in place of the web interface.

- **Ticket list and board.** Filter by status, priority, group, responsible
  person, age, SLA, form, classification and type. Search the list with ⌘F, and
  switch between list, board and inbox views.
- **Full ticket detail.** Read the feed, reply, comment privately or publicly,
  notify people, attach files, reassign, change status, and work ticket tasks
  and workflows.
- **Inbox.** Comments that notify you, gathered across tickets, with an unread
  count on the Dock icon. A small background helper keeps the count current
  while the app is closed.
- **Single sign-on.** Signs in to TDX in the background with your
  organisation's identity provider. You never see a password prompt when
  single sign-on is available. A TDX service account is supported as a
  fallback.
- **Links.** `ticketsmate://ticket/<id>` opens a ticket in the app. A Safari
  extension can hand TDX ticket pages to it.

TicketsMate holds no organisation's settings. Each site points it at its own
TDX tenant, through Settings or a configuration profile.

## Requirements

- macOS 14 Sonoma or later.
- A TeamDynamix tenant, and the ID of its ticketing application.
- For single sign-on: TDX set up for SAML sign-in through your identity
  provider. With Microsoft Entra ID, a Mac registered through Platform SSO or
  Company Portal signs in silently.
- If you have no single sign-on, a TDX service account: its BEID and web
  services key.

## Install

Download `TicketsMate-App-<version>.zip` from
[Releases](../../releases), unzip it and move `TicketsMate.app` to
`/Applications`.

Release builds are not signed or notarised. Sites that deploy the app sign
and notarise it with their own signing identity before handing it out, for
example in a Munki, Jamf or Intune pipeline. To try an unsigned build on one
Mac, clear its quarantine flag first:

```sh
xattr -dr com.apple.quarantine /Applications/TicketsMate.app
```

## Configure

On first launch a short setup asks for the TDX address and ticketing app ID.
You can change them later in Settings ▸ Authentication.

To configure every Mac at once, deploy a configuration profile for the
preference domain `systems.focused.ticketsmate`. If you build TicketsMate under
your own bundle ID, use that ID as the domain instead. A value the profile
sets wins over the one in Settings. Profile keys:

| Key                           | Type    | Meaning                                                                              |
| ----------------------------- | ------- | ------------------------------------------------------------------------------------ |
| `tdxBaseUrl`                  | string  | Your TDX tenant address, e.g. `https://example.teamdynamix.com` (the web API path is added for you) |
| `tdxTicketingAppId`           | integer | ID of the ticketing application                                                      |
| `tdxAssetsAppId`              | integer | ID of the assets application, if tickets link to assets                              |
| `tdxAppId`                    | integer | Legacy single app ID, used when the two above are unset                              |
| `tdxResponsibleGroupId`       | integer | Group whose tickets the list loads by default                                        |
| `azureTenantId`               | string  | Microsoft Entra tenant for single sign-on; defaults to `organizations`               |
| `tdxBeid`                     | string  | Service account BEID (fallback sign-in)                                              |
| `tdxWebServicesKey`           | string  | Service account web services key (fallback sign-in)                                  |
| `tdxUsername` / `tdxPassword` | string  | Username and password sign-in, where TDX allows it                                   |

Prefer single sign-on to a service account. Anything done through a service
account is attributed to that account rather than to the person using the app.
If you must deploy one, keep the key out of a profile that users can read.

A minimal profile payload:

```xml
<dict>
    <key>PayloadType</key>
    <string>systems.focused.ticketsmate</string>
    <key>PayloadIdentifier</key>
    <string>org.example.ticketsmate.settings</string>
    <key>PayloadUUID</key>
    <string>00000000-0000-0000-0000-000000000001</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>tdxBaseUrl</key>
    <string>https://example.teamdynamix.com</string>
    <key>tdxTicketingAppId</key>
    <integer>123</integer>
</dict>
```

The same settings can also come from `~/.ticketsmate/config.yaml`, or from
environment variables such as `TDX_BASE_URL` and `TDX_TICKETING_APP_ID`.
Environment variables are handy while developing.

Logs are written to `~/Library/Logs/TicketsMate/`, and every request the app
makes is listed in Window ▸ Activity Log (⌥⌘L).

## Build from source

You need Xcode 26, or the Command Line Tools with the macOS 26 SDK. You don't
need any accounts or secrets to build.

```sh
git clone https://github.com/focusedsystems/ticketsmate-macintosh.git
cd ticketsmate-macintosh
make app
open .build/app/TicketsMate.app
```

`make build` makes a debug build, and `make test` runs the test suite, which
needs Xcode. `make zip` writes `out/TicketsMate-App-<version>.zip`; pass
`VERSION=YYYY.MM.DD.HHMM` to stamp it.

Signing is optional and uses your own identity. Set it on the command line or
in a `.env` file, which is never committed:

```sh
make sign SIGNING_IDENTITY="<your codesigning identity>"
make notarize SIGNING_IDENTITY="<your codesigning identity>" NOTARY_PROFILE=<notarytool keychain profile>
```

`BUNDLE_ID=<your.bundle.id>` builds under your own bundle ID. The
configuration profile domain follows it.

## Contributing

TicketsMate's source is generated from an upstream project and synced here
automatically, so pull requests against the code in this repository are
overwritten on the next sync. Open an issue to report a bug or ask for a
feature.

## Licence

MIT. See [LICENSE](LICENSE).
