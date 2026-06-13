# Troubleshooting

## "Re-authenticate in Claude Code: …" won't go away

You re-logged into Claude Code, but SturtBar still shows a red line like
`Re-authenticate in Claude Code: Claude OAuth refresh token missing…` or
`…token refresh failed [terminal]…`.

This usually isn't a login problem — it's SturtBar being unable to *read* your new login.
When Claude Code re-authenticates it recreates its keychain item, which resets the permission
you previously granted SturtBar. A leftover `~/.claude/.credentials.json` from an older
install can also shadow the fresh keychain credentials. Work through the steps below in
order; most people are done after step 3.

> Logging into the **Claude desktop app** doesn't help here — it doesn't update the
> credentials SturtBar reads. Only the `claude` CLI does.

### 1. Capture the exact error

Open the SturtBar menu and click the red status line — it copies the full, untruncated
message to your clipboard. Keep it handy; if you end up filing an issue, paste it there.

### 2. Confirm Claude Code itself is signed in

In Terminal, run `claude` and check `/status` shows your account without asking you to log
in. If it asks, log in and let it finish.

### 3. Grant SturtBar keychain access (fixes most cases)

With the SturtBar menu open, press **⌘R** (Refresh Now). If macOS asks
*"SturtBar wants to access Claude Code-credentials"*, click **Always Allow**.

Re-logging into Claude Code resets this permission, so you may be asked again even if you
allowed it before. Clicking *Deny* re-breaks it. Background refreshes never show this
prompt — only opening the menu or pressing ⌘R can.

### 4. Check for a stale credentials file

An old `~/.claude/.credentials.json` can shadow your fresh keychain login:

```sh
ls -la ~/.claude/.credentials.json 2>/dev/null
python3 -c "import json,os,datetime;o=json.load(open(os.path.expanduser('~/.claude/.credentials.json'))).get('claudeAiOauth',{});print('hasRefreshToken:',bool(o.get('refreshToken')),'expires:',datetime.datetime.fromtimestamp((o.get('expiresAt') or 0)/1000))"
security find-generic-password -s "Claude Code-credentials" 2>/dev/null | head -3
```

If the file shows `hasRefreshToken: False` or an expiry in the past, **and** the keychain
item exists, move the file aside and confirm Claude Code still works:

```sh
mv ~/.claude/.credentials.json ~/.claude/.credentials.json.bak
claude   # should start without asking you to log in; if not, restore the .bak file
```

Then open the SturtBar menu and press ⌘R.

### 5. Reset SturtBar's remembered auth state

SturtBar remembers a hard authentication failure until it sees your credentials change.
If it's stuck, clear that memory: quit SturtBar, then run:

```sh
for k in claudeOAuthRefreshTerminalBlockedV1 claudeOAuthRefreshTerminalReasonV1 \
         claudeOAuthRefreshBackoffFingerprintV2 claudeOAuthRefreshBackoffFailureCountV1 \
         claudeOAuthRefreshTransientBlockedUntilV1 claudeOAuthRefreshTransientFailureCountV1 \
         claudeOAuthRefreshBackoffBlockedUntilV1; do defaults delete com.michaelpalmes.sturtbar "$k" 2>/dev/null; done
security delete-generic-password -s "com.michaelpalmes.sturtbar.cache" 2>/dev/null
```

Relaunch SturtBar, open the menu, and approve the keychain prompt with **Always Allow**.

### 6. Still stuck? Collect the log

```sh
log show --last 30m --info --debug --predicate 'subsystem == "com.michaelpalmes.sturtbar"' > sturtbar.log
```

Look for `Claude OAuth credentials considered expired` lines — the `source=` and `owner=`
fields name exactly which credential store is producing the stale record. Attach the log
(it contains no tokens; secrets are redacted before logging) and the full error from
step 1 to a [GitHub issue](https://github.com/michael-palmes/SturtBar/issues).
