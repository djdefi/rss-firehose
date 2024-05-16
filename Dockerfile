FROM ruby:3-alpine

# Install python for simple HTTP server
RUN apk add --no-cache python3 py3-pip py3-http.server

VOLUME /usr/src/app/public
WORKDIR /usr/src/app

COPY . .
RUN bundle install --jobs 4

# Serve the public/index.html using a simple HTTP server
CMD ["python3", "-m", "http.server", "8000", "--directory", "public"]
