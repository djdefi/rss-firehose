FROM ruby:3-alpine
WORKDIR /usr/src/app

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY . .

VOLUME /usr/src/app/public
CMD ["./render.rb"]
