# Deploying and managing Kylmora in an organisation

This is for IT administrators. It covers how to get Kylmora onto a fleet of
Macs, how to lock settings in place on them, and how to check that a policy
has taken effect.

## 1. Getting the app onto the Macs

Every release on the releases page carries two files:

**https://github.com/kylmora/kylmora/releases/latest**

- `Kylmora.dmg` — for people. Open it, drag the app to Applications.
- `Kylmora.pkg` — for fleets. An installer package that puts the app in
  `/Applications` with no interaction, which is what a device-management tool
  needs to install software silently on every enrolled Mac. Use this one.

Both are built and notarised by CI from a `vX.Y.Z` tag, so what you deploy is
byte-for-byte what an employee would download. The bundle identifier is
`com.kylmora.Kylmora`.

Hand the `.pkg` to whatever your device-management tool uses for third-party
apps:

| Tool | How |
| --- | --- |
| Jamf Pro | Upload `Kylmora.pkg` to the distribution point, add it to a policy, scope the policy to the Macs. |
| Microsoft Intune | Apps ▸ macOS ▸ Add ▸ *macOS app (PKG)*, upload the file, assign it. |
| Kandji, Mosyle, Addigy, Fleet | A custom-app upload of the `.pkg`, assigned to a device group. |
| Munki | Import the `.pkg` with `munkiimport`. |
| Script / SSH | `sudo installer -pkg Kylmora.pkg -target /` |

To build the package yourself from a checkout: `make bundle` then `make pkg`
(add `INSTALLER_ID="Developer ID Installer: …"` to sign it).

Employees can also download it themselves. That is fine: policies are not
inside the app, they are on the Mac, so a self-installed copy is managed
exactly like a pushed one.

Updates: the app checks for new releases itself. To make sure nobody turns
that off, enforce `AutoUpdateForced` (below), or keep pushing new `.dmg`s
through the MDM and leave the in-app check on as well.

## 2. How policies reach the browser

Kylmora reads policies from three places, in this order of precedence. The
first one that has a value for a key wins.

1. **Managed Preferences (MDM / configuration profile).** A profile whose
   payload targets the bundle ID `com.kylmora.Kylmora`. macOS stores it in
   `/Library/Managed Preferences/` and marks the values as *forced*, which is
   the only path where the user genuinely cannot override anything. This is
   what a real fleet should use. A ready-made profile is in
   [`Resources/Enterprise/Kylmora.mobileconfig`](../Resources/Enterprise/Kylmora.mobileconfig).
2. **A `policies.json` file**, either machine-wide at
   `/Library/Application Support/Kylmora/policies.json` (needs admin rights
   to write, so ordinary users cannot edit it) or per user at
   `~/Library/Application Support/Kylmora/policies.json`. Handy for scripted
   deployments and for testing without an MDM. Example in
   [`Resources/Enterprise/policies.json`](../Resources/Enterprise/policies.json).
   The file is read when the app launches.
3. **Plain preferences** (`defaults write com.kylmora.Kylmora HomepageURL …`).
   Accepted so a policy can be tried on one Mac in a minute, but the user can
   undo it with `defaults delete`, so do not rely on it for enforcement.

Whenever any key is set through any of these, the app considers itself
*managed*: a "Managed by <OrganizationName>" footer appears in Settings, the
affected controls are greyed out, and **Kylmora ▸ Enterprise Policies…**
lists every enforced key with its value.

## 3. The policies

Keys are case-sensitive. Booleans may also be given as the strings `"true"`
/ `"false"` or `1` / `0`; lists may be given as an array or as one
comma-separated string.

| Key | Type | What it does | Example |
| --- | --- | --- | --- |
| `OrganizationName` | string | Name shown in the "Managed by …" footer and the policies sheet. Set this whenever you set anything else. | `"Acme Corp"` |
| `HomepageURL` | string | Fixes the homepage; the field in General is locked. | `"https://intranet.acme.com"` |
| `NewTabURL` | string | Fixes what a new tab opens with. | `"https://intranet.acme.com/start"` |
| `DefaultSearchEngine` | string | Fixes the search engine, by identifier or name. | `"duckduckgo"`, `"google"`, `"bing"`, `"kagi"` |
| `LockSearchEngine` | bool | Greys out the search-engine controls so the choice cannot be changed. | `true` |
| `URLBlocklist` | [string] | Domains or URL patterns the browser refuses to load. | `["facebook.com", "*.tiktok.com"]` |
| `URLAllowlist` | [string] | Exceptions to the blocklist that stay reachable. | `["careers.facebook.com"]` |
| `BlockAllExtensions` | bool | No extensions can be installed or run; the Extensions pane is locked. | `true` |
| `ExtensionInstallBlocklist` | [string] | Extension IDs that may not be installed. | `["abcdefghijklmnop"]` |
| `ExtensionInstallAllowlist` | [string] | Only these extension IDs may be installed. | `["cjpalhdlnbpafiamejdnhcphjbkeiagm"]` |
| `DeveloperToolsDisabled` | bool | Removes Web Inspector, the JavaScript console and Inspect Element; the Develop menu switch is locked off. | `true` |
| `PrivateBrowsingDisabled` | bool | No private spaces or private tabs, so all browsing is logged. | `true` |
| `PasswordManagerDisabled` | bool | No saving or autofilling of credentials (for fleets that mandate a separate password manager). | `true` |
| `ContentBlockingForced` | bool | Ad and tracker blocking stays on; the switches in Privacy are locked. | `true` |
| `AutoUpdateForced` | bool | Automatic update checks stay on; the switch in About is locked. | `true` |
| `DNSOverHTTPSURL` | string | Preselects this DNS-over-HTTPS resolver in Settings ▸ Advanced and locks the picker. It does not change DNS by itself: page loads use the Mac's DNS settings, which only a `com.apple.dnsSettings.managed` profile can switch to encrypted DNS. Push that profile through your MDM alongside this policy; Kylmora's "Install DNS Profile" button makes the same profile for a single Mac. | `"https://dns.acme.com/dns-query"` |
| `RAMCacheOnlyForced` | bool | Web cache is kept in memory only, never written to disk. | `true` |

## 4. Checking that it worked

On a managed Mac:

- Open **Kylmora ▸ Enterprise Policies…**. The header reads "Managed by
  <OrganizationName>" and the table lists each enforced key and its value.
  On an unmanaged Mac the same sheet says so and the table is empty.
- Open **Settings**. A "Managed by …" footer sits under the list of panes,
  and the controls a policy covers are greyed out.
- From Terminal, for a profile-delivered policy:
  `defaults read com.kylmora.Kylmora HomepageURL` prints the value, and
  `profiles list` shows the profile installed.

Policies from a profile or `defaults` are picked up at launch; if the app is
already running when a profile lands, quit and reopen it.

## 5. Testing on one Mac without an MDM

Either double-click `Resources/Enterprise/Kylmora.mobileconfig` and approve
it in System Settings ▸ General ▸ Device Management (this installs it as a
user-approved profile, which counts as forced), or copy
`Resources/Enterprise/policies.json` to
`~/Library/Application Support/Kylmora/policies.json`, edit it, and relaunch
Kylmora. Remove the profile or delete the file to go back to unmanaged.
