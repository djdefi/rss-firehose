## rss-firehose

Aggregate Local RSS feeds into a lightweight page.

Example page: https://djdefi.github.io/rss-firehose/

### Rendering:

To render the page:

```
ruby render.rb
```

Outputs to: `public/index.html`

### Writing and Running Rendering Tests

To ensure the integrity of rendering changes, it's crucial to write and run rendering tests. Here's how:

1. Write new tests in `test/render_test.rb` when modifying rendering logic.
2. To run the tests, execute the following command:

```
ruby test/render_test.rb
```

This will verify that the output of `render.rb` matches the expected HTML structure or content.

### Docker

To run the application using Docker, build the Docker image and then run the container:

```
docker build -t djdefi/rss-firehose .
docker run --rm -v rss-firehose:/usr/src/app/public -it djdefi/rss-firehose
```

Re-run the `rss-firehose` container to update the page.

#### Environment variables

Optional settings can be configured an Docker run time, or be set in your local Ruby environment:

```

## Docker:

docker run --rm -v rss-firehose:/usr/src/app/public -e "RSS_TITLE=My News" -e "RSS_URLS=https://url1/feed,http://url2/rss" -e "RSS_BACKUP_URLS=https://backup1/feed,http://backup2/rss" -e "ANALYTICS_UA=UA-XXXXX-Y" -it djdefi/rss-firehose

## Ruby:

export RSS_URLS="https://url1/feed,http://url2/rss"
export RSS_BACKUP_URLS="https://backup1/feed,http://backup2/rss"
ruby render.rb

```

Available environment variable options:

```
"ANALYTICS_UA=UA-XXXXX-Y"
"RSS_URLS=https://url1/feed,http://url2/rss"
"RSS_BACKUP_URLS=https://backup1/feed,http://backup2/rss"
"RSS_TITLE=My News"
"RSS_DESCRIPTION=My really awesome news aggregation page"
```
