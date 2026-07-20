# Security Policy

## Reporting Security Issues

If you find a security issue, please do not publish sensitive details in a public issue. Open a private security advisory on GitHub, or contact the project maintainer through the repository owner profile.

## Sensitive Data

The app only reads local files and stores aggregate counts. The following local artifacts may still reveal personal usage patterns — treat them as private:

```text
~/.claude/ccusage.db
~/.zcode/cli/db/db.sqlite
~/Library/Preferences/com.luoqi.tokenmonitor.plist
~/Library/Group Containers/N5YV5FV235.group.com.luoqi.tokenmonitor/
```

The WidgetKit snapshot in the App Group contains token totals, model names, and tool-call counts — no credentials, no file contents.

## Notes

- The app opens SQLite databases in read-only mode (`?mode=ro`) and never writes to your source logs.
- No API keys or credentials are stored by this app. (Authentication for any underlying source DB is handled by the source tool itself.)
- Do not commit screenshots that contain your actual model usage if that is sensitive.
