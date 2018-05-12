## rss-firehose

Aggregate Local RSS feeds into a lightweight page.

Example page: https://nevco.press

### Rendering:

To render the page:

```
ruby render.rb
```

Outputs to: `public/index.html`

### Docker

Served up on port 8080 with nginx:

```
docker build -t djdefi/rss-firehose .
docker run --rm -v rss-firehose:/usr/src/app/public -it djdefi/rss-firehose
docker run --name rss-nginx --rm -v rss-firehose:/usr/share/nginx/html:ro -p 8080:80 nginx:1.14.0-alpine
```

Re-run the `rss-firehose` container to update the page.

#### Environment variables

Optional settings can be configured an Docker run time, or be set in your local Ruby environment:

```

## Docker:

docker run --rm -v rss-firehose:/usr/src/app/public -e "RSS_TITLE=My News" -e "RSS_URLS=https://url1/feed,http://url2/rss" -e "ANALYTICS_UA=UA-XXXXX-Y" -it djdefi/rss-firehose

## Ruby:

export RSS_URLS="https://url1/feed,http://url2/rss"
ruby render.rb

```

Available environment variable options:

```
"ANALYTICS_UA=UA-XXXXX-Y"
"RSS_URLS=https://url1/feed,http://url2/rss"
"RSS_TITLE=My News"
"RSS_DESCRIPTION=My really awesome news aggregation page"
```
