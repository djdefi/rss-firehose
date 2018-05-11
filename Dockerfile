FROM ruby:2.5.1-alpine3.7
WORKDIR /usr/src/app

COPY Gemfile Gemfile.lock ./
RUN bundle install
VOLUME /usr/src/app/public

COPY . .

CMD ["./render.rb"]
