# Renders the static site. render.rb uses only the Ruby standard library, so no
# gem install is needed and the image stays tiny.
FROM ruby:4.0-alpine

# Install python for simple HTTP server
RUN apk add --no-cache python3

WORKDIR /usr/src/app

COPY . .

VOLUME /usr/src/app/public

# Run the render script then serve public/index.html with Python's HTTP server
CMD ["sh", "-c", "ruby render.rb && python3 -m http.server 8000 --directory public"]
