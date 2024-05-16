FROM ruby:3-alpine

# Install python for simple HTTP server
RUN apk add --no-cache python3=3.12.3-r1

VOLUME /usr/src/app/public
WORKDIR /usr/src/app

COPY . .
RUN bundle install --jobs 4

# Run the render script then serve the public/index.html using a simple HTTP server
CMD ["sh", "-c", "bundle exec ruby render.rb && python3 -m http.server 8000 --directory public"]
