FROM ruby:3-alpine
VOLUME /usr/src/app/public
CMD ["./render.rb"]
WORKDIR /usr/src/app

COPY . .
RUN bundle install --jobs 4
