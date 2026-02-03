# Bar Favicon Bridge (Firefox Extension)

This WebExtension emits `(windowId, url, favIconUrl)` for each window’s active tab and sends updates to the Bar macOS app using **Native Messaging**.

## Files
- `manifest.json` – Firefox extension manifest
- `background.js` – listens to tab/window events, sends updates

## Payload
```json
{
  "type": "tabUpdate",
  "windowId": 12,
  "url": "https://example.com",
  "favIconUrl": "https://example.com/favicon.ico"
}
```

`favIconUrl` can be a data URL or redirected icon URL as provided by Firefox.

## Load in Firefox (temporary)
1. Open Firefox → `about:debugging` → **This Firefox**.
2. Click **Load Temporary Add-on…** and select `FirefoxExtension/manifest.json`.
3. Open a few windows/tabs and watch the native host logs.

## Native Messaging Setup (macOS)
See `NativeMessagingHost/README.md`.
