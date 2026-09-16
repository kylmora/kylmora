# How people reach us

Kylmora has no analytics, no telemetry and no crash-reporting service. Nothing
is sent anywhere unless a person decides to send it. That is a feature, and the
price of it is that every bug we ever fix is one somebody chose to tell us
about — so the routes have to be short, obvious, and present at the moment
something goes wrong.

There are four, and they all end in the same inbox.

## 1. In the browser

The shortest route, and the only one that is there at the moment of the bug.

| Where | What it does |
|---|---|
| **Help → Report a Problem…** | Opens a sheet: pick a kind, write it, press Send. Goes straight to kylmora.com — no mail client needed |
| **Help → Suggest a Feature…** | The same sheet, opened on the feature kind |
| **Help → Contact Support…** | The same sheet, opened on the question kind |
| **Settings → About → Contact** | The addresses written out, plus the same two buttons |
| **Help → Issues on GitHub** | The public tracker |
| **Help → Report a Security Issue…** | GitHub's private advisory form |
| After a crash | The alert offers **Send It…**, which drafts a mail with the top of the report and reveals the saved file |

### The sheet

`FeedbackWindowController` posts to `https://kylmora.com/api/contact` with
`source=app`, and the row lands in the same D1 table as the website's form —
tagged, so the two can be told apart. `FeedbackSubmission` builds the request:
one attempt, no retry, no queue, an ephemeral `URLSession` so it carries no
cookies and leaves no cache.

**This is the only thing the browser sends about itself, and only when someone
presses Send.** There is no background report, no batching and no event of any
kind; close the sheet and nothing has left the Mac. "Kylmora does not phone
home" is still true, because nothing here happens without a person deciding it
should.

The environment lines are **shown on the sheet**, not described: the version,
the build, the macOS version and `hw.model` (`Mac15,3`), printed where the
person can read them before pressing Send. No serial, no generated identifier,
no hostname, no username — nothing that says *which* Mac rather than *what
kind*.

**Send as Email Instead** is the second button, for anyone who would rather
have the message in their own Sent folder, or who does not want to post
anything to us. It hands the same report to their mail client through
`SupportContact`, which is also what the crash alert and every address link
use. A Mac with no mail client falls back to the contact page.

## 2. The form on kylmora.com

`https://kylmora.com/contact` — for people who are not in the app: someone who
could not get it to launch, or who is reading the site before downloading.

The site is static files on Cloudflare's edge; `run_worker_first` in
`wrangler.jsonc` claims `/api/*` and nothing else, so only the contact form runs
any server code. `worker/index.ts` validates it and writes one row to the
`kylmora-contact` D1 database in our own Cloudflare account. No mail is sent,
no third party is in the path, and nothing about the visitor is recorded beyond
what they typed — no IP address, no country, no user agent.

Spam defences, in order: a honeypot field, length limits, and Cloudflare
Turnstile. Turnstile is optional — with no `TURNSTILE_SECRET` set the form still
works on the first two.

### Nothing notifies you

**This is the one weakness of the whole surface, and it is deliberate.** A
message sits in the table until someone looks. Cloudflare Email Sending — which
would let the Worker mail a notification — requires the Workers Paid plan, and
we are on the free one. So the form stores, and checking is a habit rather than
an interruption.

Both the app and the form land in the same `messages` table. The `source`
column says which: `app` or `web`. Anything from `app` came from someone with
the browser running, and its version and Mac model were filled in by the app
rather than typed from memory.

Three ways to read it:

**The Cloudflare dashboard** — Storage & databases → D1 → `kylmora-contact` →
**Explore Data**. No commands, and the easiest habit to keep.

**Wrangler:**

```sh
# Everything unhandled, newest first
npx wrangler d1 execute kylmora-contact --remote \
  --command "SELECT * FROM messages WHERE handled = 0 ORDER BY received_at DESC"

# Mark one as dealt with
npx wrangler d1 execute kylmora-contact --remote \
  --command "UPDATE messages SET handled = 1 WHERE id = 7"
```

or over HTTP, once `ADMIN_KEY` is set (`wrangler secret put ADMIN_KEY`):

```sh
# everything unhandled
curl -H "Authorization: Bearer $ADMIN_KEY" https://kylmora.com/api/contact/list

# only what came from inside the app
curl -H "Authorization: Bearer $ADMIN_KEY" "https://kylmora.com/api/contact/list?source=app"
```

`ADMIN_KEY` is a shared secret and nothing more — not accounts, not sessions.
With no secret set the route answers 404 rather than opening up.

**If you would rather be told than remember:** buy the Workers Paid plan, run
`wrangler email sending enable kylmora.com`, and the Worker can mail `support@`
on every message. The code for that is a dozen lines; the plan is the blocker.

## 3. GitHub

`github.com/kylmora/kylmora` — the public route, and the right one for anything
that other people benefit from seeing.

- **Issues** — bug and feature templates; blank issues are off, so a report
  arrives with its version and steps.
- **Discussions** — questions and half-formed ideas.
- **Security → Report a vulnerability** — private advisories. Never a public
  issue; see `SECURITY.md`.

The issue chooser also links the support address and the contact form, for
people who would rather not have an account.

## 4. Email, directly

Every address on `kylmora.com` forwards to one inbox. See `BRAND_EMAIL.md` for
the full list and which is published where.

| Address | For |
|---|---|
| `support@` | Problems with the browser. The one the app and the form use. |
| `security@` | Vulnerabilities |
| `press@` | Journalists and reviewers |
| `privacy@` | Data and GDPR requests |
| `hello@` | Everything else |

## What we deliberately do not have

- **No Sentry, no PostHog, no analytics of any kind.** Not disabled by default —
  not present. There is no code in the app that could send a report on its own.
- **No automatic crash upload.** Crash reports are written to Kylmora's own
  folder and stay there unless the user chooses to send one.
- **No background reporting.** The one request the app can make about itself is
  the one a person typed and pressed Send on.
- **No "anonymous usage statistics" checkbox.** A checkbox implies there is
  something behind it to switch on.

This is the whole reason the routes above have to be good: they are not a
supplement to telemetry, they are instead of it.
