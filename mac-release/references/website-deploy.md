# Hosting the appcast & DMG

Sparkle needs two things reachable over HTTPS: the **`appcast.xml`** feed (at
`SU_FEED_URL`) and the **DMG** each item's `enclosure url` points at. Anything
that serves static files works.

## Hosting options

| Option | Good for | Notes |
|---|---|---|
| **Self-hosted (VPS/EC2 + nginx)** | Full control, custom domain | Deploy via rsync — `deploy-website.sh`. |
| **GitHub Pages** | Free, push-to-deploy | Put `appcast.xml` + `downloads/` in a `gh-pages` branch or `/docs`. Feed URL `https://<user>.github.io/<repo>/appcast.xml`. Large DMGs may bump Pages limits — consider Releases for binaries. |
| **GitHub Releases** | Free binary hosting | Upload the DMG as a release asset; point the `enclosure url` at the asset. Host only the appcast on Pages. |
| **S3 + CloudFront** | Scale, CDN | Set `Content-Type` correctly; `application/octet-stream` for the DMG. |

Whichever you pick, the feed and the DMG must be served over **HTTPS** —
Sparkle refuses insecure feeds by default, and the EdDSA signature is what
actually guarantees integrity regardless of transport.

## Self-hosted path: `deploy-website.sh`

The template rsyncs your `website/` tree (landing page + `appcast.xml` +
`downloads/`) to a host over SSH. It reads connection details from env vars so
no secrets live in the repo:

```bash
export DEPLOY_HOST=deploy@updates.example.com   # or an ~/.ssh/config alias
export DEPLOY_PATH=/var/www/myapp               # remote document root
export DEPLOY_KEY=~/keys/deploy.pem             # optional; must be chmod 600/400
export DEPLOY_PORT=22                            # optional
```

The script:

- Refuses to run if `index.html` is missing (don't push a broken site).
- Warns if `appcast.xml` is missing (clients would 404 on update checks).
- Verifies the deploy key's permissions are `600`/`400` (SSH refuses looser).
- Confirms the remote directory exists before pushing (a mistyped path fails
  loudly instead of silently no-op'ing).
- `rsync --delete` keeps the remote an exact mirror — files deleted locally
  disappear from the live site.

It does **not** version-bump, sign, notarize, or tag. Run it after the appcast
has the new `<item>` and the DMG is in `website/downloads/`.

## Non-rsync hosting

If you're on Pages/S3/Releases, drop `deploy-website.sh` and substitute your
publish step (a `git push` to `gh-pages`, `aws s3 sync`, `gh release upload`).
The rest of the pipeline — preflight, release, verify, appcast edit, tag — is
unchanged. The preflight's website/SSH gates are self-hosted-specific; set
`WEBSITE_INDEX_REL=""` (and leave the deploy env vars unset) to skip them.

## Propagation

Sparkle clients poll on their own schedule (default a few times a day), so a new
version appears in the background within hours; "Check for Updates…" forces an
immediate fetch. There's no push — just make sure the appcast and DMG are live
*before* you announce.
