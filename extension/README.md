# Save to Aigle — Chrome extension

A Manifest V3 extension that adds “Save to Aigle” to Chrome's context menu.

## Install (unpacked)

1. In Aigle: **Settings → Extensions → Allow the browser extension to connect**. Copy the token.
2. In Chrome: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose this `extension/` folder.
3. Open the extension's **Options** page and paste the token.

## How it works

The extension `POST`s to `http://127.0.0.1:41417/save` with a JSON body:

```json
{ "url": "…", "pageUrl": "…", "title": "…", "type": "image" }
```

and an `X-Aigle-Token` header. The app binds the listener to the loopback
address only and rejects any request without the current token, so nothing on
your network — or on the page — can reach your library.

`type` is one of `image`, `video`, `link` or `page`. Images and videos are
downloaded into the library; links and pages become link items with a fetched
title and preview.

## Testing without Chrome

```bash
curl -i -X POST http://127.0.0.1:41417/save \
  -H 'Content-Type: application/json' \
  -H "X-Aigle-Token: $TOKEN" \
  -d '{"url":"https://example.com/cat.png","type":"image"}'
```

`GET /ping` returns `{"ok":true,"app":"Aigle"}` when the server is up.

## Icon

`icon128.png` is a placeholder generated from a script — swap in real artwork
whenever you like; nothing else references it.
