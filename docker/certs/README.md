# Extra trusted CAs for the image build

This directory is empty by design.

If you build the image from behind a proxy that intercepts TLS, the `https`
downloads in the Dockerfile — Morello LLVM from `git.morello-project.org` and
the CheriBSD sysroot from `download.cheribsd.org` — fail like this:

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

Copy your organisation's root CA here as a `.crt` file (PEM encoded, despite
the extension — that is what `update-ca-certificates` expects) and rebuild.
Each build stage trusts whatever it finds here.

```sh
cp /usr/local/share/ca-certificates/YourRoot.crt docker/certs/
```

Nothing in this directory is committed apart from this file.
