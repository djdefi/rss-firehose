# Renders the static site. render.rb uses only the Ruby standard library, so no
# gem install is needed and the image stays tiny.
#
# Ruby 4.0 for modern/security-supported runtime. YJIT is intentionally NOT
# enabled: this renderer is a short-lived one-shot, so JIT warmup never pays off
# — the real speed-ups are concurrent fetching and conditional-GET caching.
FROM ruby:4.0-alpine

WORKDIR /usr/src/app

COPY . .

VOLUME /usr/src/app/public
CMD ["./render.rb"]
