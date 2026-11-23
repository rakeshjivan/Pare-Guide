# Pare Guide

Record any workflow on your Mac and turn it into a step-by-step guide. Do the task once and Pare Guide makes one step per click or entry. Each step gets a screenshot with the clicked item boxed. Export the guide as a PDF, Word file, web page, Markdown, video or GIF.

This is a Mac desktop take on [Mimik](https://github.com/westpoint-io/mimik) (MIT). Mimik is a browser extension, so it only sees web pages. Pare Guide works in every app: Finder, Keynote, practice software, System Settings and browsers.

No account and no cloud. Guides stay on your Mac in `~/Library/Application Support/Pare Guide`.

## Get it

Download `Pare-Guide-mac.zip` from the **Releases** page. Unzip it and drag **Pare Guide** into Applications.
The app isn't signed by Apple, so macOS blocks it the first time you open it. Go to **System Settings › Privacy & Security** and click **Open Anyway**.

**Or build it yourself:** in Terminal, run `bash build.sh` in this folder.

## First launch: two permissions

- **Accessibility** lets Pare Guide see where you click, what you clicked (button names, menu items, fields) and what you type.
- **Screen Recording** lets it take the screenshots.

Click **Allow…** next to each one, switch Pare Guide on in System Settings, then click **Quit & Reopen**.

## Record

1. Click **New Recording** (⇧⌘R). The window hides and recording starts after a 3-second countdown.
2. Do the task. A red dot in the menu bar shows the step count.
3. Stop with **⌃⌥⌘S** or from the menu bar dot. Pause or resume with **⌃⌥⌘P**.

What becomes a step:
- **Clicks, right-clicks and double-clicks.** The step is worded from what you clicked, for example *Click the **Export** button* or *Choose **Save As…***. Each screenshot shows the screen just **before** the click, so menus are still open.
- **Typing.** One step per field: *Type "Smith" in the **Surname** field*. Password fields are written as *Enter your password* and the characters are never saved.
- **Shortcuts** such as ⌘C and ⇧⌘S, plus Return and Esc.

## Edit

- Click a step's text to change it. Use `**double asterisks**` for **bold**.
- Drag steps to reorder them. Use the bin to delete a step, or **Add a text-only step** for notes and tips.
- Click a picture to **Blur** private details, **Crop**, or move the **Highlight** box.
- **Pictures:** show the whole screen, or zoom in automatically around each click.
- **Versions** rolls the guide back to an earlier save.

### Private details

Emails, phone numbers, card numbers, TFNs and Medicare-style numbers are found in each screenshot and blurred automatically. You can switch this off in Settings. Click **Blur Private Details** to check again. The search is good but not perfect, so look over the pictures before you share a guide.

## Write with AI (optional)

Click **Write with AI** to reword every step, or the ✨ button for one step. **Write Title and Summary** names the guide for you. Choose how in **Settings › AI**:

- **Claude subscription (default).** Uses the Claude Code tool signed in to your Claude Pro or Max plan, so there's nothing extra to pay and no API key. Claude reads each screenshot, with blurs applied. To set it up, click **Connect Claude** in Settings › AI. Pare Guide installs Claude Code if needed and opens claude.ai in your browser so you can sign in (Google sign-in works). You do this once per Mac. Pare Guide removes any `ANTHROPIC_API_KEY` before calling it, so use is never billed as API.
- **Apple Intelligence.** Free, on-device and offline (macOS 26 or later). It uses the recorded button names, app and window, not the screenshots. It also takes over automatically if Claude Code isn't available or your allowance runs out.
- **Anthropic or OpenAI API key**, if you have API credits. The key is kept in your Mac's Keychain.

## Tutorial videos

**Export › Tutorial Video** turns a guide into a narrated how-to video (1080p). The camera eases in on each click, a cursor glides to it and clicks (with a click sound), and each step appears as a caption. The video opens and closes with an intro and outro.

- **Narration.** Click **Narration** in the toolbar to see what the narrator says for each step, plus an intro and outro line. Type your own, or use **Write with AI › Write Narration Script** to turn the steps into a natural spoken script. A blank line reads the step text.
- **Script view.** Switch the toolbar to **Steps | Grid | Script**. Script shows every line of the voiceover next to its picture, with **▶ Play** to hear it in your chosen voice, **Rewrite** (Shorter, Friendlier, More formal, Fix wording) and how long it takes to say. Lines over 12 seconds turn orange.
- **Talk while you record.** Turn it on when you start a recording and just explain what you're doing. Pare Guide turns your words into each step's narration (on your Mac, using Apple's speech recognition). **Write with AI › Polish My Spoken Narration** tidies it up.
- **Captions.** **Export › Captions** sets caption size (Small, Medium, Large), position (Auto moves the caption to the top when the click is near the bottom), one-line short captions, or no captions.
- **Pronunciation.** In **Settings › Voice › Pronunciation**, tell the narrator how to say tricky words (for example Pare → Pair).
- **Voices.** Choose the narrator in **Settings › Voice**: a cloned voice with **Pare Voice**, or one of the Mac's built-in voices.
- **Intros & outros.** The **Pare PDF** style is built in. Add your own in **Settings › Intros & Outros**: colours, a logo, a tagline and website, or your own intro and outro video clips. Pick one per guide, or **None**.

### Pare Voice (cloned voices)

Pare Voice narrates in cloned voices using Chatterbox, entirely on your Mac.

- **Setup.** In **Settings › Voice**, click **Set Up Pare Voice**. Pare Guide downloads and installs everything by itself: a Python environment at `~/chatterbox`, Chatterbox, a music remover (in `~/pare-voice-tools`) and the voice models. It takes 10–20 minutes and a few GB the first time. **Repair or Update** runs it again.
- **Voice library.** **Record a Voice** shows a short script to read for about 15 seconds. **Add from File** takes any audio or video, picks the cleanest stretch of speech and can remove background music. Voices are kept in `~/Documents/Pare Voice/Voices` (shared with the Pare Voice app). **Export Voices** and **Import Voices** move the whole library to another Mac in one file.
- **Fast or Expressive.** **Fast (Turbo)** is several times quicker and understands tags like `[laugh]`. **Expressive (Standard)** is slower and has sliders for expressiveness and pace.
- Only clone voices you have permission to use. Every clip Chatterbox makes carries an inaudible watermark showing it was AI-generated.

## Export

| Format | Notes |
|---|---|
| PDF | A4, numbered steps with pictures |
| Word (.docx) | Opens in Word or Pages; edit freely |
| Web page (.html) | One file, pictures included, light and dark mode |
| Markdown | A folder with the `.md` file and an `images` folder |
| Tutorial video (.mp4) | Narrated, animated how-to video with intro and outro (see above) |
| Simple slideshow (.mp4) | 1080p, one step every few seconds with a caption, optionally read by a Mac voice |
| GIF | Loops through the steps |
| Pare Guide file | Share a `.pareguide` file. Others open it with **Import** or a double-click. |

## Updates

Pare Guide checks for a newer version each time it opens. It downloads the update in the background and installs it when you quit. Copies you build yourself with `build.sh` don't auto-update.

Every change pushed to `main` builds the app and publishes it as the latest release.

### Keeping permissions after updates

macOS links the two permissions to the app's signature. To keep that signature the same on every release, the build uses a fixed certificate, stored as two repository secrets: `SIGNING_P12` (the base64 `.p12`) and `SIGNING_PASSWORD`. Without them, each release is signed ad hoc. You would then have to switch both permissions off and on again after every update.

## Limits

- Pare Guide can't see inside some apps that don't support Accessibility, such as some games, remote desktops and Java apps. Those clicks still become steps, with a click marker but no box.
- Mimik's live "Guide Me" replay is not included. On the desktop, windows move between runs, so a replay would point at the wrong place.
