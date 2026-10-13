#!/usr/bin/env bash
# One-time setup, without root: Ruby 3.4, Playwright with Chromium, and the shared libraries
# and fonts Chromium needs on a bare Debian 12. Idempotent. See README.md in this directory.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RB=${RB:-$HOME/rb}           # Ruby prefix
PW=${PW:-$HOME/pw}           # Playwright install
LIBS=${LIBS:-$HOME/chromelibs}
RUBY_TGZ=https://github.com/ruby/ruby-builder/releases/download/toolcache/ruby-3.4.6-ubuntu-22.04.tar.gz
DEB=https://deb.debian.org/debian

if [ ! -x "$RB/x64/bin/ruby.real" ]; then
  mkdir -p "$RB/syslib" && cd "$RB"
  curl -sfL -o r.tgz "$RUBY_TGZ" && tar xzf r.tgz          # compiled prefix /opt/hostedtoolcache/...
  (cd syslib && curl -sfO "$DEB/pool/main/liby/libyaml/libyaml-0-2_0.2.5-1_amd64.deb" \
     && dpkg-deb -x libyaml-0-2_0.2.5-1_amd64.deb .)
  cp "$HERE/rbconfig_fix.rb" "$RB/"
  R=$RB/x64 L=$RB/x64/lib/ruby
  mv "$R/bin/ruby" "$R/bin/ruby.real"
  cat > "$R/bin/ruby" <<WRAP
#!/bin/sh
export LD_LIBRARY_PATH=$R/lib:$RB/syslib/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export RUBYLIB=$L/3.4.0:$L/3.4.0/x86_64-linux:$L/site_ruby/3.4.0:$L/site_ruby/3.4.0/x86_64-linux:$L/vendor_ruby/3.4.0:$L/vendor_ruby/3.4.0/x86_64-linux
export GEM_HOME=$RB/gems GEM_PATH=$RB/gems:$L/gems/3.4.0
export RUBYOPT="-r$RB/rbconfig_fix.rb --disable-error_highlight \${RUBYOPT:-}"
exec $R/bin/ruby.real "\$@"
WRAP
  chmod +x "$R/bin/ruby"
  for f in bundle bundler erb gem irb racc rake rdoc ri; do
    [ -f "$R/bin/$f" ] && sed -i "1s|.*|#!$R/bin/ruby|" "$R/bin/$f"
  done
fi

mkdir -p "$PW" && cd "$PW"
[ -d node_modules/playwright ] || { npm init -y >/dev/null && npm i playwright; }
npx playwright install chromium

mkdir -p "$LIBS" && cd "$LIBS"
[ -f Packages ] || curl -sf "$DEB/dists/bookworm/main/binary-amd64/Packages.xz" | xz -d > Packages
python3 - "$DEB" <<'PY'
import subprocess, sys, os
names = """libglib2.0-0 libnspr4 libnss3 libatk1.0-0 libatk-bridge2.0-0 libdbus-1-3 libx11-6
libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libgbm1 libxcb1 libxkbcommon0 libasound2
libatspi2.0-0 libxau6 libxdmcp6 libbsd0 libmd0 libpcre2-8-0 libffi8 libdrm2 libwayland-server0
libexpat1 libxrender1 libx11-xcb1 libxcb-dri3-0 libxi6 libxshmfence1 libxcb-randr0 libxcb-xfixes0
libxcb-present0 libxcb-sync1 libfontconfig1 libfreetype6 libpng16-16 libbrotli1
fonts-dejavu-core fonts-liberation fonts-noto-color-emoji""".split()
files, cur = {}, None
for line in open("Packages", encoding="utf-8", errors="ignore"):
    if line.startswith("Package: "): cur = line[9:].strip()
    elif line.startswith("Filename: ") and cur: files.setdefault(cur, line[10:].strip())
for n in names:
    f = files[n]
    if not os.path.exists(os.path.basename(f)):
        subprocess.run(["curl", "-sfO", f"{sys.argv[1]}/{f}"], check=True)
PY
for d in *.deb; do dpkg-deb -x "$d" ex; done
cat > fonts.conf <<CONF
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig><dir>$LIBS/ex/usr/share/fonts</dir><cachedir>$LIBS/cache</cachedir></fontconfig>
CONF
echo "prepare.sh: done (Ruby in $RB, Playwright in $PW, libraries in $LIBS)"
