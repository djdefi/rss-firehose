# Renders the static site. render.rb uses only the Ruby standard library, so no
# gem install is needed and the image stays tiny.
FROM ruby:3.3-alpine

WORKDIR /usr/src/app

COPY . .

VOLUME /usr/src/app/public
CMD ["./render.rb"]
