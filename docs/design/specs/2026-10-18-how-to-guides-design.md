# How-To Guides: Design

Date: 2026-10-18
Release: v1.8.3

## Intent

Submersion's user guide (`docs/user/`, published at submersion.app/guide) is a
reference: each page explains every option of one feature area. A diver who is
brand new to Submersion and wants one outcome ("my MacDive dives are in here",
"sync works on my phone and laptop") has to work out which of those options
matter and in what order.

This adds a set of task-based how-to guides for that new diver. Each guide takes
one goal from start to finish in numbered steps with a real screenshot at every
step, then links out to the reference pages for detail. The reference pages stay
as they are; the guides do not repeat them.

## Audience

Someone brand new to Submersion (the maintainer's framing). Each guide assumes
only that the app is installed. Nothing in a guide relies on having read another
guide, apart from an explicit "do this first" link.

## Goals

- Fourteen guides, each one goal end to end:
  - Database Sync Setup
  - Media Sync Setup
  - Shared Site Library Setup
  - GPS Track Logging on Mobile
  - Walk-through Sample Dive Logging
  - Customizing the Display
  - Eight migration guides, one per app a diver would be leaving: MacDive,
    Subsurface, Shearwater Cloud, Diving Log, Garmin Connect, Suunto, divelogs.de
    and DAN DiveCloud.
- A real screenshot for every step a reader needs to see, captured from the app
  running on demo data and inserted by the builder.
- A new "How-To Guides" section in the user guide's sidebar, so the guides go
  live on submersion.app/guide when the PR merges.

- One correction to an existing reference page: `shared-site-libraries.md` says
  Cloudflare R2 accepts the per-role key policy "or [has] an equivalent per-key
  prefix setting". R2 keys can be limited to buckets, not to folders inside a
  bucket (folder limits exist only for short-lived API credentials), so that
  sentence is corrected.

## Non-goals

- Changing the existing reference pages, beyond a link from the guide's home page
  to the new index and the R2 correction above. Their screenshot placeholders
  stay as they are.
- Featuring guides on the marketing homepage. That is a change in the
  `submersion-website` repo and a separate PR after this one.
- Screenshots of other apps. Export steps inside MacDive, Subsurface and the rest
  are written steps only; screenshots start at Submersion's side.
- Migration guides for formats Submersion recognises but cannot read yet (Diving
  Log XML, Suunto SML, Suunto DM5, Scubapro). Where relevant, a guide says to
  export UDDF from that app instead.
- Translations. The user guide is English only.
- Any app code change. If writing a guide turns up a bug or a confusing label,
  it is raised with the maintainer, not fixed silently in this PR.

## Anti-goals

- **A real person's data in a screenshot.** A dev build on the maintainer's Mac
  shares the installed app's data folder. Every capture uses the demo-mode
  logbook (see Screenshots), never `~/Documents/Submersion`. No real names,
  e-mail addresses, bucket names, keys, account IDs or home dive sites appear in
  any image or in the text.
- **Guessed labels.** A step that names a button that does not exist, or names it
  differently, fails a new user at exactly the moment the guide exists for. Every
  screen, menu and button name is taken from the app's English strings and
  confirmed again on screen at capture time.
- **A guide that re-documents the reference page.** If a step needs more than a
  sentence of explanation, it links to the reference page instead.

## Where they live

- Flat files in `docs/user/`, named `how-to-*.md`. The website renders the guide
  with docsify using `relativePath: false`, which resolves every link from the
  guide's root; a subfolder would break links either on GitHub or on the
  website. Flat files keep plain `settings.md` links working in both.
- An index page, `docs/user/how-to-guides.md`, listing every guide with one line
  on what it gets you, grouped as below. The guide's home page
  (`docs/user/README.md`) links to it from its "New here?" note.
- Images under `docs/user/images/how-to/<guide-slug>/`, named
  `<nn>-<what-it-shows>.png` in step order.
- Sidebar (`docs/user/_sidebar.md`): a new **How-To Guides** section directly
  after **Getting Started**:

  ```
  **How-To Guides**
  - [All How-To Guides](how-to-guides.md)
  - [Set Up Database Sync](how-to-database-sync.md)
  - [Set Up Media Sync](how-to-media-sync.md)
  - [Set Up a Shared Site Library](how-to-shared-site-library.md)
  - [Log GPS Tracks on Your Phone](how-to-gps-track-logging.md)
  - [Log a Dive from Your Computer](how-to-log-a-dive.md)
  - [Customize the Display](how-to-customize-display.md)
  - Moving from another app
    - [MacDive](how-to-move-from-macdive.md)
    - [Subsurface](how-to-move-from-subsurface.md)
    - [Shearwater Cloud](how-to-move-from-shearwater-cloud.md)
    - [Diving Log](how-to-move-from-diving-log.md)
    - [Garmin Connect](how-to-move-from-garmin-connect.md)
    - [Suunto](how-to-move-from-suunto.md)
    - [divelogs.de](how-to-move-from-divelogs-de.md)
    - [DAN DiveCloud](how-to-move-from-dan-divecloud.md)
  ```

  Sidebar labels are the builder's to polish; the slugs above are fixed so the
  image folders and cross-links can be planned.

## Shape of every guide

1. **Title and outcome.** One sentence: what you will have when you finish.
2. **Before you start.** What you need (an account, an export file, a dive
   computer, a second device) and roughly how long it takes.
3. **Numbered steps.** One action per step, using the app's exact screen and
   button names in bold, and the path in the form already used across the guide
   (**Settings > Data > Database Cloud Sync**). A screenshot after each step a
   reader needs to see; not every step needs one.
4. **Check it worked.** What the reader should see if everything went right.
5. **If something goes wrong.** The two or three failures a new user actually
   hits, each with its fix or a link to the reference page's troubleshooting.
6. **Next steps.** Links to the reference pages and to the guide that naturally
   follows.

Callouts use the guide's existing GitHub-style syntax (`> [!NOTE]`,
`> [!TIP]`, `> [!WARNING]`), which the website renders through
docsify-plugin-flexible-alerts.

Phone and desktop: steps are written once. Where the path differs between a
phone and a desktop (navigation bar vs. sidebar, a menu vs. a toolbar button),
the step says both.

## The guides

### Database Sync Setup (`how-to-database-sync.md`)

Lead path: **Google Drive** (maintainer's choice), walked end to end on the
first device and then on a second device, including the "Combine Libraries?"
prompt a second device can show. A short closing section, "Using a different
provider", covers iCloud, Dropbox and S3-compatible storage in a few lines each
and links to the reference page's Cloudflare R2 walkthrough rather than
repeating it.

### Media Sync Setup (`how-to-media-sync.md`)

Same lead path, Google Drive, through **Settings > Data > Photos & Media > Media
Storage**. Covers connecting, what gets uploaded, upload quality, and seeing the
photos on a second device. States that media storage is independent of database
sync. Closes with the same "Using a different provider" pattern.

### Shared Site Library Setup (`how-to-shared-site-library.md`)

Both readers matter equally (maintainer's answer), so the guide follows the order
things happen in real life, in clearly headed parts.

Storage is **Cloudflare R2** (maintainer's choice), with **bucket-scoped keys**
(maintainer's choice):

- The organizer makes a bucket used only for this library, apart from any bucket
  holding their own sync or photos.
- Each member gets their own R2 key, limited to that bucket, so one member can be
  cut off by deleting their key. The organizer's key is limited the same way.
- A warning box says plainly what bucket scoping cannot do: R2 cannot limit a key
  to folders, so a reader's key can write or delete files anywhere in the library
  bucket. Signatures stop a forged or altered edit from counting, and the
  library's backups repair a deletion. Clubs that need strict reader keys are
  pointed to the reference page's AWS S3 policies.

Parts:

1. **For the organizer:** set up storage, create the library, store the
   recovery code, and send members what they need to join. There is no invite
   link in the app: a member needs the library folder name, the bucket or
   server details, and a key.
2. **For members:** **Connect a library**, enter what the organizer sent,
   **Check**, then **Join**.
3. **Back to the organizer:** approve the member.
4. **Both:** see the shared sites, and what stays private.

### GPS Track Logging on Mobile (`how-to-gps-track-logging.md`)

A boat day (maintainer's choice): start recording as the boat leaves, leave the
phone on the boat during the dives, stop when back at the dock, download the
dive computer, and see each dive pick up its position from the track. Shows the
track under **Tracks**. There is no reference page for this feature today, so
this guide is its first written explanation; the builder confirms the actual
recording, permission and matching flow from the code before writing.

Screenshots: the recording is a pre-recorded boat route played back as the iOS
Simulator's location, and the matched dives come from the demo logbook. The
"download the dive computer" step links to the dive logging guide rather than
showing a real download (builder's call).

### Walk-through Sample Dive Logging (`how-to-log-a-dive.md`)

Starts from a **dive computer download** (maintainer's choice), not manual entry:
connect the computer for the first time, download, review what came in, then
open the new dive and fill in what the computer does not know (site, buddy,
gear, conditions, photos), ending at a complete dive and its profile. Links to
"Your First Dive" for manual entry.

Screenshots: the scan, pairing and download-progress screens come from the
maintainer's real computer. The download review shows real dives, so it gets no
screenshot (maintainer's choice). From "open the new dive" on, the steps are shown
on a dive from the demo logbook, introduced as "your dive will look like this"
(builder's call, so no real dive appears).

### Customizing the Display (`how-to-customize-display.md`)

From what changes the whole app to what changes one screen:

1. Look and feel: color theme, light or dark, display size.
2. Units and formats: revisiting the setup wizard's metric or imperial choice
   and fine-tuning individual units.
3. The Dashboard: status chips and home cards, and their order.
4. The dive list: Detailed, Compact or Table; which fields show; coloring cards
   by depth, duration or temperature.
5. Navigation: which destinations sit in the phone's bottom bar or the desktop
   sidebar.

Dive profile chart overlays are left to the Dive Profiles reference page, linked
at the end. (This order was proposed by the builder when the maintainer was
unsure, and accepted.)

### Migration guides (`how-to-move-from-*.md`)

Title pattern: "Moving from <App> to Submersion". One shape for all eight:

1. What comes across and what does not, up front, so the reader can decide.
2. Export from the old app: written steps only, no screenshots.
3. Import into Submersion through the import wizard (or **Transfer > Cloud** for
   the cloud sources): screenshots from here on.
4. Review: duplicates, sites, buddies and gear the wizard found.
5. Check it worked.

Per app, from what Submersion reads today (`docs/user/import-export.md`):

| Guide | Source the reader uses |
| --- | --- |
| MacDive | MacDive XML export, or reading MacDive's SQLite database directly |
| Subsurface | Subsurface XML (`.ssrf`), plus the optional sample-data CSV |
| Shearwater Cloud | The Shearwater Cloud desktop app's `.db` file |
| Diving Log | Diving Log's SQLite database |
| Garmin Connect | Cloud import under **Transfer > Cloud**, or FIT files / the watch by cable |
| Suunto | Cloud import under **Transfer > Cloud**; DM5 users export UDDF |
| divelogs.de | Cloud import under **Transfer > Cloud** (logbook, sites, gear, certifications, photos) |
| DAN DiveCloud | The DAN DL7 export, including DiveCloud's ZIP |

Where a source has two routes (MacDive XML vs. SQLite, Garmin cloud vs. file),
the guide recommends one and mentions the other in a sentence, with the reason.

The cloud imports (Garmin Connect, Suunto, divelogs.de) get screenshots up to the
point of signing in, and none of the import review, which would show real dives
(maintainer's choice). The file-based imports are captured end to end on sample
files.

## Screenshots

All screenshots are captured and inserted by the builder (maintainer's request).

- **Data:** the demo-mode logbook being built in a separate session. It is not
  ready yet. Until it is, each place an image goes holds a marker in the
  guide's existing placeholder form:
  `<!-- screenshot: images/how-to/<guide-slug>/<nn>-<name>.png: what it shows, which device, which state -->`.
  The markers are the shot list for capture.
- **Devices:** the macOS app window for most guides; the iOS Simulator for the
  GPS guide (playing back a pre-recorded boat route as the simulated location)
  and for the member side of the shared-library guide.
- **Sign-ins:** the builder never signs in to anyone's account. The maintainer
  signs in to Google (Drive) at capture time for the two sync guides; a
  throwaway account is fine. The cloud migration imports stop before sign-in.
- **Dive computer:** the maintainer has a real computer on hand at capture time
  for the scan, pairing and download screens. Screens showing downloaded dives
  are not captured.
- **Shared library storage:** a local S3-compatible server on this Mac stands in
  for R2, so "connected" and "approved" screens are real, with no real cloud
  credentials anywhere. The R2 dashboard steps are written only (another
  service's screens, like the migration exports).
- **Demo mode must allow it:** phase 2 assumes demo mode keeps its logbook apart
  from `~/Documents/Submersion` while still allowing sync, media storage, a
  shared library, file imports and a dive computer download to write into it.
  This is confirmed with the maintainer before capture starts; if it does not
  hold, the capture plan is revisited with them.
- **Migration imports:** Submersion's import wizard run on sample files for each
  format. Where the demo data does not include one, the builder uses a fixture
  file from `test/` or builds a small sample, never the maintainer's own export.
- Before inserting, every image is checked for personal data (the anti-goal
  above).

## Delivery

One PR, held open until the screenshots are in (maintainer's choice):

1. Phase 1: the spec, plan, all fourteen guides with screenshot markers, the
   index page and the sidebar section. The PR opens as a **draft**.
2. Phase 2, once demo mode is merged (the maintainer says when): capture every
   marked shot, replace each marker with the image, re-check every label on
   screen, and mark the PR ready for review.

## Paused until the app settles

On 2026-10-18, after the index guard and the empty index page were committed,
the maintainer paused all guide writing (all fourteen guides, not only the
three that walk Settings > Data) until two pieces of work merge:

- **The Settings > Data refactor, issue #3482:** a re-runnable "Set up this
  device" flow, connected accounts as the one place to sign in, new workflows
  for sync and backup, a new first run, and new wording across the section.
- **Git as a storage backend:** a new provider for sync storage (no issue
  number yet).

On resuming, before writing anything:

1. Re-read this spec against the merged app. If "Set up this device" exists, it
   becomes the sync guides' lead path. Re-check the lead-path choices (Google
   Drive for both sync guides, Cloudflare R2 for shared libraries) now that Git
   is a provider, and bring any change to the maintainer before writing.
2. Re-trace every guide's flow from the merged code; none of the earlier
   tracing is reused.
3. Then write phase 1 as planned. Phase 2 still waits for demo mode.

## Constraints

- No em dashes anywhere, and no mention of AI tools, in the guides, the PR or
  commits.
- `scripts/check_docs_links.py` checks relative links in `docs/user/`; every link
  and image path in the guides must resolve.
- Units in prose follow both systems where a number appears (for example "18 m
  (60 ft)"), since readers use either.

## Left to the builder

- Wording, sidebar label polish, and how many screenshots each step needs.
- The exact order of steps within each guide, once the real flow is confirmed in
  the code.
- Which sample files to import for each migration guide, within the data rules
  above.
- Whether a small automated check is worth adding (for example, that no
  `how-to-*.md` still holds a screenshot marker once phase 2 is done).
