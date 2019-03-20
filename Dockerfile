FROM ruby:2.6.0-alpine3.7
WORKDIR /usr/src/app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

VOLUME /usr/src/app/public
CMD ["./render.rb"]
