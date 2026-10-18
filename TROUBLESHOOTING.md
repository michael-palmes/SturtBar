# Troubleshooting

## Switching Claude accounts

After switching accounts in the Claude Code CLI, SturtBar checks for the change on its next refresh.
Press **⌘R** to check immediately. It reads only the account and organisation IDs from `~/.claude.json`
and credential metadata to detect changes; these checks do not enable Keychain prompts.

If the new credentials cannot be read, SturtBar hides the previous usage. Confirm the CLI
has finished signing in, then press **⌘R**. A locked or temporarily unavailable Keychain
alone does not count as signing out. The optional permission fallback remains off unless
you enable it; it is a last resort, not a requirement for account switching.

SturtBar follows one shared CLI sign-in. Its local spend totals include logs from all accounts.

## "Waiting for Claude Code to refresh its sign-in"

Claude's sign-in token has expired. SturtBar never refreshes it; Claude Code renews it the
next time it runs. Run `claude` (or click the line to open it) and SturtBar picks up the new
token on its next refresh. Your last reading stays on screen meanwhile.

## "Sign in to Claude Code" won't go away

You re-logged into Claude Code, but SturtBar still asks you to sign in or to allow Keychain
access.

This usually isn't a login problem: it's SturtBar being unable to *read* your new login.
When Claude Code re-authenticates it recreates its keychain item, which resets the permission
you previously granted SturtBar. A leftover `~/.claude/.credentials.json` from an older
install can also shadow the fresh keychain credentials. Work through the steps below in
order, starting with the CLI sign-in and a manual refresh.

> Logging into the **Claude desktop app** doesn't help here: it doesn't update the
> credentials SturtBar reads. Only the `claude` CLI does.

### 1. Capture the exact error

Open the SturtBar menu and hover over the red status line; the tooltip shows the full,
untruncated message. Keep it handy; if you end up filing an issue, copy it there. (Clicking
the line acts on the problem rather than copying: it opens the sign-in terminal or offers
Keychain access, depending on the message.)

### 2. Confirm Claude Code itself is signed in

In Terminal, run `claude` and check `/status` shows your account without asking you to log
in. If it asks, log in and let it finish.

### 3. Refresh after the CLI finishes signing in

Open the SturtBar menu and press **⌘R**. This checks the current sign-in immediately,
bypassing the automatic credential-check interval. An unchanged account keeps using its
cached credentials; a detected switch reads the current credentials again.

The preferred reader uses macOS's `security` command, independently of the permission
fallback setting. It normally works without a dialog when macOS permits access. The
command has no no-prompt option, so a dialog remains possible even with the fallback off.

### 4. Check for a stale credentials file

An old `~/.claude/.credentials.json` can shadow your fresh keychain login:

```sh
ls -la ~/.claude/.credentials.json 2>/dev/null
python3 -c "import json,os,datetime;o=json.load(open(os.path.expanduser('~/.claude/.credentials.json'))).get('claudeAiOauth',{});print('expires:',datetime.datetime.fromtimestamp((o.get('expiresAt') or 0)/1000))"
security find-generic-password -s "Claude Code-credentials" 2>/dev/null | head -3
```

If the file shows an expiry in the past **and** the keychain item exists, move the file aside
and confirm Claude Code still works:

```sh
mv ~/.claude/.credentials.json ~/.claude/.credentials.json.bak
claude   # should start without asking you to log in; if not, restore the .bak file
```

Then open the SturtBar menu and press ⌘R.

### 5. Collect the log

If refreshing does not recover usage, collect the log below before changing access settings
or clearing SturtBar's cached copy.

```sh
log show --last 30m --info --debug --predicate 'subsystem == "com.michaelpalmes.sturtbar"' > sturtbar.log
```

Look for `Claude OAuth credentials considered expired` lines: the `source=` and `owner=`
fields name exactly which credential store is producing the stale record. Attach the log
and the full error from step 1 to a [GitHub issue](https://github.com/michael-palmes/SturtBar/issues)
after checking them for personal information.

### 6. Optional last resort: allow the permission fallback

If you want to try the fallback, use **Allow Keychain access** in the SturtBar menu and
choose **Continue**. This enables "Ask for Keychain access when needed". Only approve
the macOS dialog if you want SturtBar to read that item. SturtBar never changes it.

The fallback can prompt on user action or once at launch when no saved token exists.
Its background reads explicitly disable dialogs. You can leave this fallback off.

### 7. Clear SturtBar's cached copy

SturtBar keeps a copy of the token it last read so it asks for Keychain access less often.
If it's stuck, clear that copy: quit SturtBar, then run:

```sh
security delete-generic-password -s "com.michaelpalmes.sturtbar.cache" 2>/dev/null
```

Relaunch SturtBar and press **⌘R**. Clearing its cache does not enable the permission fallback.
