# Bar Native Messaging Host (macOS)

This folder contains a minimal Native Messaging host stub and the manifest template Firefox uses to discover the host.

## Host Name
The extension expects the host name:

```
bar.favicon.bridge
```

## Payloads
The extension sends JSON lines with this format:

```json
{
  "type": "tabUpdate",
  "windowId": 12,
  "url": "https://example.com",
  "favIconUrl": "https://example.com/favicon.ico"
}
```

## 1) Install the Native Host Manifest
Create the host manifest at:

```
~/Library/Application Support/Mozilla/NativeMessagingHosts/bar.favicon.bridge.json
```

Template (update `path` to your installed helper binary):

```json
{
  "name": "bar.favicon.bridge",
  "description": "Bar Firefox favicon bridge",
  "path": "/Users/you/d/Bar/NativeMessagingHost/bar_favicon_host.js",
  "type": "stdio",
  "allowed_extensions": ["bar-favicon-bridge@bar.local"]
}
```

## 2) Run the sample host
This repo includes a Node-based host stub:

```
node NativeMessagingHost/bar_favicon_host.js
```


This folder contains a minimal Napackets from stdin and logs them.

## 3) Hook into the Bar app
Replace the sample host script with a Swift CLI helper (or update it to forward to your app over IPC). The Native M```

## Payltocol uses a **4-byte little-endian length prefix** followed by a JSON payload.

Reference: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging
